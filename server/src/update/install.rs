//! Downloading, checking and installing a release, and going back when it doesn't start.

use std::{
    io::Write,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use sha2::{Digest, Sha256};

use super::{
    MAX_PACKAGE_BYTES, Source,
    release::Found,
    status::{self, UpdateState, UpdateStatus},
    verify,
};
use crate::{
    backup::database,
    config::Config,
    db::{self, Db},
    fsutil, setup, tls,
};

/// How long the new version gets to answer after it was started.
pub const START_TIMEOUT: Duration = Duration::from_secs(60);

/// A checked release, unpacked.
#[derive(Debug)]
pub struct Downloaded {
    /// The new `halden` program.
    pub program: PathBuf,
    /// The unpacked package (with `install.sh` and the systemd units).
    pub folder: PathBuf,
}

async fn fetch_small(client: &reqwest::Client, url: &str, limit: usize) -> Result<Vec<u8>> {
    let response = client
        .get(url)
        .send()
        .await
        .with_context(|| format!("could not download {url}"))?
        .error_for_status()?;
    let mut body = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        body.extend_from_slice(&chunk?);
        if body.len() > limit {
            bail!("{url} is unexpectedly big");
        }
    }
    Ok(body)
}

/// Downloads the release into `work`, checks its signature and checksum, and unpacks it.
/// Nothing is installed yet.
pub async fn download(source: &Source, found: &Found, work: &Path) -> Result<Downloaded> {
    let Some(key) = &source.key else {
        bail!(
            "this build of Halden has no release key, so it installs no updates; install the \
             new version by hand (see docs/UPDATE_SIGNING.md)"
        );
    };
    let client = super::client()?;
    let sums = fetch_small(&client, &found.sums.browser_download_url, 64 * 1024).await?;
    let signature = fetch_small(&client, &found.signature.browser_download_url, 8 * 1024).await?;
    verify::signature(&sums, &String::from_utf8_lossy(&signature), key)?;
    let expected = verify::expected_hash(&String::from_utf8_lossy(&sums), &found.package.name)
        .with_context(|| format!("{} is not in the release's checksums", found.package.name))?;

    fsutil::create_dir(work, 0o700)?;
    let package = work.join(&found.package.name);
    let response = client
        .get(&found.package.browser_download_url)
        .send()
        .await
        .context("could not download the update")?
        .error_for_status()?;
    let mut file = std::fs::File::create(&package)?;
    let mut hasher = Sha256::new();
    let mut size = 0u64;
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("the download broke off")?;
        size += chunk.len() as u64;
        if size > MAX_PACKAGE_BYTES {
            bail!("the update is unexpectedly big");
        }
        hasher.update(&chunk);
        file.write_all(&chunk)?;
    }
    file.sync_all()?;
    drop(file);
    let actual: [u8; 32] = hasher.finalize().into();
    if actual != expected {
        let _ = std::fs::remove_file(&package);
        bail!("the download doesn't match the signed checksum; it is not installed");
    }

    // Only the package's own folder is unpacked: nothing outside it, no `..`.
    let top = format!("halden-{}-{}-linux/", found.version, super::arch());
    let listing = tokio::process::Command::new("tar")
        .arg("-tzf")
        .arg(&package)
        .stdin(Stdio::null())
        .output()
        .await
        .context("could not run tar")?;
    let names = String::from_utf8_lossy(&listing.stdout);
    let foreign = names
        .lines()
        .any(|name| !name.starts_with(&top) || name.split('/').any(|part| part == ".."));
    if !listing.status.success() || foreign {
        bail!("the download is not a Halden server package; it is not installed");
    }
    let folder = work.join("unpacked");
    let _ = std::fs::remove_dir_all(&folder);
    fsutil::create_dir(&folder, 0o700)?;
    let status = tokio::process::Command::new("tar")
        .arg("-xzf")
        .arg(&package)
        .arg("-C")
        .arg(&folder)
        .arg("--no-same-owner")
        .stdin(Stdio::null())
        .status()
        .await
        .context("could not run tar")?;
    if !status.success() {
        bail!("the update could not be unpacked");
    }
    let program = find_program(&folder).context("the update has no halden program in it")?;
    Ok(Downloaded { program, folder })
}

/// The `halden` file in the unpacked package (in its top folder).
fn find_program(folder: &Path) -> Option<PathBuf> {
    let direct = folder.join("halden");
    if direct.is_file() {
        return Some(direct);
    }
    std::fs::read_dir(folder)
        .ok()?
        .flatten()
        .map(|entry| entry.path().join("halden"))
        .find(|path| path.is_file())
}

