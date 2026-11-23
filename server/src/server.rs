//! Starting, reloading and stopping the HTTPS server.
//!
//! [`Supervisor`] runs the server for `halden serve`. When the config file changes (the server
//! looks every few seconds, on `SIGHUP`, and right after an app changed a setting), it starts the
//! server again inside the same process with the new settings, in well under a second: the port
//! stays open the whole time, so devices just reconnect, and uploads continue where they were.
//! A config file that isn't valid is not used; the server goes on with the settings it has and
//! reports the problem (`halden doctor`, the apps).

use std::{
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener},
    path::{Path, PathBuf},
    sync::{
        Arc, RwLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, Result};
use axum_server::{
    Handle,
    tls_rustls::{RustlsAcceptor, RustlsConfig},
};
use tokio::{
    sync::{Notify, oneshot, watch},
    task::JoinHandle,
};

use crate::{
    accounts,
    activity::Activity,
    api::{self, AppState},
    auth::password,
    config::Config,
    db, jobs,
    net::{HomeNetworkAcceptor, NetworkPolicy},
    seclog::{self, Event, Record},
    tls::{self, Fingerprint},
    upload::Uploads,
};

/// How long running requests get to finish when the server stops.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(10);
/// When the server restarts with new settings. Uploads cut off continue right after.
const RESTART_GRACE: Duration = Duration::from_secs(2);
/// How long a stop waits for upload writers and background work to let go of their files.
const WORK_GRACE: Duration = Duration::from_secs(15);
/// How often the config file is checked for changes.
pub const CONFIG_POLL: Duration = Duration::from_secs(5);
const STREAM_WINDOW: u32 = 4 * 1024 * 1024;
const CONNECTION_WINDOW: u32 = 16 * 1024 * 1024;
/// How often old log entries, codes and unused devices are cleaned up (also once at start).
const TIDY_EVERY: Duration = Duration::from_secs(24 * 60 * 60);
/// How often the mirror catches up and the backup status is refreshed (also once at start).
const BACKUP_EVERY: Duration = Duration::from_secs(60 * 60);

/// What the API may ask of the process that runs it: where the settings live, and to start
/// again with them.
#[derive(Clone)]
pub struct Control(Arc<ControlInner>);

struct ControlInner {
    config_path: Option<PathBuf>,
    restart: Notify,
    problem: RwLock<Option<String>>,
    started_at: i64,
    restarts: AtomicU64,
}

impl Default for Control {
    fn default() -> Self {
        Self::new(None)
    }
}

impl Control {
    pub fn new(config_path: Option<PathBuf>) -> Self {
        Self(Arc::new(ControlInner {
            config_path,
            restart: Notify::new(),
            problem: RwLock::new(None),
            started_at: db::now_ms(),
            restarts: AtomicU64::new(0),
        }))
    }

    /// The config file, when the server was started from one (always, except in tests).
    pub fn config_path(&self) -> Option<&Path> {
        self.0.config_path.as_deref()
    }

    /// Starts the server again with the settings in the config file, once the current request
    /// has been answered.
    pub fn restart_soon(&self) {
        let control = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(250)).await;
            control.0.restart.notify_one();
        });
    }

    /// Why the config file's newest contents are not in use, if they aren't.
    pub fn config_problem(&self) -> Option<String> {
        self.0.problem.read().ok().and_then(|p| p.clone())
    }

    fn set_problem(&self, problem: Option<String>) {
        if let Ok(mut current) = self.0.problem.write() {
            *current = problem;
        }
    }

    /// When the process started (Unix milliseconds).
    pub fn started_at(&self) -> i64 {
        self.0.started_at
    }

    /// How often the server restarted with new settings since the process started.
    pub fn restarts(&self) -> u64 {
        self.0.restarts.load(Ordering::SeqCst)
    }
}

