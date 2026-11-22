//! The `halden` command line.

use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream},
    path::{Path, PathBuf},
    process::ExitCode,
    time::Duration,
};

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use tracing_subscriber::EnvFilter;

use crate::{
    API_VERSION, VERSION,
    config::{Config, DEFAULT_CONFIG_PATH},
    net, server, setup, tls,
};

#[derive(Parser)]
#[command(
    name = "halden",
    version,
    about = "Halden server: your photos, your server, no twitches."
)]
struct Cli {
    /// Path to the config file.
    #[arg(long, global = true, env = "HALDEN_CONFIG", default_value = DEFAULT_CONFIG_PATH)]
    config: PathBuf,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Set up the server: config, folders, certificate and database. Safe to run again.
    Setup(SetupArgs),
    /// Show how the server is doing and how devices can reach it.
    Status,
    /// Run the server (systemd and Docker start it this way).
    Serve,
}

#[derive(Args)]
struct SetupArgs {
    /// Name the apps show for this server [default: the computer's name]
    #[arg(long)]
    name: Option<String>,
    /// Folder for the database and keys, best on the fast system disk [default: /var/lib/halden]
    #[arg(long)]
    data_dir: Option<PathBuf>,
    /// Folder for your photos and videos, usually the big data disk [default: /srv/halden/library]
    #[arg(long)]
    library_dir: Option<PathBuf>,
    /// HTTPS port [default: 47130]
    #[arg(long)]
    port: Option<u16>,
    /// System user that runs the server and owns its folders [default: halden, when run as root]
    #[arg(long)]
    service_user: Option<String>,
}

pub fn main() -> ExitCode {
    let cli = Cli::parse();
    let default_level = match cli.command {
        Command::Serve => "info",
        _ => "warn",
    };
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(default_level)),
        )
        .with_target(false)
        .with_writer(std::io::stderr)
        // Colours only in a terminal, not in the systemd journal or Docker logs.
        .with_ansi(std::io::IsTerminal::is_terminal(&std::io::stderr()))
        .init();

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("error: could not start: {error}");
            return ExitCode::FAILURE;
        }
    };
    match runtime.block_on(run(cli)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn run(cli: Cli) -> Result<()> {
    match cli.command {
        Command::Setup(args) => run_setup(&cli.config, args).await,
        Command::Status => run_status(&cli.config).await,
        Command::Serve => server::run(Config::load(&cli.config)?).await,
    }
}

async fn run_setup(config_path: &Path, args: SetupArgs) -> Result<()> {
    let report = setup::run(
        config_path,
        setup::SetupOptions {
            name: args.name,
            data_dir: args.data_dir,
            library_dir: args.library_dir,
            port: args.port,
            service_user: args.service_user,
        },
    )
    .await?;
    let config = &report.config;

    println!("Halden is set up.\n");
    row(
        "Config",
        format!(
            "{}{}",
            report.config_path.display(),
            if report.config_created {
                " (new)"
            } else {
                " (kept)"
            }
        ),
    );
    row("Name", &config.server.name);
    row("Server ID", report.server_id);
    row("Library", config.storage.library_dir.display());
    row("Data", config.storage.data_dir.display());
    if let Some(owner) = &report.owner {
        row("Runs as", owner);
    }
    row(
        "Certificate",
        if report.identity_created {
            "created"
        } else {
            "kept"
        },
    );
    row("Fingerprint", report.fingerprint);
    for warning in &report.warnings {
        println!("\nWarning: {warning}");
    }
    println!(
        "\nWhen a device connects for the first time, check that it shows the same fingerprint.\n\
         Start the server with:  sudo systemctl enable --now halden\n\
         Check on it with:       halden status"
    );
    Ok(())
}

async fn run_status(config_path: &Path) -> Result<()> {
    let config = Config::load(config_path)?;
    let fingerprint = tls::identity_fingerprint(&config)
        .context("could not read the certificate (try with sudo)")?;

    println!("Halden server \"{}\"\n", config.server.name);
    row("Version", format!("{VERSION} (API {API_VERSION})"));
    row(
        "State",
        if is_listening(config.server.port) {
            format!("running on port {}", config.server.port)
        } else {
            format!("not running (port {})", config.server.port)
        },
    );
    row("Fingerprint", fingerprint);
    if !config.uses_generated_certificate() {
        row("Certificate", config.cert_path().display());
    }

    let addresses = net::local_addresses();
    if addresses.is_empty() {
        row("Addresses", "none found on the home network");
    } else {
        let listed: Vec<String> = addresses
            .iter()
            .map(|ip| {
                if net::is_tailscale(*ip) {
                    format!("{ip} (Tailscale)")
                } else {
                    ip.to_string()
                }
            })
            .collect();
        row("Addresses", listed.join(", "));
    }
    row(
        "Network",
        if config.network.allow_public {
            "OPEN TO THE INTERNET (network.allow_public = true)".to_string()
        } else if config.network.allowed_networks.is_empty() {
            "home network and Tailscale only".to_string()
        } else {
            let extra: Vec<String> = config
                .network
                .allowed_networks
                .iter()
                .map(ToString::to_string)
                .collect();
            format!("home network, Tailscale and {}", extra.join(", "))
        },
    );
    row("Library", describe_disk(&config.storage.library_dir));
    row("Data", describe_disk(&config.storage.data_dir));
    Ok(())
}

fn row(label: &str, value: impl std::fmt::Display) {
    println!("  {label:<12} {value}");
}

/// Is something listening on this port on this computer?
fn is_listening(port: u16) -> bool {
    [
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V6(std::net::Ipv6Addr::LOCALHOST),
    ]
    .into_iter()
    .any(|ip| {
        TcpStream::connect_timeout(&SocketAddr::new(ip, port), Duration::from_millis(300)).is_ok()
    })
}

fn describe_disk(path: &Path) -> String {
    match (fs4::available_space(path), fs4::total_space(path)) {
        (Ok(free), Ok(total)) => format!(
            "{} ({} free of {})",
            path.display(),
            human_bytes(free),
            human_bytes(total)
        ),
        _ => format!("{} (not reachable)", path.display()),
    }
}

pub fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn cli_is_well_formed() {
        Cli::command().debug_assert();
    }

    #[test]
    fn bytes_are_readable() {
        assert_eq!(human_bytes(512), "512 B");
        assert_eq!(human_bytes(1_500_000), "1.5 MB");
        assert_eq!(human_bytes(931_500_000_000), "931.5 GB");
    }
}
