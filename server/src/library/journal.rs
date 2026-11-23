//! Keeps file moves and removals in step with the database across crashes (see
//! `migrations/0007_file_journal.sql`).

use std::path::Path;

use sqlx::SqliteConnection;

use super::{derived, paths};
use crate::db::{Db, now_ms};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Storage {
    Library,
    Derived,
    Mirror,
}

impl Storage {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Library => "library",
            Self::Derived => "derived",
            Self::Mirror => "mirror",
        }
    }

    pub fn parse(text: &str) -> Self {
        match text {
            "derived" => Self::Derived,
            "mirror" => Self::Mirror,
            _ => Self::Library,
        }
    }
}

/// Notes, and commits, that a file is about to be moved to `path` in the library. Returns the
/// entry to pass to [`placed`] in the transaction that records the file.
pub async fn will_place(db: &Db, path: &str, upload_id: Option<&str>) -> Result<i64, sqlx::Error> {
    let (id,): (i64,) = sqlx::query_as(
        "INSERT INTO file_journal (action, storage, path, upload_id, created_at) \
         VALUES ('place', 'library', ?, ?, ?) RETURNING id",
    )
    .bind(path)
    .bind(upload_id)
    .bind(now_ms())
    .fetch_one(db.write())
    .await?;
    Ok(id)
}

/// In the transaction that records the placed file.
pub async fn placed(tx: &mut SqliteConnection, entry: i64) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM file_journal WHERE id = ?")
        .bind(entry)
        .execute(&mut *tx)
        .await?;
    Ok(())
}

/// The move didn't happen after all (it failed, or was undone).
pub async fn forget(db: &Db, entry: i64) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM file_journal WHERE id = ?")
        .bind(entry)
        .execute(db.write())
        .await?;
    Ok(())
}

/// In the transaction that deletes a file's record: the file is to go once it is committed.
pub async fn will_remove(
    tx: &mut SqliteConnection,
    storage: Storage,
    path: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO file_journal (action, storage, path, created_at) VALUES ('remove', ?, ?, ?)",
    )
    .bind(storage.as_str())
    .bind(path)
    .bind(now_ms())
    .execute(&mut *tx)
    .await?;
    Ok(())
}

/// Where the files are.
#[derive(Debug, Clone, Copy)]
pub struct Roots<'a> {
    pub library: &'a Path,
    pub derived: &'a Path,
    pub mirror: Option<&'a Path>,
}

/// Removes the files whose records are gone, as noted by [`will_remove`]. Run right after the
/// deleting transaction, and again at every start. A mirror copy waits until the mirror disk is
/// there.
pub async fn remove_pending(db: &Db, roots: Roots<'_>) -> Result<u64, sqlx::Error> {
    let pending: Vec<(i64, String, String)> = sqlx::query_as(
        "SELECT id, storage, path FROM file_journal WHERE action = 'remove' ORDER BY id",
    )
    .fetch_all(db.read())
    .await?;
    let mut removed = 0;
    for (id, storage, path) in pending {
        let done = match Storage::parse(&storage) {
            Storage::Library => {
                // Unless a newer record took over the name in the meantime.
                let live: Option<(i64,)> = sqlx::query_as(
                    "SELECT 1 FROM asset_files WHERE storage = 'library' AND path = ?",
                )
                .bind(&path)
                .fetch_optional(db.read())
                .await?;
                if live.is_none()
                    && let Some(full) = paths::resolve(roots.library, &path)
                {
                    remove(&full).await;
                }
                true
            }
            Storage::Derived => {
                if let Err(error) = derived::remove_if_unused(db, roots.derived, &path).await {
                    tracing::warn!(%error, "could not remove a thumbnail");
                }
                true
            }
            Storage::Mirror => match roots.mirror {
                Some(root) if crate::backup::mirror::reachable(root) => {
                    let live: Option<(i64,)> =
                        sqlx::query_as("SELECT 1 FROM mirror_files WHERE path = ?")
                            .bind(&path)
                            .fetch_optional(db.read())
                            .await?;
                    if live.is_none()
                        && let Some(full) = paths::resolve(root, &path)
                    {
                        remove(&full).await;
                    }
                    true
                }
                // The mirror disk is away (or no longer the mirror): try again later, unless
                // there is no mirror any more at all.
                Some(_) => false,
                None => true,
            },
        };
        if done {
            sqlx::query("DELETE FROM file_journal WHERE id = ?")
                .bind(id)
                .execute(db.write())
                .await?;
            removed += 1;
        }
    }
    Ok(removed)
}

async fn remove(full: &Path) {
    match tokio::fs::remove_file(full).await {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => tracing::warn!(%error, "could not remove a deleted photo's file"),
    }
}

/// What [`recover`] put right.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Recovered {
    /// Uploads moved back to their partial file, to be finished.
    pub uploads_returned: u64,
    /// Files moved into the library but never recorded, removed.
    pub unrecorded_removed: u64,
    /// Files of deleted records, removed.
    pub removed: u64,
}

/// At start: finishes what a crash interrupted. `incoming` holds the uploads' partial files.
pub async fn recover(db: &Db, roots: Roots<'_>, incoming: &Path) -> Result<Recovered, sqlx::Error> {
    let mut recovered = Recovered::default();
    let placements: Vec<(i64, String, Option<String>)> = sqlx::query_as(
        "SELECT id, path, upload_id FROM file_journal WHERE action = 'place' ORDER BY id",
    )
    .fetch_all(db.read())
    .await?;
    for (id, path, upload_id) in placements {
        let recorded: Option<(i64,)> =
            sqlx::query_as("SELECT 1 FROM asset_files WHERE storage = 'library' AND path = ?")
                .bind(&path)
                .fetch_optional(db.read())
                .await?;
        if recorded.is_none()
            && let Some(full) = paths::resolve(roots.library, &path)
            && full.is_file()
        {
            let receiving = match &upload_id {
                Some(upload) => {
                    sqlx::query_as::<_, (String,)>("SELECT state FROM uploads WHERE id = ?")
                        .bind(upload)
                        .fetch_optional(db.read())
                        .await?
                        .is_some_and(|(state,)| state == "receiving")
                }
                None => false,
            };
            let part = upload_id
                .as_ref()
                .map(|upload| incoming.join(format!("{upload}.part")));
            match part {
                Some(part) if receiving && !part.exists() => {
                    if std::fs::rename(&full, &part).is_ok() {
                        let _ = crate::fsutil::sync_dir(incoming);
                        recovered.uploads_returned += 1;
                    }
                }
                _ => {
                    remove(&full).await;
                    recovered.unrecorded_removed += 1;
                }
            }
        }
        forget(db, id).await?;
    }
    recovered.removed = remove_pending(db, roots).await?;
    Ok(recovered)
}