pub struct RunningServer {
    pub addr: SocketAddr,
    pub fingerprint: Fingerprint,
    handle: Handle<SocketAddr>,
    task: JoinHandle<io::Result<()>>,
    tidying: JoinHandle<()>,
    backing_up: JoinHandle<()>,
    workers: jobs::Workers,
    activity: Activity,
    _lock: crate::fsutil::DataLock,
}

impl RunningServer {
    /// Stops accepting connections, lets running requests finish, then returns.
    pub async fn shutdown(self) -> Result<()> {
        self.stop(SHUTDOWN_GRACE).await
    }

    async fn stop(self, grace: Duration) -> Result<()> {
        self.handle.graceful_shutdown(Some(grace));
        self.tidying.abort();
        self.backing_up.abort();
        self.workers.stop();
        let served = self.task.await;
        // Upload writers and photo decoding run on their own threads; the next server must not
        // start on the same files while they still write.
        if !self.activity.wait_idle(WORK_GRACE).await {
            tracing::warn!(
                busy = self.activity.count(),
                "background work did not finish in time"
            );
        }
        served
            .context("the server task failed")?
            .context("the server stopped with an error")
    }
}

/// Opens the database, loads the certificate and starts listening. Returns once the port is open.
pub async fn start(config: &Config) -> Result<RunningServer> {
    let listener = bind(config.server.bind, config.server.port)?;
    start_on(config, listener, Control::default()).await
}

/// Like [`start`], on a port that is already open.
pub async fn start_on(
    config: &Config,
    listener: TcpListener,
    control: Control,
) -> Result<RunningServer> {
    config.validate()?;
    let lock = crate::fsutil::lock_data_dir(&config.storage.data_dir)?;
    let (tls_config, fingerprint) = tls::server_config(config)?;
    let pool = db::Db::open(&config.db_path()).await?;
    if let Err(error) = pool.optimize().await {
        tracing::warn!(%error, "could not optimise the database");
    }
    let server_id = db::server_id(&pool).await?;
    password::warm_up().await;

    let activity = Activity::default();
    let wake = Arc::new(Notify::new());
    let placing = Arc::new(tokio::sync::Mutex::new(()));
    let uploads = Arc::new(Uploads::new(
        config,
        wake.clone(),
        placing.clone(),
        activity.clone(),
    )?);
    uploads.recover(&pool).await?;
    let workers = jobs::Workers::start(
        config,
        pool.clone(),
        wake.clone(),
        placing,
        activity.clone(),
    )
    .await?;

    let backup_status = Arc::new(crate::backup::mirror::StatusCell::default());

    let addr = listener.local_addr()?;
    let state = AppState::new(
        config,
        api::Services {
            server_id,
            fingerprint,
            port: addr.port(),
            db: pool.clone(),
            uploads: uploads.clone(),
            wake: wake.clone(),
            backup_status: backup_status.clone(),
            control,
        },
    );
    let app = api::router(state).into_make_service_with_connect_info::<SocketAddr>();
    let acceptor = RustlsAcceptor::new(RustlsConfig::from_config(tls_config)).acceptor(
        HomeNetworkAcceptor::new(NetworkPolicy::from_config(&config.network)),
    );
    let handle = Handle::new();
    let mut server = axum_server::from_tcp(listener)?
        .acceptor(acceptor)
        .handle(handle.clone());
    tune_http(&mut server);
    let task = tokio::spawn(async move { server.serve(app).await });
    let tidying = tokio::spawn(keep_tidy(pool.clone(), config.clone(), uploads));
    let backing_up = tokio::spawn(keep_backed_up(pool, config.clone(), backup_status, wake));

    Ok(RunningServer {
        addr,
        fingerprint,
        handle,
        task,
        tidying,
        backing_up,
        workers,
        activity,
        _lock: lock,
    })
}

/// What the supervised server currently is.
#[derive(Debug, Clone)]
pub struct Generation {
    /// 0 for the first start, then one more for every restart with new settings.
    pub number: u64,
    pub addr: SocketAddr,
    pub fingerprint: Fingerprint,
}

