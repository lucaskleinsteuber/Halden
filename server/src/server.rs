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
    api::{self, AppState},
    config::Config,
    db,
    net::{HomeNetworkAcceptor, NetworkPolicy},
    tls::{self, Fingerprint},
};

/// How long running requests get to finish when the server stops.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(10);

pub struct RunningServer {
    pub addr: SocketAddr,
    pub fingerprint: Fingerprint,
    handle: Handle<SocketAddr>,
    task: JoinHandle<io::Result<()>>,
}

impl RunningServer {
    /// Stops accepting connections, lets running requests finish, then returns.
    pub async fn shutdown(self) -> Result<()> {
        self.handle.graceful_shutdown(Some(SHUTDOWN_GRACE));
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
    let state = AppState::new(server_id, config.server.name.clone(), fingerprint, pool);
    let app = api::router(state).into_make_service_with_connect_info::<SocketAddr>();

    let listener = bind(config.server.bind, config.server.port)?;
    let addr = listener.local_addr()?;
    let acceptor = RustlsAcceptor::new(RustlsConfig::from_config(tls_config)).acceptor(
        HomeNetworkAcceptor::new(NetworkPolicy::from_config(&config.network)),
    );
    let handle = Handle::new();
    let server = axum_server::from_tcp(listener)?
        .acceptor(acceptor)
        .handle(handle.clone());
    let task = tokio::spawn(async move { server.serve(app).await });

    Ok(RunningServer {
        addr,
        fingerprint,
        handle,
        task,
    })
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
