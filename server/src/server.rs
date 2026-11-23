//! Starting and stopping the HTTPS server.

use std::{
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener},
    time::Duration,
};

use anyhow::{Context, Result};
use axum_server::{
    Handle,
    tls_rustls::{RustlsAcceptor, RustlsConfig},
};
use tokio::task::JoinHandle;

use crate::{
    accounts,
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
const STREAM_WINDOW: u32 = 4 * 1024 * 1024;
const CONNECTION_WINDOW: u32 = 16 * 1024 * 1024;
/// How often old log entries, codes and unused devices are cleaned up (also once at start).
const TIDY_EVERY: Duration = Duration::from_secs(24 * 60 * 60);
/// How often the mirror catches up and the backup status is refreshed (also once at start).
const BACKUP_EVERY: Duration = Duration::from_secs(60 * 60);

pub struct RunningServer {
    pub addr: SocketAddr,
    pub fingerprint: Fingerprint,
    handle: Handle<SocketAddr>,
    task: JoinHandle<io::Result<()>>,
    tidying: JoinHandle<()>,
    backing_up: JoinHandle<()>,
    workers: jobs::Workers,
    _lock: crate::fsutil::DataLock,
}

impl RunningServer {
    /// Stops accepting connections, lets running requests finish, then returns.
    pub async fn shutdown(self) -> Result<()> {
        self.handle.graceful_shutdown(Some(SHUTDOWN_GRACE));
        self.tidying.abort();
        self.backing_up.abort();
        self.workers.stop();
        self.task
            .await
            .context("the server task failed")?
            .context("the server stopped with an error")
    }
}

/// Opens the database, loads the certificate and starts listening. Returns once the port is open.
pub async fn start(config: &Config) -> Result<RunningServer> {
    config.validate()?;
    let lock = crate::fsutil::lock_data_dir(&config.storage.data_dir)?;
    let (tls_config, fingerprint) = tls::server_config(config)?;
    let pool = db::Db::open(&config.db_path()).await?;
    if let Err(error) = pool.optimize().await {
        tracing::warn!(%error, "could not optimise the database");
    }
    let server_id = db::server_id(&pool).await?;
    password::warm_up().await;

    let wake = std::sync::Arc::new(tokio::sync::Notify::new());
    let placing = std::sync::Arc::new(tokio::sync::Mutex::new(()));
    let uploads = std::sync::Arc::new(Uploads::new(config, wake.clone(), placing.clone())?);
    uploads.recover(&pool).await?;
    let workers = jobs::Workers::start(config, pool.clone(), wake.clone(), placing).await?;

    let backup_status = std::sync::Arc::new(crate::backup::mirror::StatusCell::default());

    let listener = bind(config.server.bind, config.server.port)?;
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
        _lock: lock,
    })
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

/// Runs the server until SIGTERM (systemd stop) or Ctrl-C.
pub async fn run(config: Config) -> Result<()> {
    let server = start(&config).await?;
    tracing::info!(
        name = %config.server.name,
        addr = %server.addr,
        fingerprint = %server.fingerprint,
        public = config.network.allow_public,
        "Halden server is running"
    );
    wait_for_stop_signal().await;
    tracing::info!("stopping");
    server.shutdown().await
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