/// Lets the new program prove itself: it must say its version, and it must be able to bring a
/// copy of the database up to date and find it intact.
pub async fn self_test(
    program: &Path,
    config_path: &Path,
    version: &semver::Version,
) -> Result<()> {
    let output = tokio::time::timeout(
        Duration::from_secs(30),
        tokio::process::Command::new(program)
            .arg("--version")
            .stdin(Stdio::null())
            .output(),
    )
    .await
    .context("the new version doesn't answer")?
    .context("the new version can't be started")?;
    let said = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() || !said.contains(&version.to_string()) {
        bail!(
            "the new version says it is {:?}, not {version}",
            said.trim()
        );
    }
    let output = tokio::time::timeout(
        Duration::from_secs(600),
        tokio::process::Command::new(program)
            .arg("--config")
            .arg(config_path)
            .arg("check-upgrade")
            .stdin(Stdio::null())
            .output(),
    )
    .await
    .context("the new version's database check took too long")?
    .context("the new version can't be started")?;
    if !output.status.success() {
        bail!(
            "the new version can't use this database: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

/// `halden check-upgrade`: copies the database, brings the copy up to this version and checks
/// it. Run by the updater with the new program before it is installed.
pub async fn check_upgrade(config: &Config) -> Result<()> {
    let folder = config.storage.data_dir.join("update");
    fsutil::create_dir(&folder, 0o700)?;
    let copy = folder.join(format!("check-{}.db", std::process::id()));
    let _ = std::fs::remove_file(&copy);
    let result = async {
        {
            use sqlx::{ConnectOptions, Connection};
            let mut connection = sqlx::sqlite::SqliteConnectOptions::new()
                .filename(config.db_path())
                .read_only(true)
                .busy_timeout(Duration::from_secs(30))
                .connect()
                .await
                .context("could not open the database")?;
            sqlx::query("VACUUM INTO ?")
                .bind(copy.to_string_lossy().into_owned())
                .execute(&mut connection)
                .await
                .context("could not copy the database")?;
            connection.close().await.ok();
        }
        let db = Db::open(&copy)
            .await
            .context("could not bring the database up to date")?;
        db.close().await;
        database::check(&copy).await
    }
    .await;
    for suffix in ["", "-wal", "-shm"] {
        let mut name = copy.clone().into_os_string();
        name.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(name));
    }
    result
}

/// Where the program lives and how it runs.
#[derive(Debug, Clone)]
pub struct Machine {
    /// The installed `halden` program, e.g. `/usr/local/bin/halden`.
    pub binary: PathBuf,
    /// The systemd unit that runs the server (`halden`), when there is one.
    pub service: Option<String>,
}

impl Machine {
    /// This program and, if systemd knows it, the `halden` unit.
    pub async fn this() -> Result<Self> {
        // Tests install into a folder of their own, never over the program that runs them.
        #[cfg(debug_assertions)]
        if let Some(binary) = std::env::var_os("HALDEN_UPDATE_BINARY") {
            return Ok(Self {
                binary: binary.into(),
                service: None,
            });
        }
        let binary = std::env::current_exe()
            .and_then(|path| path.canonicalize())
            .context("could not find where this program is installed")?;
        let service = systemctl(&["cat", "halden.service"])
            .await
            .is_ok()
            .then(|| "halden".to_string());
        Ok(Self { binary, service })
    }

    fn previous(&self) -> PathBuf {
        let mut name = self.binary.clone().into_os_string();
        name.push(".previous");
        PathBuf::from(name)
    }
}

async fn systemctl(args: &[&str]) -> Result<()> {
    let status = tokio::process::Command::new("systemctl")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .context("could not run systemctl")?;
    if !status.success() {
        bail!("systemctl {} failed", args.join(" "));
    }
    Ok(())
}

fn writable(folder: &Path) -> bool {
    let probe = folder.join(format!(".halden-update-{}", std::process::id()));
    let ok = std::fs::File::create(&probe).is_ok();
    let _ = std::fs::remove_file(&probe);
    ok
}

/// Copies `from` over `to` atomically (via a temporary file next to `to`), executable.
fn put_program(from: &Path, to: &Path) -> Result<()> {
    let bytes =
        std::fs::read(from).with_context(|| format!("could not read {}", from.display()))?;
    fsutil::write_atomic(to, &bytes, 0o755)
}

/// Asks the local server for its version, over its pinned certificate.
pub async fn running_version(config: &Config) -> Option<String> {
    let fingerprint = tls::identity_fingerprint(config).ok()?;
    let client = tls::pinned_client(fingerprint).ok()?;
    let host = match config.server.bind {
        IpAddr::V6(ip) if ip == Ipv6Addr::UNSPECIFIED => IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V4(ip) if ip == Ipv4Addr::UNSPECIFIED => IpAddr::V4(Ipv4Addr::LOCALHOST),
        other => other,
    };
    let url = match host {
        IpAddr::V6(ip) => format!("https://[{ip}]:{}/api/v1/server", config.server.port),
        IpAddr::V4(ip) => format!("https://{ip}:{}/api/v1/server", config.server.port),
    };
    let info: serde_json::Value = client.get(url).send().await.ok()?.json().await.ok()?;
    info["version"].as_str().map(str::to_string)
}

async fn wait_for_version(config: &Config, version: &str, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    while tokio::time::Instant::now() < deadline {
        if running_version(config).await.as_deref() == Some(version) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    false
}

/// What [`install`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Installed and answering (or installed, and the server must be started by hand).
    Installed { restarted: bool },
    /// Installed, didn't answer, and the old version is back.
    RolledBack,
}

/// Installs a downloaded, checked release: backs up the database, lets the new program test
/// itself, swaps it in, restarts the server and waits for it to answer with the new version.
/// If it doesn't, the old program and the backed-up database come back.
pub async fn install(
    config_path: &Path,
    config: &Config,
    machine: &Machine,
    downloaded: &Downloaded,
    version: &semver::Version,
) -> Result<Outcome> {
    self_test(&downloaded.program, config_path, version).await?;

    let db = Db::open(&config.db_path()).await?;
    let backup = database::make(&db, config).await;
    db.close().await;
    setup::give_database_back(config)?;
    let backup = backup.context("could not back up the database before the update")?;
    tracing::info!(file = %backup.name, "database backed up before the update");

    let folder = machine.binary.parent().unwrap_or(Path::new("/"));
    if !writable(folder) {
        bail!(
            "may not replace {}; run the update with sudo",
            machine.binary.display()
        );
    }
    put_program(&machine.binary, &machine.previous())?;
    put_program(&downloaded.program, &machine.binary)?;
    install_units(&downloaded.folder).await;

    let Some(service) = &machine.service else {
        return Ok(Outcome::Installed { restarted: false });
    };
    systemctl(&["restart", service]).await?;
    if wait_for_version(config, &version.to_string(), START_TIMEOUT).await {
        return Ok(Outcome::Installed { restarted: true });
    }

    tracing::error!("the new version did not answer; going back to the old one");
    let _ = systemctl(&["stop", service]).await;
    put_program(&machine.previous(), &machine.binary)?;
    database::restore(config, &backup.path)
        .await
        .context("could not put the database back")?;
    setup::give_database_back(config)?;
    // The failing version may have used up systemd's start attempts.
    let _ = systemctl(&["reset-failed", service]).await;
    systemctl(&["start", service]).await?;
    Ok(Outcome::RolledBack)
}

/// Installs the package's systemd units when they differ from the installed ones.
async fn install_units(folder: &Path) {
    let target = Path::new("/etc/systemd/system");
    if !target.is_dir() {
        return;
    }
    let Some(units) = find_dir(folder, "systemd") else {
        return;
    };
    let mut changed = false;
    for entry in std::fs::read_dir(units).into_iter().flatten().flatten() {
        let name = entry.file_name();
        let text = name.to_string_lossy();
        if !(text.starts_with("halden")
            && (text.ends_with(".service") || text.ends_with(".path") || text.ends_with(".timer")))
        {
            continue;
        }
        let Ok(new) = std::fs::read(entry.path()) else {
            continue;
        };
        let destination = target.join(&name);
        if std::fs::read(&destination).ok().as_deref() != Some(new.as_slice())
            && fsutil::write_atomic(&destination, &new, 0o644).is_ok()
        {
            changed = true;
        }
    }
    if changed {
        let _ = systemctl(&["daemon-reload"]).await;
        let _ = systemctl(&["enable", "--now", "halden-update-request.path"]).await;
    }
}

fn find_dir(folder: &Path, name: &str) -> Option<PathBuf> {
    let direct = folder.join(name);
    if direct.is_dir() {
        return Some(direct);
    }
    std::fs::read_dir(folder)
        .ok()?
        .flatten()
        .map(|entry| entry.path().join(name))
        .find(|path| path.is_dir())
}

/// Writes a status, keeping what is known about the newest version.
pub fn report(
    config: &Config,
    state: UpdateState,
    installed: &str,
    found: Option<&Found>,
    message: Option<String>,
) {
    let mut current = status::read(config);
    current.state = state;
    current.installed = installed.to_string();
    if let Some(found) = found {
        current.latest = Some(found.version.to_string());
        current.prerelease = found.prerelease;
        current.notes_url = Some(found.notes_url.clone());
    }
    current.checked_at = Some(db::now_ms());
    current.message = message;
    if let Err(error) = status::write(config, &current) {
        tracing::warn!(
            error = format!("{error:#}"),
            "could not write the update status"
        );
    }
}

/// The status after a check.
pub fn checked(config: &Config, checked: &super::Checked) -> UpdateStatus {
    let mut current = status::read(config);
    if matches!(current.state, UpdateState::Installing) {
        // An installation is running; it reports itself.
        return current;
    }
    current.installed = crate::VERSION.to_string();
    current.checked_at = Some(db::now_ms());
    current.message = None;
    current.test_version = checked.test_version.as_ref().map(ToString::to_string);
    match checked.found.as_ref() {
        Some(found) => {
            current.state = UpdateState::Available;
            current.latest = Some(found.version.to_string());
            current.prerelease = found.prerelease;
            current.notes_url = Some(found.notes_url.clone());
        }
        None => {
            current.state = UpdateState::UpToDate;
            current.latest = Some(crate::VERSION.to_string());
            current.prerelease = false;
            current.notes_url = None;
        }
    }
    if let Err(error) = status::write(config, &current) {
        tracing::warn!(
            error = format!("{error:#}"),
            "could not write the update status"
        );
    }
    current
}