/// Runs the server from a config file and restarts it when the file changes. See the module
/// documentation.
pub struct Supervisor {
    stop: Option<oneshot::Sender<()>>,
    task: JoinHandle<Result<()>>,
    generation: watch::Receiver<Generation>,
    control: Control,
}

impl Supervisor {
    pub async fn start(config_path: &Path) -> Result<Self> {
        Self::start_polling(config_path, CONFIG_POLL).await
    }

    /// Like [`Supervisor::start`], looking at the config file every `poll`.
    pub async fn start_polling(config_path: &Path, poll: Duration) -> Result<Self> {
        let config = Config::load(config_path)?;
        let listener = bind(config.server.bind, config.server.port)?;
        let control = Control::new(Some(config_path.to_path_buf()));
        let server = start_on(&config, listener.try_clone()?, control.clone()).await?;
        let (generation_tx, generation) = watch::channel(Generation {
            number: 0,
            addr: server.addr,
            fingerprint: server.fingerprint,
        });
        let (stop, stop_rx) = oneshot::channel();
        let task = tokio::spawn(supervise(Supervised {
            path: config_path.to_path_buf(),
            config,
            listener,
            server: Some(server),
            control: control.clone(),
            stop: stop_rx,
            generation: generation_tx,
            poll,
        }));
        Ok(Self {
            stop: Some(stop),
            task,
            generation,
            control,
        })
    }

    pub fn current(&self) -> Generation {
        self.generation.borrow().clone()
    }

    pub fn control(&self) -> &Control {
        &self.control
    }

    /// Waits until the server has restarted past generation `after`.
    pub async fn restarted_after(&mut self, after: u64) -> Generation {
        let _ = self.generation.wait_for(|g| g.number > after).await;
        self.current()
    }

    pub async fn stop(mut self) -> Result<()> {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        self.task.await.context("the server task failed")?
    }
}

struct Supervised {
    path: PathBuf,
    config: Config,
    listener: TcpListener,
    /// Only `None` for the moment between stopping and starting again.
    server: Option<RunningServer>,
    control: Control,
    stop: oneshot::Receiver<()>,
    generation: watch::Sender<Generation>,
    poll: Duration,
}

async fn supervise(mut s: Supervised) -> Result<()> {
    let mut seen = std::fs::read(&s.path).ok();
    let mut ticks = tokio::time::interval(s.poll);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    ticks.tick().await;
    #[cfg(unix)]
    let mut hangup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup()).ok();
    loop {
        let hangup_signal = async {
            #[cfg(unix)]
            if let Some(signal) = hangup.as_mut() {
                signal.recv().await;
                return;
            }
            std::future::pending::<()>().await;
        };
        let forced = tokio::select! {
            _ = &mut s.stop => break,
            () = hangup_signal => false,
            () = s.control.0.restart.notified() => true,
            _ = ticks.tick() => {
                let now = std::fs::read(&s.path).ok();
                if now == seen {
                    continue;
                }
                seen = now;
                false
            }
        };
        let next = match Config::load(&s.path) {
            Ok(next) => {
                s.control.set_problem(None);
                next
            }
            Err(error) => {
                let problem = format!("{error:#}");
                tracing::error!(
                    problem,
                    "the changed config file can't be used; keeping the old settings"
                );
                s.control.set_problem(Some(problem));
                if !forced {
                    continue;
                }
                s.config.clone()
            }
        };
        if next == s.config && !forced {
            continue;
        }
        restart(&mut s, next).await?;
    }
    match s.server.take() {
        Some(server) => server.shutdown().await,
        None => Ok(()),
    }
}

