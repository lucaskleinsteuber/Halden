//! The mirror: a second copy of every original, conversion and database backup on another disk
//! (a USB disk, a mounted NAS folder), in the same readable layout as the library.
//!
//! Each file is copied to a temporary name, flushed, read back and compared by SHA-256, and only
//! then renamed into place and recorded. A marker file (`.halden-mirror`, written by
//! `halden mirror set`) must be in the mirror folder: if the USB disk is not plugged in, its
//! mount point is an empty folder on the system disk, and without the marker Halden won't fill
//! the system disk with copies. Every new file is mirrored right after its upload; an hourly
//! sweep catches up with whatever was missed while the mirror was away.

use std::{
    io::{Read, Write},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::RwLock,
};

use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::{
    config::Config,
    db::{Db, now_ms},
    fsutil,
    jobs::{self, JobKind},
    library::paths,
};

pub const MARKER: &str = ".halden-mirror";
const COPY_BUFFER: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MirrorState {
    /// No mirror set up: everything exists only once.
    None,
    /// Every file is mirrored.
    Ok,
    /// Copies are still being made.
    Behind,
    /// The mirror folder is missing or not marked (disk unplugged?).
    Unreachable,
}

/// What the apps show about backups. Kept in memory and refreshed in the background, so asking
/// for it costs nothing.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BackupStatus {
    pub mirror: MirrorState,
    /// True as long as there is no working mirror: a broken library disk would lose photos.
    pub only_one_copy: bool,
    pub files_waiting: i64,
    /// The mirror is on the same disk as the library, so it protects against nothing.
    pub mirror_on_same_disk: bool,
    pub last_database_backup_at: Option<i64>,
}

impl Default for BackupStatus {
    fn default() -> Self {
        Self {
            mirror: MirrorState::None,
            only_one_copy: true,
            files_waiting: 0,
            mirror_on_same_disk: false,
            last_database_backup_at: None,
        }
    }
}

#[derive(Default)]
pub struct StatusCell(RwLock<BackupStatus>);

impl StatusCell {
    pub fn get(&self) -> BackupStatus {
        self.0.read().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn set(&self, status: BackupStatus) {
        if let Ok(mut current) = self.0.write() {
            *current = status;
        }
    }
}

pub fn reachable(root: &Path) -> bool {
    root.join(MARKER).is_file()
}

/// Are both folders on the same file system (the same disk)?
pub fn same_disk(a: &Path, b: &Path) -> bool {
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev(),
        _ => false,
    }
}

