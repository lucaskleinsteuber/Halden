//! The `halden` command line.
//!
//! The account, device and log commands work on the database directly, without the HTTP API,
//! so they also work while the server is stopped.

mod devices;
mod log;
mod pair;
mod user;

use std::{
    io::{BufRead, IsTerminal},
    net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream},
    path::{Path, PathBuf},
    process::ExitCode,
    time::Duration,
};

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};
use tracing_subscriber::EnvFilter;

use crate::{
    API_VERSION, VERSION, accounts,
    auth::password,
    config::{Config, DEFAULT_CONFIG_PATH},
    db, net, server, setup, tls,
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
    /// Manage accounts.
    #[command(subcommand)]
    User(user::UserCommand),
    /// Show a QR code that adds a device to an account.
    Pair(pair::PairArgs),
    /// List the signed-in devices, or sign one out.
    Devices(devices::DevicesArgs),
    /// Show the security log: sign-ins, new devices, account changes.
    Log(log::LogArgs),
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
        Command::User(command) => user::run(&cli.config, command).await,
        Command::Pair(args) => pair::run(&cli.config, args).await,
        Command::Devices(args) => devices::run(&cli.config, args).await,
        Command::Log(args) => log::run(&cli.config, args).await,
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
    let first_owner = if report.has_accounts {
        None
    } else {
        create_first_owner(config).await?
    };

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
    if let Some(owner) = &first_owner {
        row("Owner", owner);
    }
    for warning in &report.warnings {
        println!("\nWarning: {warning}");
    }
    if !report.has_accounts && first_owner.is_none() {
        println!(
            "\nThere is no account yet. Create the first one with:\n  \
             sudo halden user add <name> --owner"
        );
    }
    println!(
        "\nWhen a device connects for the first time, check that it shows the same fingerprint.\n\
         Start the server with:  sudo systemctl enable --now halden\n\
         Check on it with:       halden status\n\
         Add a device with:      sudo halden pair"
    );
    Ok(())
}

/// Asks for the first owner account when setup runs in a terminal. Returns its username.
async fn create_first_owner(config: &Config) -> Result<Option<String>> {
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        return Ok(None);
    }
    println!("Create the first account. It becomes the owner of this server.\n");
    let username = loop {
        let name = ask_line("Username: ")?;
        match accounts::check_username(&name) {
            Ok(name) => break name,
            Err(error) => println!("{error}"),
        }
    };
    let password = ask_new_password(&username)?;
    let hash = password::hash(password).await?;
    let database = Database::open(config).await?;
    let result = accounts::create_user(
        database.pool(),
        accounts::NewUser {
            username: &username,
            display_name: None,
            role: accounts::Role::Owner,
            password_hash: Some(hash),
        },
    )
    .await;
    if let Ok(user) = &result {
        crate::seclog::Record::new(crate::seclog::Event::UserCreated)
            .user(&user.id)
            .detail(format!(
                "{} as owner in the terminal (setup)",
                user.username
            ))
            .write(database.pool())
            .await;
    }
    database.close().await?;
    println!();
    Ok(Some(result?.username))
}

/// The database, opened by a terminal command. [`Database::close`] gives files that SQLite
/// created as root back to the server's user.
pub(crate) struct Database {
    pool: db::Db,
    config: Config,
}

impl Database {
    pub(crate) async fn open(config: &Config) -> Result<Self> {
        let path = config.db_path();
        if !path.exists() {
            bail!(
                "there is no database at {} yet (run `halden setup` first)",
                path.display()
            );
        }
        let pool = db::Db::open(&path)
            .await
            .context("could not open the database (try with sudo)")?;
        Ok(Self {
            pool,
            config: config.clone(),
        })
    }

    pub(crate) fn pool(&self) -> &db::Db {
        &self.pool
    }

    pub(crate) async fn close(self) -> Result<()> {
        self.pool.close().await;
        setup::give_database_back(&self.config)
    }
}