async fn restart(s: &mut Supervised, mut next: Config) -> Result<()> {
    tracing::info!("starting again with the changed settings");
    let old = std::mem::replace(&mut s.config, next.clone());
    // The old server is fully stopped before the next one opens the database.
    if let Some(running) = s.server.take() {
        running.stop(RESTART_GRACE).await?;
    }
    if (next.server.bind, next.server.port) != (old.server.bind, old.server.port) {
        match bind(next.server.bind, next.server.port) {
            Ok(listener) => s.listener = listener,
            Err(error) => {
                tracing::error!(error = format!("{error:#}"), "keeping the old address");
                s.control.set_problem(Some(format!("{error:#}")));
                next.server.bind = old.server.bind;
                next.server.port = old.server.port;
            }
        }
    }
    let started = match start_on(&next, s.listener.try_clone()?, s.control.clone()).await {
        Ok(started) => started,
        Err(error) => {
            let problem = format!("{error:#}");
            tracing::error!(
                problem,
                "the new settings could not be used; going on with the old ones"
            );
            s.control.set_problem(Some(problem));
            next = old;
            start_on(&next, s.listener.try_clone()?, s.control.clone()).await?
        }
    };
    s.config = next;
    s.control.0.restarts.fetch_add(1, Ordering::SeqCst);
    s.generation.send_modify(|generation| {
        generation.number += 1;
        generation.addr = started.addr;
        generation.fingerprint = started.fingerprint;
    });
    s.server = Some(started);
    Ok(())
}

/// HTTP/2 as the apps use it: one connection carries hundreds of thumbnail requests at once, and
/// uploads must not be throttled by tiny flow-control windows (hyper starts with 64 KiB, which
/// caps an upload over Wi-Fi or Tailscale at a fraction of the line speed). 4 MiB per stream
/// covers a 100 ms round trip at 40 MB/s; the windows also cap how much an upload can have in
/// flight, so many uploads at once can't eat the memory. Pings find dead connections (a phone
/// that left the house) so they don't hold uploads open.
fn tune_http<A>(server: &mut axum_server::Server<SocketAddr, A>) {
    server
        .http_builder()
        .http2()
        .initial_stream_window_size(STREAM_WINDOW)
        .initial_connection_window_size(CONNECTION_WINDOW)
        .max_concurrent_streams(256)
        .max_frame_size(256 * 1024)
        .max_send_buf_size(1024 * 1024)
        .keep_alive_interval(Duration::from_secs(20))
        .keep_alive_timeout(Duration::from_secs(20));
}

/// Makes the daily database backup (copied to the mirror too), lets the mirror catch up, and
/// refreshes the backup status the apps show.
async fn keep_backed_up(
    pool: db::Db,
    config: Config,
    status: std::sync::Arc<crate::backup::mirror::StatusCell>,
    wake: std::sync::Arc<tokio::sync::Notify>,
) {
    let mut every_hour = tokio::time::interval(BACKUP_EVERY);
    loop {
        every_hour.tick().await;
        back_up(&pool, &config, &status, &wake).await;
    }
}

/// One round of [`keep_backed_up`]; public for tests.
pub async fn back_up(
    pool: &db::Db,
    config: &Config,
    status: &crate::backup::mirror::StatusCell,
    wake: &tokio::sync::Notify,
) {
    use crate::backup::{database, mirror};
    if database::due(config, db::now_ms()) {
        match database::make(pool, config).await {
            Ok(backup) => {
                tracing::info!(file = %backup.name, bytes = backup.size, "database backed up");
                if let Err(error) = mirror::mirror_backup(config, &backup.path).await {
                    tracing::warn!(%error, "could not copy the database backup to the mirror");
                }
            }
            Err(error) => tracing::error!(error = format!("{error:#}"), "database backup failed"),
        }
    }
    if config.mirror.path.is_some() {
        match mirror::sweep(pool).await {
            Ok(0) => {}
            Ok(queued) => {
                tracing::info!(queued, "copying missing files to the mirror");
                wake.notify_waiters();
            }
            Err(error) => tracing::error!(%error, "could not check the mirror"),
        }
    }
    let current = mirror::compute_status(pool, config).await;
    if current.only_one_copy {
        tracing::warn!(
            mirror = ?current.mirror,
            "there is only one copy of the photos; set up a mirror with `halden mirror set`"
        );
    }
    status.set(current);
}

