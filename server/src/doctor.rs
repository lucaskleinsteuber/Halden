//! `halden doctor`: checks everything the server depends on and says how to fix what's wrong.
//!
//! The quick checks run in a second and are also what the apps show (`GET /admin/doctor`).
//! [`verify_files`] (`halden doctor --files`) reads every file of the library and the mirror and
//! compares it with the SHA-256 recorded when it arrived, which finds silent disk damage.

use std::{
    collections::HashSet,
    ffi::OsString,
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::Result;
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::{
    backup::{database, mirror},
    config::Config,
    db::{self, Db},
    jobs::tools::{self, Tools},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Level {
    Ok,
    Warning,
    Problem,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Check {
    /// Stable, for code: `config`, `folders`, `disk`, …
    pub id: &'static str,
    pub level: Level,
    pub title: &'static str,
    pub detail: String,
    /// What to do about it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

impl Check {
    fn new(id: &'static str, title: &'static str, level: Level, detail: impl Into<String>) -> Self {
        Self {
            id,
            level,
            title,
            detail: detail.into(),
            fix: None,
        }
    }

    fn fix(mut self, fix: impl Into<String>) -> Self {
        self.fix = Some(fix.into());
        self
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub level: Level,
    pub checks: Vec<Check>,
}

/// What the caller knows that doctor can't find out itself.
#[derive(Debug, Default, Clone)]
pub struct Options {
    /// The config file, to check that the server may save settings changed in the app.
    pub config_path: Option<PathBuf>,
    /// Why the config file's newest contents are not in use.
    pub config_problem: Option<String>,
    /// True when asked by the running server itself.
    pub from_server: bool,
}

const INSTALL_TOOLS: &str = "sudo apt install ffmpeg libheif-examples libheif-plugin-libde265 \
                             libheif-plugin-x265";

pub async fn check(config: &Config, db: Option<&Db>, options: &Options) -> Report {
    let mut checks = vec![config_check(options)];
    checks.push(folders(config));
    if let Some(path) = &options.config_path {
        checks.push(settings_writable(path));
    }
    checks.extend(disks(config));
    if let Some(db) = db {
        checks.push(database_check(db).await);
    }
    checks.push(certificate(config));
    checks.extend(tools_check().await);
    if let Some(db) = db {
        checks.push(mirror_check(config, db).await);
        checks.push(jobs_check(db).await);
    }
    checks.push(backups(config));
    checks.push(server_check(config, options));
    checks.extend(clock().await);
    checks.extend(systemd(config).await);
    checks.extend(firewall(config).await);
    if config.network.bonjour
        && !crate::net::local_addresses()
            .into_iter()
            .any(crate::bonjour::announce_on)
    {
        checks.push(
            Check::new(
                "bonjour",
                "Bonjour",
                Level::Warning,
                "no home-network address, so the apps can't find the server by themselves",
            )
            .fix("pair devices with the QR code from `sudo halden pair` instead"),
        );
    }
    if config.network.allow_public {
        checks.push(
            Check::new(
                "network",
                "Network",
                Level::Warning,
                "the server accepts connections from the internet",
            )
            .fix("unless you really want that: halden config set network.allow_public false"),
        );
    }
    let level = checks.iter().map(|c| c.level).max().unwrap_or(Level::Ok);
    Report { level, checks }
}

fn config_check(options: &Options) -> Check {
    match &options.config_problem {
        None => Check::new("config", "Settings", Level::Ok, "valid"),
        Some(problem) => Check::new(
            "config",
            "Settings",
            Level::Problem,
            format!("the config file was changed but can't be used: {problem}"),
        )
        .fix("correct the file, or change settings with `halden config set`; until then the server keeps its old settings"),
    }
}

/// Can this process create files in `dir`?
fn writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".halden-doctor-{}", std::process::id()));
    let created = std::fs::File::create(&probe).is_ok();
    let _ = std::fs::remove_file(&probe);
    created
}

fn folders(config: &Config) -> Check {
    let as_root = crate::setup::running_as_root();
    let mut missing = Vec::new();
    let mut read_only = Vec::new();
    for dir in [
        config.storage.data_dir.clone(),
        config.derived_dir(),
        config.storage.library_dir.clone(),
        config.incoming_dir(),
        config.backup_dir(),
    ] {
        if !dir.is_dir() {
            missing.push(dir.display().to_string());
        } else if !as_root && !writable(&dir) {
            read_only.push(dir.display().to_string());
        }
    }
    if !missing.is_empty() {
        return Check::new(
            "folders",
            "Folders",
            Level::Problem,
            format!("missing: {}", missing.join(", ")),
        )
        .fix("sudo halden setup creates them (is the library disk mounted?)");
    }
    if !read_only.is_empty() {
        return Check::new(
            "folders",
            "Folders",
            Level::Problem,
            format!("not writable: {}", read_only.join(", ")),
        )
        .fix("sudo halden setup gives them to the server's user");
    }
    Check::new("folders", "Folders", Level::Ok, "all there and writable")
}

/// The server writes settings changed in the app to its config file. It replaces the file, so
/// it needs to create files in the file's folder.
fn settings_writable(path: &Path) -> Check {
    let folder = path.parent().unwrap_or(Path::new("/"));
    let ok = if crate::setup::running_as_root() {
        group_may_write(folder)
    } else {
        writable(folder)
    };
    if ok {
        Check::new(
            "settings_file",
            "Settings file",
            Level::Ok,
            "the apps can change settings",
        )
    } else {
        Check::new(
            "settings_file",
            "Settings file",
            Level::Warning,
            format!(
                "the server may not write to {}, so settings can only be changed in the terminal",
                folder.display()
            ),
        )
        .fix("sudo halden setup")
    }
}

/// Run as root: may the server's group create files in `folder`?
fn group_may_write(folder: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    let Ok(meta) = std::fs::metadata(folder) else {
        return false;
    };
    let group = crate::setup::service_ids().map(|(_, gid)| gid);
    group == Some(meta.gid()) && meta.mode() & 0o070 == 0o070
}

fn disks(config: &Config) -> Vec<Check> {
    let mut checks = Vec::new();
    let min_free = config.storage.min_free_gb.saturating_mul(1_000_000_000);
    match (
        fs4::available_space(&config.storage.library_dir),
        fs4::total_space(&config.storage.library_dir),
    ) {
        (Ok(free), Ok(total)) => {
            let detail = format!(
                "{} free of {} on the library disk",
                crate::cli::human_bytes(free),
                crate::cli::human_bytes(total)
            );
            let level = if free <= min_free {
                Level::Problem
            } else if free <= min_free.saturating_mul(2).max(total / 20) {
                Level::Warning
            } else {
                Level::Ok
            };
            let check = Check::new("library_disk", "Library disk", level, detail);
            checks.push(if level == Level::Ok {
                check
            } else if level == Level::Problem {
                check.fix(format!(
                    "uploads are refused below {} GB free (storage.min_free_gb): free up space or use a bigger disk",
                    config.storage.min_free_gb
                ))
            } else {
                check.fix("the disk is nearly full")
            });
        }
        _ => checks.push(
            Check::new(
                "library_disk",
                "Library disk",
                Level::Problem,
                format!("{} is not reachable", config.storage.library_dir.display()),
            )
            .fix("is the disk connected and mounted?"),
        ),
    }
    if let Ok(free) = fs4::available_space(&config.storage.data_dir) {
        let level = if free < 200_000_000 {
            Level::Problem
        } else if free < 2_000_000_000 {
            Level::Warning
        } else {
            Level::Ok
        };
        let mut check = Check::new(
            "data_disk",
            "System disk",
            level,
            format!(
                "{} free for the database and thumbnails",
                crate::cli::human_bytes(free)
            ),
        );
        if level != Level::Ok {
            check = check.fix("the database stops working when this disk is full: free up space");
        }
        checks.push(check);
    }
    checks
}

async fn database_check(db: &Db) -> Check {
    let result: Result<(String,), sqlx::Error> = sqlx::query_as("PRAGMA quick_check")
        .fetch_one(db.read())
        .await;
    match result {
        Ok((answer,)) if answer == "ok" => Check::new("database", "Database", Level::Ok, "intact"),
        Ok((answer,)) => Check::new(
            "database",
            "Database",
            Level::Problem,
            format!("damaged: {answer}"),
        )
        .fix("restore the newest backup: sudo halden backup list, then sudo halden backup restore <file>"),
        Err(error) => Check::new(
            "database",
            "Database",
            Level::Problem,
            format!("can't be read: {error}"),
        ),
    }
}

fn certificate(config: &Config) -> Check {
    let certificates = match crate::tls::load_certificates(&config.cert_path()) {
        Ok(certificates) => certificates,
        Err(error) => {
            return Check::new(
                "certificate",
                "Certificate",
                Level::Problem,
                format!("{error:#}"),
            )
            .fix("sudo halden setup makes a new one (devices then have to be paired again)");
        }
    };
    let Some(first) = certificates.first() else {
        return Check::new(
            "certificate",
            "Certificate",
            Level::Problem,
            "the file is empty",
        );
    };
    let expires = x509_parser::parse_x509_certificate(first.as_ref())
        .ok()
        .map(|(_, cert)| cert.validity().not_after.timestamp());
    let now = db::now_ms() / 1000;
    match expires {
        Some(at) if at <= now => Check::new(
            "certificate",
            "Certificate",
            Level::Problem,
            "expired: the apps can't connect",
        )
        .fix("renew it, then the server picks it up"),
        Some(at) if at - now < 21 * 24 * 60 * 60 => Check::new(
            "certificate",
            "Certificate",
            Level::Warning,
            format!(
                "expires on {}",
                crate::cli::local_time(at.saturating_mul(1000))
            ),
        )
        .fix("renew it soon"),
        Some(at) => Check::new(
            "certificate",
            "Certificate",
            Level::Ok,
            format!(
                "valid until {}",
                crate::cli::local_time(at.saturating_mul(1000))
                    .split(' ')
                    .next()
                    .unwrap_or_default()
            ),
        ),
        None => Check::new(
            "certificate",
            "Certificate",
            Level::Warning,
            "its expiry date could not be read",
        ),
    }
}

async fn tools_check() -> Vec<Check> {
    let found = Tools::find();
    let mut checks = Vec::new();
    match (&found.ffmpeg, &found.ffprobe) {
        (Some(ffmpeg), Some(_)) => {
            let decoders = found
                .output(
                    ffmpeg,
                    &tools::args(&[&"-hide_banner", &"-decoders"]),
                    Duration::from_secs(10),
                )
                .await
                .unwrap_or_default();
            if decoders.contains(" hevc ") {
                checks.push(Check::new(
                    "ffmpeg",
                    "ffmpeg",
                    Level::Ok,
                    "found, reads HEVC videos",
                ));
            } else {
                checks.push(
                    Check::new(
                        "ffmpeg",
                        "ffmpeg",
                        Level::Warning,
                        "found, but it can't read HEVC (iPhone) videos",
                    )
                    .fix("install the distribution's full ffmpeg: sudo apt install ffmpeg"),
                );
            }
        }
        _ => checks.push(
            Check::new(
                "ffmpeg",
                "ffmpeg",
                Level::Warning,
                "not installed: no thumbnails of videos, no video conversions",
            )
            .fix(INSTALL_TOOLS),
        ),
    }
    checks.push(match (&found.heif_dec, &found.heif_enc) {
        (Some(_), Some(_)) => match heic_round_trip(&found).await {
            Ok(()) => Check::new("libheif", "libheif", Level::Ok, "reads and writes HEIC"),
            Err(problem) => Check::new(
                "libheif",
                "libheif",
                Level::Warning,
                format!("installed, but HEIC doesn't work: {problem}"),
            )
            .fix(INSTALL_TOOLS),
        },
        _ => Check::new(
            "libheif",
            "libheif",
            Level::Warning,
            "not installed: no thumbnails of HEIC photos the phone didn't send, no conversions from or to HEIC",
        )
        .fix(INSTALL_TOOLS),
    });
    checks
}

/// Makes a tiny HEIC and reads it back: proves both the HEVC encoder and decoder plugins work.
async fn heic_round_trip(found: &Tools) -> Result<(), String> {
    let (Some(encoder), Some(decoder)) = (&found.heif_enc, &found.heif_dec) else {
        return Err("missing".into());
    };
    let dir = std::env::temp_dir().join(format!(
        "halden-doctor-{}-{}",
        std::process::id(),
        rand::random::<u32>()
    ));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let result = async {
        let png = dir.join("probe.png");
        let heic = dir.join("probe.heic");
        let back = dir.join("back.png");
        image::RgbImage::from_fn(64, 64, |x, y| {
            image::Rgb([(x * 4) as u8, (y * 4) as u8, 128])
        })
        .save(&png)
        .map_err(|e| e.to_string())?;
        let timeout = Duration::from_secs(30);
        let encode: Vec<OsString> = tools::args(&[&png, &"-o", &heic]);
        found
            .run("heif-enc", encoder, &encode, timeout)
            .await
            .map_err(|e| e.to_string())?;
        found
            .run("heif-dec", decoder, &tools::args(&[&heic, &back]), timeout)
            .await
            .map_err(|e| e.to_string())?;
        if back.is_file() {
            Ok(())
        } else {
            Err("no picture came back".to_string())
        }
    }
    .await;
    let _ = std::fs::remove_dir_all(&dir);
    result
}

async fn mirror_check(config: &Config, db: &Db) -> Check {
    let status = mirror::compute_status(db, config).await;
    let folder = config
        .mirror
        .path
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    match status.mirror {
        mirror::MirrorState::None => Check::new(
            "mirror",
            "Mirror",
            Level::Warning,
            "none: every photo exists only once; if the library disk breaks, they are gone",
        )
        .fix("connect a second disk and run: sudo halden mirror set <folder on it>"),
        mirror::MirrorState::Unreachable => Check::new(
            "mirror",
            "Mirror",
            Level::Problem,
            format!("{folder} is not reachable, or its marker file is missing"),
        )
        .fix("connect and mount the disk; the server catches up by itself within an hour"),
        _ if status.mirror_on_same_disk => Check::new(
            "mirror",
            "Mirror",
            Level::Warning,
            format!("{folder} is on the same disk as the library: it protects against nothing"),
        )
        .fix("use a folder on another disk: sudo halden mirror set <folder>"),
        mirror::MirrorState::Behind => Check::new(
            "mirror",
            "Mirror",
            Level::Ok,
            format!("{folder}, {} files still to copy", status.files_waiting),
        ),
        mirror::MirrorState::Ok => {
            Check::new("mirror", "Mirror", Level::Ok, format!("{folder}, complete"))
        }
    }
}

async fn jobs_check(db: &Db) -> Check {
    let failed: Result<Vec<(String, Option<String>)>, sqlx::Error> = sqlx::query_as(
        "SELECT kind, last_error FROM jobs WHERE state = 'failed' ORDER BY updated_at DESC",
    )
    .fetch_all(db.read())
    .await;
    match failed {
        Ok(failed) if failed.is_empty() => {
            Check::new("jobs", "Background jobs", Level::Ok, "none failed")
        }
        Ok(failed) => {
            let (kind, error) = &failed[0];
            Check::new(
                "jobs",
                "Background jobs",
                Level::Warning,
                format!(
                    "{} failed, the newest ({kind}): {}",
                    failed.len(),
                    error.as_deref().unwrap_or("no message")
                ),
            )
            .fix("fix the cause, then try them again in the app (Server › Jobs)")
        }
        Err(error) => Check::new("jobs", "Background jobs", Level::Warning, error.to_string()),
    }
}

fn backups(config: &Config) -> Check {
    match database::list(config).first() {
        None => Check::new(
            "backups",
            "Database backup",
            Level::Warning,
            "none yet (the server makes one when it starts)",
        ),
        Some(newest) if db::now_ms() - newest.made_at > 2 * 24 * 60 * 60 * 1000 => Check::new(
            "backups",
            "Database backup",
            Level::Warning,
            format!(
                "the newest is from {}",
                crate::cli::local_time(newest.made_at)
            ),
        )
        .fix("is the server running? sudo halden backup now makes one"),
        Some(newest) => Check::new(
            "backups",
            "Database backup",
            Level::Ok,
            format!("newest from {}", crate::cli::local_time(newest.made_at)),
        ),
    }
}

fn server_check(config: &Config, options: &Options) -> Check {
    if options.from_server || crate::cli::is_listening(config.server.port) {
        Check::new(
            "server",
            "Server",
            Level::Ok,
            format!("running on port {}", config.server.port),
        )
    } else {
        Check::new(
            "server",
            "Server",
            Level::Warning,
            format!("not running (port {})", config.server.port),
        )
        .fix("sudo systemctl start halden; why it stopped: journalctl -u halden -n 50")
    }
}

async fn clock() -> Vec<Check> {
    let now = chrono::Utc::now();
    use chrono::Datelike;
    if !(2025..2100).contains(&now.year()) {
        return vec![
            Check::new(
                "clock",
                "Clock",
                Level::Problem,
                format!("the computer thinks it is {}", now.format("%Y-%m-%d")),
            )
            .fix("set the time: sudo timedatectl set-ntp true"),
        ];
    }
    if !cfg!(target_os = "linux") {
        return Vec::new();
    }
    let Some(timedatectl) = find_program("timedatectl") else {
        return Vec::new();
    };
    match command_output(&timedatectl, &["show", "-p", "NTPSynchronized", "--value"]).await {
        Some(answer) if answer.trim() == "no" => vec![
            Check::new(
                "clock",
                "Clock",
                Level::Warning,
                "not synchronised with a time server",
            )
            .fix("sudo timedatectl set-ntp true"),
        ],
        _ => vec![Check::new("clock", "Clock", Level::Ok, "right")],
    }
}

/// Under systemd the server may write only to the folders in `ReadWritePaths`.
async fn systemd(config: &Config) -> Vec<Check> {
    if !cfg!(target_os = "linux") || std::env::var_os("HALDEN_IN_DOCKER").is_some() {
        return Vec::new();
    }
    let Some(systemctl) = find_program("systemctl") else {
        return Vec::new();
    };
    let loaded = command_output(
        &systemctl,
        &["show", "halden", "-p", "LoadState", "--value"],
    )
    .await;
    if loaded.as_deref().map(str::trim) != Some("loaded") {
        return Vec::new();
    }
    let allowed = command_output(
        &systemctl,
        &["show", "halden", "-p", "ReadWritePaths", "--value"],
    )
    .await
    .unwrap_or_default();
    let allowed: Vec<PathBuf> = allowed
        .split_whitespace()
        .map(|entry| PathBuf::from(entry.trim_start_matches(['-', '+'])))
        .collect();
    let mut needed = vec![
        config.storage.data_dir.clone(),
        config.storage.library_dir.clone(),
    ];
    needed.extend(config.mirror.path.clone());
    let missing: Vec<String> = needed
        .iter()
        .filter(|path| !allowed.iter().any(|ok| path.starts_with(ok)))
        .map(|path| path.display().to_string())
        .collect();
    if missing.is_empty() {
        vec![Check::new(
            "systemd",
            "Service",
            Level::Ok,
            "may write to all its folders",
        )]
    } else {
        vec![
            Check::new(
                "systemd",
                "Service",
                Level::Problem,
                format!("may not write to {}", missing.join(", ")),
            )
            .fix(format!(
                "sudo systemctl edit halden, add\n[Service]\nReadWritePaths={}\nthen sudo systemctl restart halden",
                missing.join(" ")
            )),
        ]
    }
}

/// With ufw switched on, the port must be open for the apps.
async fn firewall(config: &Config) -> Vec<Check> {
    if !cfg!(target_os = "linux") || !crate::setup::running_as_root() {
        return Vec::new();
    }
    let Some(ufw) = find_program("ufw") else {
        return Vec::new();
    };
    let Some(status) = command_output(&ufw, &["status"]).await else {
        return Vec::new();
    };
    if !status.contains("Status: active") {
        return Vec::new();
    }
    let port = config.server.port.to_string();
    if status.lines().any(|line| {
        line.split_whitespace()
            .next()
            .is_some_and(|rule| rule.split('/').next() == Some(port.as_str()))
    }) {
        vec![Check::new(
            "firewall",
            "Firewall",
            Level::Ok,
            format!("port {port} is open"),
        )]
    } else {
        vec![
            Check::new(
                "firewall",
                "Firewall",
                Level::Problem,
                format!("ufw blocks port {port}: the apps can't connect"),
            )
            .fix(format!(
                "sudo ufw allow {port}/tcp && sudo ufw allow 5353/udp"
            )),
        ]
    }
}

fn find_program(name: &str) -> Option<PathBuf> {
    ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"]
        .iter()
        .map(|dir| Path::new(dir).join(name))
        .find(|path| path.is_file())
}

async fn command_output(program: &Path, args: &[&str]) -> Option<String> {
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(10), command.output())
        .await
        .ok()?
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// What [`verify_files`] found.
#[derive(Debug, Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileReport {
    pub checked: u64,
    pub bytes: u64,
    /// Recorded in the database but not on the disk.
    pub missing: Vec<String>,
    /// On the disk, but different from what arrived.
    pub damaged: Vec<String>,
    /// In the library folder but not in the database (not counting `.halden`).
    pub unknown: Vec<String>,
    pub mirror_checked: u64,
    pub mirror_missing: Vec<String>,
    pub mirror_damaged: Vec<String>,
}

impl FileReport {
    /// Nothing missing or damaged anywhere.
    pub fn intact(&self) -> bool {
        self.missing.is_empty()
            && self.damaged.is_empty()
            && self.mirror_missing.is_empty()
            && self.mirror_damaged.is_empty()
    }
}

/// Reads every file of the library, the thumbnails and the mirror and compares it with its
/// recorded SHA-256. `progress(done, total)` is called now and then.
pub async fn verify_files(
    config: &Config,
    db: &Db,
    progress: impl Fn(u64, u64) + Send + 'static,
) -> Result<FileReport> {
    let files: Vec<(String, String, Vec<u8>)> = sqlx::query_as(
        "SELECT f.storage, f.path, f.sha256 FROM asset_files f \
         JOIN assets a ON a.id = f.asset_id WHERE a.deleted_at IS NULL",
    )
    .fetch_all(db.read())
    .await?;
    let mirrored: Vec<(String, Vec<u8>)> = sqlx::query_as("SELECT path, sha256 FROM mirror_files")
        .fetch_all(db.read())
        .await?;
    let library = config.storage.library_dir.clone();
    let derived = config.derived_dir();
    let mirror = config
        .mirror
        .path
        .clone()
        .filter(|root| mirror::reachable(root));
    tokio::task::spawn_blocking(move || {
        let total = (files.len() + if mirror.is_some() { mirrored.len() } else { 0 }) as u64;
        let mut report = FileReport::default();
        let mut known = HashSet::new();
        let mut done = 0u64;
        for (storage, relative, expected) in &files {
            let root = if storage == "library" {
                &library
            } else {
                &derived
            };
            if storage == "library" {
                known.insert(relative.clone());
            }
            match hash_file(&root.join(relative)) {
                Ok((hash, size)) => {
                    report.checked += 1;
                    report.bytes += size;
                    if hash.as_slice() != expected.as_slice() {
                        report.damaged.push(relative.clone());
                    }
                }
                Err(_) => report.missing.push(relative.clone()),
            }
            done += 1;
            if done.is_multiple_of(100) {
                progress(done, total);
            }
        }
        if let Some(root) = &mirror {
            for (relative, expected) in &mirrored {
                match hash_file(&root.join(relative)) {
                    Ok((hash, _)) => {
                        report.mirror_checked += 1;
                        if hash.as_slice() != expected.as_slice() {
                            report.mirror_damaged.push(relative.clone());
                        }
                    }
                    Err(_) => report.mirror_missing.push(relative.clone()),
                }
                done += 1;
                if done.is_multiple_of(100) {
                    progress(done, total);
                }
            }
        }
        progress(done, total);
        report.unknown = unknown_files(&library, &known);
        report
    })
    .await
    .map_err(|join| anyhow::anyhow!(join.to_string()))
}

fn hash_file(path: &Path) -> std::io::Result<([u8; 32], u64)> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    let mut size = 0u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        size += read as u64;
    }
    Ok((hasher.finalize().into(), size))
}