/// Opens the database, runs `work`, and closes the database again whatever happened.
pub(crate) async fn with_database<T>(
    config_path: &Path,
    work: impl AsyncFnOnce(&Config, &db::Db) -> Result<T>,
) -> Result<T> {
    let config = Config::load(config_path)?;
    let database = Database::open(&config).await?;
    let result = work(&config, database.pool()).await;
    database.close().await?;
    result
}

/// Reads one line typed in the terminal.
pub(crate) fn ask_line(prompt: &str) -> Result<String> {
    use std::io::Write as _;
    print!("{prompt}");
    std::io::stdout().flush()?;
    let mut line = String::new();
    if std::io::stdin().lock().read_line(&mut line)? == 0 {
        bail!("no input");
    }
    Ok(line.trim().to_string())
}

/// Asks for a new password twice without showing it. Without a terminal, reads one line from
/// standard input (for scripts: `echo "$PASSWORD" | halden user add anna`).
pub(crate) fn ask_new_password(username: &str) -> Result<String> {
    if !std::io::stdin().is_terminal() {
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line)?;
        let password = line.trim_end_matches(['\r', '\n']).to_string();
        password::check_new(&password, username).map_err(anyhow::Error::msg)?;
        return Ok(password);
    }
    for _ in 0..3 {
        let first = rpassword::prompt_password(format!("Password for {username}: "))?;
        if let Err(problem) = password::check_new(&first, username) {
            println!("{problem}");
            continue;
        }
        let second = rpassword::prompt_password("Same password again: ")?;
        if first == second {
            return Ok(first);
        }
        println!("The two passwords are different.");
    }
    bail!("no password set")
}

/// A Unix time in milliseconds as local date and time.
pub(crate) fn local_time(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms)
        .map(|time| {
            time.with_timezone(&chrono::Local)
                .format("%Y-%m-%d %H:%M")
                .to_string()
        })
        .unwrap_or_else(|| "?".into())
}

/// Prints rows as columns, each as wide as its widest cell.
pub(crate) fn print_table(headers: &[&str], rows: &[Vec<String>]) {
    let mut widths: Vec<usize> = headers.iter().map(|h| h.chars().count()).collect();
    for row in rows {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(cell.chars().count());
        }
    }
    let line = |cells: Vec<&str>| {
        let padded: Vec<String> = cells
            .iter()
            .zip(&widths)
            .map(|(cell, width)| format!("{cell:<width$}"))
            .collect();
        println!("  {}", padded.join("  ").trim_end());
    };
    line(headers.to_vec());
    for row in rows {
        line(row.iter().map(String::as_str).collect());
    }
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
    match library_numbers(&config).await {
        Ok((stats, uploads, accounts)) => {
            row(
                "Photos",
                format!(
                    "{} photos, {} videos, {} in the trash ({})",
                    stats.photos,
                    stats.videos,
                    stats.trashed,
                    human_bytes(stats.library_bytes.max(0) as u64)
                ),
            );
            row("Uploads", format!("{uploads} unfinished"));
            row("Accounts", accounts);
        }
        Err(_) => row("Photos", "run with sudo to see the library"),
    }
    Ok(())
}

async fn library_numbers(
    config: &Config,
) -> Result<(crate::library::assets::LibraryStats, i64, i64)> {
    let database = Database::open(config).await?;
    let result = async {
        let stats = crate::library::assets::stats(database.pool(), None).await?;
        let (uploads,): (i64,) =
            sqlx::query_as("SELECT count(*) FROM uploads WHERE state = 'receiving'")
                .fetch_one(database.pool().read())
                .await?;
        let accounts = accounts::count_users(database.pool()).await?;
        Ok::<_, anyhow::Error>((stats, uploads, accounts))
    }
    .await;
    database.close().await?;
    result
}

fn row(label: &str, value: impl std::fmt::Display) {
    println!("  {label:<12} {value}");
}

/// Is something listening on this port on this computer?
pub(crate) fn is_listening(port: u16) -> bool {
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
