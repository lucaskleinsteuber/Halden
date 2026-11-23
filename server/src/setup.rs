//! `halden setup`: creates the config, folders, certificate and database.
//!
//! Running it again is safe: existing files are kept, missing pieces are added.

use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use uuid::Uuid;

use crate::{
    accounts,
    config::Config,
    db, fsutil,
    tls::{self, Fingerprint},
};

/// The system user the packaged server runs as.
pub const SERVICE_USER: &str = "halden";

#[derive(Debug, Default, Clone)]
pub struct SetupOptions {
    pub name: Option<String>,
    pub data_dir: Option<PathBuf>,
    pub library_dir: Option<PathBuf>,
    pub port: Option<u16>,
    /// Hand the folders to this system user. Defaults to `halden` when run as root and that
    /// user exists.
    pub service_user: Option<String>,
}

impl SetupOptions {
    fn changes_anything(&self) -> bool {
        self.name.is_some()
            || self.data_dir.is_some()
            || self.library_dir.is_some()
            || self.port.is_some()
    }
}

#[derive(Debug)]
pub struct SetupReport {
    pub config_path: PathBuf,
    pub config: Config,
    pub config_created: bool,
    pub identity_created: bool,
    pub server_id: Uuid,
    pub fingerprint: Fingerprint,
    /// System user that now owns the folders, if any.
    pub owner: Option<String>,
    /// Is there at least one account? If not, the terminal offers to create the first owner.
    pub has_accounts: bool,
    pub warnings: Vec<String>,
}

pub async fn run(config_path: &Path, options: SetupOptions) -> Result<SetupReport> {
    let mut warnings = Vec::new();

    let (config, config_created) = if config_path.exists() {
        if options.changes_anything() {
            bail!(
                "{} already exists. Change settings there (then restart the server), \
                 or delete it to set up from scratch",
                config_path.display()
            );
        }
        (Config::load(config_path)?, false)
    } else {
        let mut config = Config::default();
        if let Some(name) = options.name.clone() {
            config.server.name = name;
        }
        if let Some(dir) = options.data_dir.clone() {
            config.storage.data_dir = dir;
        }
        if let Some(dir) = options.library_dir.clone() {
            config.storage.library_dir = dir;
        }
        if let Some(port) = options.port {
            config.server.port = port;
        }
        config.validate()?;
        if let Some(parent) = config_path.parent()
            && !parent.exists()
        {
            fsutil::create_dir(parent, 0o755)?;
        }
        config.save(config_path)?;
        (config, true)
    };

    fsutil::create_dir(&config.storage.data_dir, 0o700)?;
    fsutil::create_dir(&config.derived_dir(), 0o700)?;
    if !config.storage.library_dir.exists() {
        fsutil::create_dir(&config.storage.library_dir, 0o750)?;
    }
    fsutil::create_dir(&config.library_meta_dir(), 0o700)?;
    fsutil::create_dir(&config.incoming_dir(), 0o700)?;
    fsutil::create_dir(&config.backup_dir(), 0o700)?;

    let identity_created = tls::ensure_identity(&config)?;
    let fingerprint = tls::identity_fingerprint(&config)?;

    let pool = db::Db::open(&config.db_path()).await?;
    let server_id = db::server_id(&pool).await?;
    let has_accounts = accounts::count_users(&pool).await? > 0;
    pool.close().await;

    let owner = hand_over(
        &config,
        config_path,
        options.service_user.as_deref(),
        &mut warnings,
    )?;

    Ok(SetupReport {
        config_path: config_path.to_path_buf(),
        config,
        config_created,
        identity_created,
        server_id,
        fingerprint,
        owner,
        has_accounts,
        warnings,
    })
}

