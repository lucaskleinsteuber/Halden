//! Database backups. Once a day (and before a restore) the server writes a complete, consistent
//! copy of the database with `VACUUM INTO` to `<library>/.halden/backups/`, on the big disk: if
//! the system disk dies, the library disk holds everything needed to start again. Each copy is
//! flushed to disk and checked (`PRAGMA quick_check`) before it counts; the newest
//! `[backup] keep` (default 14) are kept.

use std::{
    path::{Path, PathBuf},
    str::FromStr,
};

use anyhow::{Context, Result, bail};
use sqlx::{ConnectOptions, Connection, sqlite::SqliteConnectOptions};

use crate::{config::Config, db::Db, fsutil};

#[derive(Debug, Clone)]
pub struct BackupFile {
    pub path: PathBuf,
    pub name: String,
    pub size: u64,
    /// Unix milliseconds.
    pub made_at: i64,
}

fn made_at(path: &Path) -> i64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as i64)
}

/// The backups in a folder, newest first.
pub fn list_in(folder: &Path) -> Vec<BackupFile> {
    let mut found: Vec<BackupFile> = std::fs::read_dir(folder)
        .map(|entries| {
            entries
                .flatten()
                .filter_map(|entry| {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    (name.starts_with("halden-") && name.ends_with(".db")).then(|| BackupFile {
                        size: entry.metadata().map_or(0, |m| m.len()),
                        made_at: made_at(&entry.path()),
                        path: entry.path(),
                        name,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    // The names hold the time, so sorting by name sorts by age.
    found.sort_by(|a, b| b.name.cmp(&a.name));
    found
}

pub fn list(config: &Config) -> Vec<BackupFile> {
    list_in(&config.backup_dir())
}

/// Keeps the newest `keep` backups in a folder and deletes the rest.
pub fn prune(folder: &Path, keep: u32) -> usize {
    let mut removed = 0;
    for old in list_in(folder).into_iter().skip(keep.max(1) as usize) {
        if std::fs::remove_file(&old.path).is_ok() {
            removed += 1;
        }
    }
    removed
}

/// Checks a database file: SQLite's own consistency check must say "ok".
pub async fn check(path: &Path) -> Result<()> {
    let mut connection = SqliteConnectOptions::from_str(&format!("sqlite://{}", path.display()))?
        .read_only(true)
        .connect()
        .await
        .with_context(|| format!("could not open {}", path.display()))?;
    let (result,): (String,) = sqlx::query_as("PRAGMA quick_check")
        .fetch_one(&mut connection)
        .await?;
    connection.close().await?;
    if result != "ok" {
        bail!("{} is damaged: {result}", path.display());
    }
    Ok(())
}

/// Makes a backup now. It runs on its own connection, so uploads and the library keep working
/// while it is written.
pub async fn make(db: &Db, config: &Config) -> Result<BackupFile> {
    let folder = config.backup_dir();
    fsutil::create_dir(&folder, 0o700)?;
    let name = format!(
        "halden-{}.db",
        chrono::Local::now().format("%Y-%m-%d_%H-%M-%S")
    );
    let target = folder.join(&name);
    let partial = folder.join(format!(".{name}.tmp"));
    let _ = std::fs::remove_file(&partial);

    let mut connection = SqliteConnectOptions::new()
        .filename(db.path())
        .busy_timeout(std::time::Duration::from_secs(30))
        .connect()
        .await
        .context("could not open the database for a backup")?;
    let result = sqlx::query("VACUUM INTO ?")
        .bind(partial.to_string_lossy().into_owned())
        .execute(&mut connection)
        .await;
    connection.close().await.ok();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&partial);
        return Err(error).context("could not write the database backup");
    }

    let flushed = partial.clone();
    tokio::task::spawn_blocking(move || -> std::io::Result<()> {
        std::fs::File::open(&flushed)?.sync_all()
    })
    .await??;
    if let Err(error) = check(&partial).await {
        let _ = std::fs::remove_file(&partial);
        return Err(error);
    }
    std::fs::rename(&partial, &target)?;
    fsutil::sync_dir(&folder)?;
    prune(&folder, config.backup.keep);
    let size = std::fs::metadata(&target).map_or(0, |m| m.len());
    Ok(BackupFile {
        made_at: made_at(&target),
        path: target,
        name,
        size,
    })
}

/// Puts a backup in place of the database. The server must be stopped (the data-folder lock
/// proves it). The current database is set aside first, as `halden.db.before-restore-<time>`.
/// Returns where it went.
pub async fn restore(config: &Config, backup: &Path) -> Result<PathBuf> {
    let _lock = fsutil::lock_data_dir(&config.storage.data_dir)?;
    check(backup)
        .await
        .context("the backup can't be restored")?;
    let db_path = config.db_path();

    // Fold the write-ahead log into the database file, so the copy set aside is complete.
    if db_path.exists() {
        let mut connection = SqliteConnectOptions::new()
            .filename(&db_path)
            .connect()
            .await?;
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .execute(&mut connection)
            .await?;
        connection.close().await?;
    }
    let aside = config.storage.data_dir.join(format!(
        "halden.db.before-restore-{}",
        chrono::Local::now().format("%Y-%m-%d_%H-%M-%S")
    ));
    if db_path.exists() {
        std::fs::copy(&db_path, &aside)
            .with_context(|| format!("could not set the database aside to {}", aside.display()))?;
    }

    let incoming = config.storage.data_dir.join(".halden.db.restore.tmp");
    std::fs::copy(backup, &incoming)?;
    std::fs::File::open(&incoming)?.sync_all()?;
    for suffix in ["-wal", "-shm"] {
        let mut side = db_path.clone().into_os_string();
        side.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(side));
    }
    std::fs::rename(&incoming, &db_path)?;
    fsutil::sync_dir(&config.storage.data_dir)?;

    // An older backup gets the newer tables now.
    let db = Db::open(&db_path).await?;
    db.close().await;
    Ok(aside)
}

/// A backup is made at start and then every day; this says whether one is due.
pub fn due(config: &Config, now_ms: i64) -> bool {
    list(config)
        .first()
        .is_none_or(|newest| now_ms - newest.made_at > 23 * 60 * 60 * 1000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn backups_are_complete_checked_and_pruned() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.storage.data_dir = dir.path().join("data");
        config.storage.library_dir = dir.path().join("library");
        config.backup.keep = 2;
        std::fs::create_dir_all(&config.storage.data_dir).unwrap();
        let db = Db::open(&config.db_path()).await.unwrap();
        let id = crate::db::server_id(&db).await.unwrap();

        let first = make(&db, &config).await.unwrap();
        assert!(first.size > 0);
        check(&first.path).await.unwrap();
        assert!(!due(&config, crate::db::now_ms()));
        // Names carry the time to the second; make sure the next ones differ.
        for _ in 0..2 {
            tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
            make(&db, &config).await.unwrap();
        }
        let kept = list(&config);
        assert_eq!(kept.len(), 2, "only the newest two are kept");
        assert!(kept[0].name > kept[1].name);

        let copy = Db::open(&kept[0].path).await.unwrap();
        assert_eq!(crate::db::server_id(&copy).await.unwrap(), id);
        copy.close().await;

        std::fs::write(dir.path().join("broken.db"), b"not a database").unwrap();
        assert!(check(&dir.path().join("broken.db")).await.is_err());
        db.close().await;
    }
}