/// Copies `source` to `<root>/<relative>`, checking the source against `expected` on the way and
/// the copy after flushing it. Runs blocking; call it from a background thread.
pub fn copy_checked(
    source: &Path,
    root: &Path,
    relative: &str,
    expected: &[u8],
) -> Result<(), String> {
    let target = paths::resolve(root, relative).ok_or("invalid path")?;
    let folder = target.parent().ok_or("no folder")?.to_path_buf();
    std::fs::create_dir_all(&folder)
        .map_err(|e| format!("could not create {}: {e}", folder.display()))?;
    let partial = folder.join(format!(
        ".{}.halden-tmp",
        target
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    ));

    let result = (|| -> Result<(), String> {
        let mut input = std::fs::File::open(source).map_err(|e| e.to_string())?;
        let mut output = std::fs::File::create(&partial).map_err(|e| e.to_string())?;
        let mut buffer = vec![0u8; COPY_BUFFER];
        let mut hasher = Sha256::new();
        loop {
            let read = input.read(&mut buffer).map_err(|e| e.to_string())?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            output
                .write_all(&buffer[..read])
                .map_err(|e| e.to_string())?;
        }
        if hasher.finalize().as_slice() != expected {
            return Err("the library file does not match its recorded hash".into());
        }
        output.sync_all().map_err(|e| e.to_string())?;
        drop(output);

        let mut check = std::fs::File::open(&partial).map_err(|e| e.to_string())?;
        let mut hasher = Sha256::new();
        loop {
            let read = check.read(&mut buffer).map_err(|e| e.to_string())?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        if hasher.finalize().as_slice() != expected {
            return Err("the copy on the mirror is damaged".into());
        }
        std::fs::rename(&partial, &target).map_err(|e| e.to_string())?;
        fsutil::sync_dir(&folder).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&partial);
    }
    result
}

/// Copies an asset's library files that the mirror doesn't have yet (or has with other content).
pub async fn mirror_asset(ctx: &jobs::JobContext, asset_id: &str) -> Result<(), String> {
    let Some(root) = ctx.mirror.as_ref() else {
        return Ok(());
    };
    if !reachable(root) {
        return Err(format!(
            "the mirror {} is not reachable (is the disk connected?)",
            root.display()
        ));
    }
    let missing: Vec<(String, Vec<u8>, String)> = sqlx::query_as(
        "SELECT f.role, f.sha256, f.path FROM asset_files f \
         LEFT JOIN mirror_files m ON m.asset_id = f.asset_id AND m.role = f.role \
             AND m.sha256 = f.sha256 \
         WHERE f.asset_id = ? AND f.storage = 'library' AND m.asset_id IS NULL",
    )
    .bind(asset_id)
    .fetch_all(ctx.db.read())
    .await
    .map_err(|e| e.to_string())?;
    for (role, sha256, path) in missing {
        let source = paths::resolve(&ctx.library, &path).ok_or("invalid library path")?;
        let (root_copy, relative, expected) = (root.clone(), path.clone(), sha256.clone());
        ctx.background
            .run(move || copy_checked(&source, &root_copy, &relative, &expected))
            .await
            .ok_or("copying to the mirror crashed")??;
        sqlx::query(
            "INSERT INTO mirror_files (asset_id, role, sha256, path, copied_at) VALUES (?, ?, ?, ?, ?) \
             ON CONFLICT (asset_id, role) DO UPDATE SET sha256 = excluded.sha256, \
                 path = excluded.path, copied_at = excluded.copied_at",
        )
        .bind(asset_id)
        .bind(&role)
        .bind(&sha256)
        .bind(&path)
        .bind(now_ms())
        .execute(ctx.db.write())
        .await
        .map_err(|e| e.to_string())?;
    }
    // Copies of files the library no longer has (an old conversion) go too.
    let stale: Vec<(String, String)> = sqlx::query_as(
        "SELECT m.role, m.path FROM mirror_files m \
         LEFT JOIN asset_files f ON f.asset_id = m.asset_id AND f.role = m.role \
             AND f.sha256 = m.sha256 \
         WHERE m.asset_id = ? AND f.asset_id IS NULL",
    )
    .bind(asset_id)
    .fetch_all(ctx.db.read())
    .await
    .map_err(|e| e.to_string())?;
    for (role, path) in stale {
        let live: Option<(i64,)> =
            sqlx::query_as("SELECT 1 FROM asset_files WHERE storage = 'library' AND path = ?")
                .bind(&path)
                .fetch_optional(ctx.db.read())
                .await
                .map_err(|e| e.to_string())?;
        if live.is_none()
            && let Some(full) = paths::resolve(root, &path)
        {
            let _ = tokio::fs::remove_file(full).await;
        }
        sqlx::query("DELETE FROM mirror_files WHERE asset_id = ? AND role = ?")
            .bind(asset_id)
            .bind(role)
            .execute(ctx.db.write())
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Library files the mirror doesn't have with the right content.
pub async fn waiting(db: &Db) -> Result<i64, sqlx::Error> {
    let (count,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM asset_files f \
         LEFT JOIN mirror_files m ON m.asset_id = f.asset_id AND m.role = f.role \
             AND m.sha256 = f.sha256 \
         WHERE f.storage = 'library' AND m.asset_id IS NULL",
    )
    .fetch_one(db.read())
    .await?;
    Ok(count)
}

/// Queues a mirror job for every asset with files the mirror is missing. Returns how many.
pub async fn sweep(db: &Db) -> Result<u64, sqlx::Error> {
    let assets: Vec<(String, String)> = sqlx::query_as(
        "SELECT DISTINCT f.asset_id, f.user_id FROM asset_files f \
         LEFT JOIN mirror_files m ON m.asset_id = f.asset_id AND m.role = f.role \
             AND m.sha256 = f.sha256 \
         WHERE f.storage = 'library' AND m.asset_id IS NULL",
    )
    .fetch_all(db.read())
    .await?;
    if assets.is_empty() {
        return Ok(0);
    }
    let mut tx = db.begin().await?;
    for (asset_id, user_id) in &assets {
        jobs::enqueue(&mut tx, JobKind::Mirror, asset_id, user_id, 0).await?;
    }
    tx.commit().await?;
    Ok(assets.len() as u64)
}

/// Copies a database backup to the mirror and keeps the same number there.
pub async fn mirror_backup(config: &Config, backup: &Path) -> Result<(), String> {
    let Some(root) = config.mirror.path.clone() else {
        return Ok(());
    };
    if !reachable(&root) {
        return Err("the mirror is not reachable".into());
    }
    let name = backup
        .file_name()
        .ok_or("no file name")?
        .to_string_lossy()
        .into_owned();
    let relative = format!(".halden/backups/{name}");
    let source = backup.to_path_buf();
    let keep = config.backup.keep;
    tokio::task::spawn_blocking(move || -> Result<(), String> {
        let expected = {
            let mut file = std::fs::File::open(&source).map_err(|e| e.to_string())?;
            let mut hasher = Sha256::new();
            let mut buffer = vec![0u8; COPY_BUFFER];
            loop {
                let read = file.read(&mut buffer).map_err(|e| e.to_string())?;
                if read == 0 {
                    break;
                }
                hasher.update(&buffer[..read]);
            }
            hasher.finalize()
        };
        copy_checked(&source, &root, &relative, &expected)?;
        crate::backup::database::prune(&root.join(".halden/backups"), keep);
        Ok(())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Works out the backup status (one count query; run in the background, not per request).
pub async fn compute_status(db: &Db, config: &Config) -> BackupStatus {
    let last_database_backup_at = crate::backup::database::list(config)
        .first()
        .map(|b| b.made_at);
    let Some(root) = &config.mirror.path else {
        return BackupStatus {
            last_database_backup_at,
            ..BackupStatus::default()
        };
    };
    let on_same_disk = same_disk(root, &config.storage.library_dir);
    if !reachable(root) {
        return BackupStatus {
            mirror: MirrorState::Unreachable,
            only_one_copy: true,
            files_waiting: waiting(db).await.unwrap_or(0),
            mirror_on_same_disk: on_same_disk,
            last_database_backup_at,
        };
    }
    let files_waiting = waiting(db).await.unwrap_or(0);
    BackupStatus {
        mirror: if files_waiting == 0 {
            MirrorState::Ok
        } else {
            MirrorState::Behind
        },
        only_one_copy: on_same_disk,
        files_waiting,
        mirror_on_same_disk: on_same_disk,
        last_database_backup_at,
    }
}

/// Removes an asset's copies from the mirror (it was deleted for good).
pub async fn forget(db: &Db, root: Option<&Path>, asset_id: &str) -> Result<(), sqlx::Error> {
    let copies: Vec<(String,)> = sqlx::query_as("SELECT path FROM mirror_files WHERE asset_id = ?")
        .bind(asset_id)
        .fetch_all(db.read())
        .await?;
    sqlx::query("DELETE FROM mirror_files WHERE asset_id = ?")
        .bind(asset_id)
        .execute(db.write())
        .await?;
    if let Some(root) = root.filter(|root| reachable(root)) {
        for (path,) in copies {
            if let Some(full) = paths::resolve(root, &path) {
                let _ = tokio::fs::remove_file(full).await;
            }
        }
    }
    Ok(())
}

/// Checks a folder and makes it the mirror: it must exist, be writable, and not be the library.
/// Writes the marker file.
pub fn prepare(folder: &Path, library: &Path) -> anyhow::Result<PathBuf> {
    let folder = folder
        .canonicalize()
        .map_err(|e| anyhow::anyhow!("{}: {e}", folder.display()))?;
    if !folder.is_dir() {
        anyhow::bail!("{} is not a folder", folder.display());
    }
    if let Ok(library) = library.canonicalize()
        && (folder.starts_with(&library) || library.starts_with(&folder))
    {
        anyhow::bail!("the mirror must not be inside the library (or the other way round)");
    }
    fsutil::write_atomic(
        &folder.join(MARKER),
        b"This folder is the mirror of a Halden library. Don't delete this file.\n",
        0o644,
    )?;
    Ok(folder)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copies_are_checked() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("photo.heic");
        std::fs::write(&source, b"the photo").unwrap();
        let mirror = dir.path().join("mirror");
        std::fs::create_dir(&mirror).unwrap();
        let hash = Sha256::digest(b"the photo");
        copy_checked(&source, &mirror, "lucas/2026/a.heic", &hash).unwrap();
        assert_eq!(
            std::fs::read(mirror.join("lucas/2026/a.heic")).unwrap(),
            b"the photo"
        );
        let wrong = Sha256::digest(b"other");
        assert!(copy_checked(&source, &mirror, "lucas/2026/b.heic", &wrong).is_err());
        assert!(!mirror.join("lucas/2026/b.heic").exists());
        assert!(copy_checked(&source, &mirror, "../escape.heic", &hash).is_err());
        assert!(same_disk(&mirror, dir.path()));
        assert!(!reachable(&mirror));
        prepare(&mirror, &dir.path().join("library")).unwrap();
        assert!(reachable(&mirror));
    }
}
