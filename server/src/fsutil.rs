//! Small file system helpers that never leave half-written files behind.

use std::{
    fs::{self, DirBuilder, File, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::Path,
};

use anyhow::{Context, Result};

/// Writes `contents` to `path` so that readers see either the old file or the complete new one,
/// never a mix: the data goes to a temporary file in the same folder, is flushed to disk, and
/// then renamed over the target. The folder is flushed too, so the rename survives a power cut.
pub fn write_atomic(path: &Path, contents: &[u8], mode: u32) -> Result<()> {
    write_atomic_owned(path, contents, mode, None)
}

/// Replaces an existing file atomically like [`write_atomic`], keeping its permissions and,
/// where allowed, its owner and group (a config file written by root stays readable by the
/// server's group, and one written by the server stays in that group).
pub fn replace_file(path: &Path, contents: &[u8]) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let old = fs::metadata(path).with_context(|| format!("could not read {}", path.display()))?;
    write_atomic_owned(
        path,
        contents,
        old.mode() & 0o7777,
        Some((old.uid(), old.gid())),
    )
}

fn write_atomic_owned(
    path: &Path,
    contents: &[u8],
    mode: u32,
    owner: Option<(u32, u32)>,
) -> Result<()> {
    let dir = path
        .parent()
        .with_context(|| format!("{} has no parent folder", path.display()))?;
    let name = path
        .file_name()
        .with_context(|| format!("{} has no file name", path.display()))?
        .to_string_lossy();
    let tmp = dir.join(format!(".{name}.tmp-{}", std::process::id()));
    let _ = fs::remove_file(&tmp);

    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&tmp)
            .with_context(|| format!("could not create {}", tmp.display()))?;
        file.write_all(contents)?;
        file.sync_all()?;
        // The mode given to open() is reduced by the umask; set it exactly.
        fs::set_permissions(&tmp, fs::Permissions::from_mode(mode))?;
        if let Some((uid, gid)) = owner {
            // Only root may give a file away; anyone may keep their own user and a group
            // they belong to. What isn't allowed is left as it is.
            if std::os::unix::fs::chown(&tmp, Some(uid), Some(gid)).is_err() {
                let _ = std::os::unix::fs::chown(&tmp, None, Some(gid));
            }
        }
        fs::rename(&tmp, path)
            .with_context(|| format!("could not move the new file to {}", path.display()))?;
        sync_dir(dir)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// Creates `path` and sets its permissions to exactly `mode`. Missing parent folders are made
/// with the usual 0755, never with `mode`: a parent only root may enter (like `/srv/halden` made
/// 0750 by root) would lock the server's own user out of everything below it.
pub fn create_dir(path: &Path, mode: u32) -> Result<()> {
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
        && !parent.exists()
    {
        DirBuilder::new()
            .recursive(true)
            .mode(0o755)
            .create(parent)
            .with_context(|| format!("could not create the folder {}", parent.display()))?;
    }
    DirBuilder::new()
        .recursive(true)
        .mode(mode)
        .create(path)
        .with_context(|| format!("could not create the folder {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .with_context(|| format!("could not set permissions on {}", path.display()))
}

/// Holds `halden.lock` in the data folder while a server runs, so two servers (or a restore and a
/// server) never work on the same database. The lock goes away with the process, even after
/// `kill -9`.
pub struct DataLock(#[allow(dead_code)] File);

pub fn lock_data_dir(data_dir: &Path) -> Result<DataLock> {
    let path = data_dir.join("halden.lock");
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(&path)
        .with_context(|| format!("could not open {}", path.display()))?;
    match file.try_lock() {
        Ok(()) => Ok(DataLock(file)),
        Err(std::fs::TryLockError::WouldBlock) => anyhow::bail!(
            "a Halden server is running on {} (stop it first: sudo systemctl stop halden)",
            data_dir.display()
        ),
        Err(std::fs::TryLockError::Error(error)) => {
            Err(error).with_context(|| format!("could not lock {}", path.display()))
        }
    }
}

/// Like [`lock_data_dir`], but waits up to `wait` for the lock: for a server that starts again
/// in the same process, while the one before is still letting go.
pub async fn lock_data_dir_waiting(data_dir: &Path, wait: std::time::Duration) -> Result<DataLock> {
    let deadline = std::time::Instant::now() + wait;
    loop {
        match lock_data_dir(data_dir) {
            Ok(lock) => return Ok(lock),
            Err(_) if std::time::Instant::now() < deadline => {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
            Err(error) => return Err(error),
        }
    }
}

/// Flushes a folder's entries (new, renamed or removed files) to disk.
pub fn sync_dir(dir: &Path) -> Result<()> {
    File::open(dir)
        .and_then(|d| d.sync_all())
        .with_context(|| format!("could not flush the folder {}", dir.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_atomic_replaces_and_sets_mode() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file.txt");
        write_atomic(&path, b"first", 0o600).unwrap();
        write_atomic(&path, b"second", 0o640).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "second");
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o640);
        // No temporary files are left behind.
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    /// Found by the system test: `/srv/halden` made 0750 by root locked the server out of its
    /// library below it.
    #[test]
    fn missing_parents_stay_open_to_enter() {
        let dir = tempfile::tempdir().unwrap();
        let library = dir.path().join("srv/halden/library");
        create_dir(&library, 0o750).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir.path().join("srv")), 0o755);
        assert_eq!(mode(&dir.path().join("srv/halden")), 0o755);
        assert_eq!(mode(&library), 0o750);
    }
}
