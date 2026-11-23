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
use sqlx::SqlitePool;
use tokio::task::JoinHandle;

use crate::{
    accounts,
    api::{self, AppState},
    auth::password,
    config::Config,
    db,
    net::{HomeNetworkAcceptor, NetworkPolicy},
    seclog::{self, Event, Record},
    tls::{self, Fingerprint},
};

/// How long running requests get to finish when the server stops.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(10);
/// How often old log entries, codes and unused devices are cleaned up (also once at start).
const TIDY_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

pub struct RunningServer {
    pub addr: SocketAddr,
    pub fingerprint: Fingerprint,
    handle: Handle<SocketAddr>,
    task: JoinHandle<io::Result<()>>,
    tidying: JoinHandle<()>,
}

impl RunningServer {
    /// Stops accepting connections, lets running requests finish, then returns.
    pub async fn shutdown(self) -> Result<()> {
        self.handle.graceful_shutdown(Some(SHUTDOWN_GRACE));
        self.tidying.abort();
        self.task
            .await
            .context("the server task failed")?
            .context("the server stopped with an error")
    }
}

/// Opens the database, loads the certificate and starts listening. Returns once the port is open.
pub async fn start(config: &Config) -> Result<RunningServer> {
    config.validate()?;
    let (tls_config, fingerprint) = tls::server_config(config)?;
    let pool = db::open(&config.db_path()).await?;
    let server_id = db::server_id(&pool).await?;
    password::warm_up().await;

    let listener = bind(config.server.bind, config.server.port)?;
    let addr = listener.local_addr()?;
    let state = AppState::new(config, server_id, fingerprint, addr.port(), pool.clone());
    let app = api::router(state).into_make_service_with_connect_info::<SocketAddr>();
    let acceptor = RustlsAcceptor::new(RustlsConfig::from_config(tls_config)).acceptor(
        HomeNetworkAcceptor::new(NetworkPolicy::from_config(&config.network)),
    );
    let handle = Handle::new();
    let server = axum_server::from_tcp(listener)?
        .acceptor(acceptor)
        .handle(handle.clone());
    let task = tokio::spawn(async move { server.serve(app).await });
    let tidying = tokio::spawn(keep_tidy(pool, config.clone()));

    Ok(RunningServer {
        addr,
        fingerprint,
        handle,
        task,
        tidying,
    })
}

async fn keep_tidy(pool: SqlitePool, config: Config) {
    let mut every_day = tokio::time::interval(TIDY_EVERY);
    loop {
        every_day.tick().await;
        tidy(&pool, &config).await;
    }
}

/// Signs out devices unused for too long and removes old log entries and pairing codes.
pub async fn tidy(pool: &SqlitePool, config: &Config) {
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