/// Files in the library the database doesn't know, relative to the library. Halden's own
/// folder and hidden files (`.DS_Store`, the mirror marker) don't count.
fn unknown_files(library: &Path, known: &HashSet<String>) -> Vec<String> {
    let mut unknown = Vec::new();
    let mut folders = vec![library.to_path_buf()];
    while let Some(folder) = folders.pop() {
        let Ok(entries) = std::fs::read_dir(&folder) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => folders.push(path),
                Ok(kind) if kind.is_file() => {
                    if let Ok(relative) = path.strip_prefix(library) {
                        let relative = relative.to_string_lossy().into_owned();
                        if !known.contains(&relative) {
                            unknown.push(relative);
                        }
                    }
                }
                _ => {}
            }
        }
    }
    unknown.sort();
    unknown
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_fresh_setup_has_no_problems() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        crate::setup::run(
            &config_path,
            crate::setup::SetupOptions {
                data_dir: Some(dir.path().join("data")),
                library_dir: Some(dir.path().join("library")),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        let config = Config::load(&config_path).unwrap();
        let db = Db::open(&config.db_path()).await.unwrap();
        let report = check(
            &config,
            Some(&db),
            &Options {
                config_path: Some(config_path),
                ..Default::default()
            },
        )
        .await;
        let problems: Vec<&Check> = report
            .checks
            .iter()
            .filter(|c| c.level == Level::Problem)
            .collect();
        assert!(problems.is_empty(), "{problems:#?}");
        let ids: Vec<&str> = report.checks.iter().map(|c| c.id).collect();
        for id in [
            "config",
            "folders",
            "settings_file",
            "library_disk",
            "database",
            "certificate",
            "mirror",
            "jobs",
        ] {
            assert!(ids.contains(&id), "{id} missing in {ids:?}");
        }
        // No mirror: a warning, with a fix.
        let mirror = report.checks.iter().find(|c| c.id == "mirror").unwrap();
        assert_eq!(mirror.level, Level::Warning);
        assert!(mirror.fix.is_some());

        let broken = check(
            &config,
            Some(&db),
            &Options {
                config_problem: Some("trash_days: invalid type".into()),
                ..Default::default()
            },
        )
        .await;
        assert_eq!(broken.level, Level::Problem);
        db.close().await;
    }

    #[test]
    fn unknown_files_skip_halden_and_hidden_files() {
        let dir = tempfile::tempdir().unwrap();
        let library = dir.path();
        std::fs::create_dir_all(library.join("lucas/2026/11")).unwrap();
        std::fs::create_dir_all(library.join(".halden/incoming")).unwrap();
        std::fs::write(library.join("lucas/2026/11/a.heic"), b"a").unwrap();
        std::fs::write(library.join("lucas/2026/11/stray.jpg"), b"b").unwrap();
        std::fs::write(library.join(".halden/incoming/x.part"), b"c").unwrap();
        std::fs::write(library.join("lucas/.DS_Store"), b"d").unwrap();
        let known = HashSet::from(["lucas/2026/11/a.heic".to_string()]);
        assert_eq!(
            unknown_files(library, &known),
            vec!["lucas/2026/11/stray.jpg"]
        );
    }
}