/// When setup runs as root, gives the server's folders to the service user so the server
/// itself never needs root. The config stays owned by root but readable by the user's group.
fn hand_over(
    config: &Config,
    config_path: &Path,
    requested: Option<&str>,
    warnings: &mut Vec<String>,
) -> Result<Option<String>> {
    let as_root = fs::metadata(&config.storage.data_dir)
        .map(|m| m.uid() == 0)
        .unwrap_or(false)
        && running_as_root();

    let user = match requested {
        Some(user) => user.to_string(),
        None if as_root => {
            if lookup_user(SERVICE_USER)?.is_none() {
                warnings.push(format!(
                    "There is no system user `{SERVICE_USER}`, so the folders belong to root. \
                     Create it with `sudo useradd --system --home {} --shell /usr/sbin/nologin {SERVICE_USER}` \
                     and run setup again.",
                    config.storage.data_dir.display()
                ));
                return Ok(None);
            }
            SERVICE_USER.to_string()
        }
        None => return Ok(None),
    };

    let Some((uid, gid)) = lookup_user(&user)? else {
        bail!("the system user `{user}` does not exist");
    };
    if !as_root {
        bail!("handing the folders to `{user}` needs root; run setup with sudo");
    }

    chown_tree(&config.storage.data_dir, uid, gid)?;
    chown_tree(&config.library_meta_dir(), uid, gid)?;
    std::os::unix::fs::chown(&config.storage.library_dir, Some(uid), Some(gid)).with_context(
        || {
            format!(
                "could not hand over {}",
                config.storage.library_dir.display()
            )
        },
    )?;
    std::os::unix::fs::chown(config_path, Some(0), Some(gid))
        .with_context(|| format!("could not hand over {}", config_path.display()))?;
    fs::set_permissions(config_path, fs::Permissions::from_mode(0o640))?;
    // The server saves settings changed in the apps by replacing the config file, so its group
    // may create files in the config's own folder (`/etc/halden`), and nowhere else in /etc.
    if let Some(folder) = config_path.parent()
        && folder.file_name().is_some_and(|name| name == "halden")
    {
        std::os::unix::fs::chown(folder, Some(0), Some(gid))
            .with_context(|| format!("could not hand over {}", folder.display()))?;
        fs::set_permissions(folder, fs::Permissions::from_mode(0o770))?;
    } else {
        warnings.push(
            "The config file is not in a folder of its own (like /etc/halden), so the apps can't \
             change settings; use `halden config set` here instead."
                .to_string(),
        );
    }
    Ok(Some(user))
}

/// After a terminal command ran as root (`sudo halden user add …`), SQLite may have created the
/// database's side files (`halden.db-wal`, `halden.db-shm`) owned by root, and the server, which
/// runs as the service user, could then no longer open the database. This gives them back to
/// whoever owns the data folder.
pub fn give_database_back(config: &Config) -> Result<()> {
    if !running_as_root() {
        return Ok(());
    }
    let folder = fs::metadata(&config.storage.data_dir)
        .with_context(|| format!("could not read {}", config.storage.data_dir.display()))?;
    if folder.uid() == 0 {
        return Ok(());
    }
    let db = config.db_path();
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut name = db.clone().into_os_string();
        name.push(suffix);
        let path = PathBuf::from(name);
        match fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_file() && meta.uid() == 0 => {
                std::os::unix::fs::chown(&path, Some(folder.uid()), Some(folder.gid()))
                    .with_context(|| format!("could not hand over {}", path.display()))?;
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn running_as_root() -> bool {
    fs::metadata("/proc/self")
        .map(|m| m.uid() == 0)
        .unwrap_or(false)
}

#[cfg(not(target_os = "linux"))]
pub fn running_as_root() -> bool {
    false
}

/// (uid, gid) of the system user the packaged server runs as, if it exists.
pub fn service_ids() -> Option<(u32, u32)> {
    lookup_user(SERVICE_USER).ok().flatten()
}

/// (uid, gid) of a system user, from `/etc/passwd`.
fn lookup_user(name: &str) -> Result<Option<(u32, u32)>> {
    let passwd = match fs::read_to_string("/etc/passwd") {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).context("could not read /etc/passwd"),
    };
    Ok(parse_passwd(&passwd, name))
}

fn parse_passwd(passwd: &str, name: &str) -> Option<(u32, u32)> {
    passwd.lines().find_map(|line| {
        let mut fields = line.split(':');
        (fields.next()? == name).then_some(())?;
        let _password = fields.next()?;
        let uid = fields.next()?.parse().ok()?;
        let gid = fields.next()?.parse().ok()?;
        Some((uid, gid))
    })
}

/// Changes the owner of a folder and everything in it. Symbolic links are skipped, never
/// followed, so a link can't trick setup into changing files elsewhere.
fn chown_tree(path: &Path, uid: u32, gid: u32) -> Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Ok(());
    }
    std::os::unix::fs::chown(path, Some(uid), Some(gid))
        .with_context(|| format!("could not hand over {}", path.display()))?;
    if meta.is_dir() {
        for entry in fs::read_dir(path)? {
            chown_tree(&entry?.path(), uid, gid)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passwd_parsing() {
        let passwd = "root:x:0:0:root:/root:/bin/bash\nhalden:x:998:997::/var/lib/halden:/usr/sbin/nologin\n";
        assert_eq!(parse_passwd(passwd, "halden"), Some((998, 997)));
        assert_eq!(parse_passwd(passwd, "root"), Some((0, 0)));
        assert_eq!(parse_passwd(passwd, "hal"), None);
    }
}