async fn keep_tidy(pool: db::Db, config: Config, uploads: std::sync::Arc<Uploads>) {
    let mut every_day = tokio::time::interval(TIDY_EVERY);
    loop {
        every_day.tick().await;
        tidy(&pool, &config).await;
        match uploads.expire(&pool, db::now_ms()).await {
            Ok(0) => {}
            Ok(expired) => tracing::info!(expired, "threw away unfinished uploads"),
            Err(error) => tracing::error!(%error, "could not tidy up uploads"),
        }
        if let Err(error) = pool.optimize().await {
            tracing::warn!(%error, "could not optimise the database");
        }
    }
}

/// Signs out devices unused for too long and removes old log entries and pairing codes.
pub async fn tidy(pool: &db::Db, config: &Config) {
    let now = db::now_ms();
    match accounts::tidy(
        pool,
        config.auth.device_inactive_days,
        config.security.log_retention_days,
        now,
    )
    .await
    {
        Ok(tidied) => {
            for (device, user) in &tidied.expired_devices {
                Record::new(Event::DeviceExpired)
                    .user(user)
                    .device(device)
                    .detail(format!(
                        "unused for more than {} days",
                        config.auth.device_inactive_days
                    ))
                    .write(pool)
                    .await;
            }
        }
        Err(error) => tracing::error!(%error, "could not tidy up accounts and devices"),
    }
    let derived = config.derived_dir();
    let roots = crate::library::trash::Roots {
        library: &config.storage.library_dir,
        derived: &derived,
        mirror: config.mirror.path.as_deref(),
    };
    match crate::library::trash::purge_expired(pool, roots, config.library.trash_days, now).await {
        Ok(0) => {}
        Ok(deleted) => tracing::info!(deleted, "deleted photos that were in the trash too long"),
        Err(error) => tracing::error!(%error, "could not empty the trash"),
    }
    match crate::library::sync::purge_tombstones(pool, config.library.tombstone_days, now).await {
        Ok(0) => {}
        Ok(removed) => tracing::info!(removed, "removed old tombstones of deleted photos"),
        Err(error) => tracing::error!(%error, "could not remove old tombstones"),
    }
    match seclog::prune(pool, config.security.log_retention_days, now).await {
        Ok(0) => {}
        Ok(removed) => tracing::info!(removed, "removed old security log entries"),
        Err(error) => tracing::error!(%error, "could not tidy up the security log"),
    }
}

/// Runs the server until SIGTERM (systemd stop) or Ctrl-C, picking up changed settings on the
/// way.
pub async fn run(config_path: &Path) -> Result<()> {
    let config = Config::load(config_path)?;
    let supervisor = Supervisor::start(config_path).await?;
    let running = supervisor.current();
    tracing::info!(
        name = %config.server.name,
        addr = %running.addr,
        fingerprint = %running.fingerprint,
        public = config.network.allow_public,
        "Halden server is running"
    );
    wait_for_stop_signal().await;
    tracing::info!("stopping");
    supervisor.stop().await
}

/// Listens on `ip:port`. If `::` is not possible because IPv6 is turned off on this computer,
/// falls back to every IPv4 address.
fn bind(ip: IpAddr, port: u16) -> Result<TcpListener> {
    match TcpListener::bind((ip, port)) {
        Ok(listener) => Ok(listener),
        Err(error)
            if ip == IpAddr::V6(Ipv6Addr::UNSPECIFIED)
                && error.kind() != io::ErrorKind::AddrInUse =>
        {
            tracing::warn!(%error, "IPv6 is not available, listening on IPv4 only");
            TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
                .with_context(|| format!("could not listen on port {port}"))
        }
        Err(error) => {
            let kind = error.kind();
            Err(error).with_context(|| match kind {
                io::ErrorKind::AddrInUse => format!(
                    "port {port} is already in use (is Halden already running? see `halden status`)"
                ),
                _ => format!("could not listen on {ip} port {port}"),
            })
        }
    }
}

async fn wait_for_stop_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
}
