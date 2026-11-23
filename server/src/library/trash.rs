//! The trash. Deleting in the app moves a photo to the trash; it can be restored from there on
//! every device. After `[library] trash_days` (default 30), or when someone empties the trash,
//! it is deleted for good: its files are removed and only a tombstone stays, so every device
//! learns about the deletion. Every step can be repeated safely, so a deletion that a phone made
//! offline can simply be sent again later.

use std::path::Path;

use crate::{
    db::{Db, now_ms},
    library::{assets, derived, paths},
};

/// Moves the account's assets to the trash. Returns how many moved (already trashed ones count
/// as done, not as moved).
pub async fn trash(db: &Db, user_id: &str, ids: &[String]) -> Result<u64, sqlx::Error> {
    let mut tx = db.begin().await?;
    let mut moved = 0;
    let now = now_ms();
    for id in ids {
        let changed = sqlx::query(
            "UPDATE assets SET trashed_at = ? \
             WHERE id = ? AND user_id = ? AND trashed_at IS NULL AND deleted_at IS NULL",
        )
        .bind(now)
        .bind(id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if changed > 0 {
            assets::touch(&mut tx, id).await?;
            moved += 1;
        }
    }
    tx.commit().await?;
    Ok(moved)
}

/// Takes assets out of the trash.
pub async fn restore(db: &Db, user_id: &str, ids: &[String]) -> Result<u64, sqlx::Error> {
    let mut tx = db.begin().await?;
    let mut restored = 0;
    for id in ids {
        let changed = sqlx::query(
            "UPDATE assets SET trashed_at = NULL \
             WHERE id = ? AND user_id = ? AND trashed_at IS NOT NULL AND deleted_at IS NULL",
        )
        .bind(id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
        if changed > 0 {
            assets::touch(&mut tx, id).await?;
            restored += 1;
        }
    }
    tx.commit().await?;
    Ok(restored)
}

/// Deletes assets for good, but only ones in the trash: nothing goes from the library straight
/// to nowhere.
pub async fn delete(
    db: &Db,
    roots: Roots<'_>,
    user_id: &str,
    ids: &[String],
) -> Result<u64, sqlx::Error> {
    let ids_json = serde_json::to_string(ids).unwrap_or_else(|_| "[]".into());
    let trashed: Vec<(String,)> = sqlx::query_as(
        "SELECT id FROM assets WHERE user_id = ? AND trashed_at IS NOT NULL \
           AND deleted_at IS NULL AND id IN (SELECT value FROM json_each(?))",
    )
    .bind(user_id)
    .bind(ids_json)
    .fetch_all(db.read())
    .await?;
    let ids: Vec<String> = trashed.into_iter().map(|(id,)| id).collect();
    purge(db, roots, &ids).await
}

/// Where an asset's files can be: the library, the derived folder, the mirror.
#[derive(Clone, Copy)]
pub struct Roots<'a> {
    pub library: &'a Path,
    pub derived: &'a Path,
    pub mirror: Option<&'a Path>,
}

/// Deletes everything that has been in the trash longer than `days`.
pub async fn purge_expired(
    db: &Db,
    roots: Roots<'_>,
    days: u32,
    now: i64,
) -> Result<u64, sqlx::Error> {
    let cutoff = now - i64::from(days.max(1)) * 24 * 60 * 60 * 1000;
    let expired: Vec<(String,)> = sqlx::query_as(
        "SELECT id FROM assets WHERE trashed_at IS NOT NULL AND trashed_at < ? \
           AND deleted_at IS NULL",
    )
    .bind(cutoff)
    .fetch_all(db.read())
    .await?;
    let ids: Vec<String> = expired.into_iter().map(|(id,)| id).collect();
    purge(db, roots, &ids).await
}

/// Turns assets into tombstones and removes their files. The database goes first: if the server
/// stops halfway, some files are left over, but no record ever points at a missing file.
async fn purge(db: &Db, roots: Roots<'_>, ids: &[String]) -> Result<u64, sqlx::Error> {
    let mut purged = 0;
    for id in ids {
        let mut tx = db.begin().await?;
        let files: Vec<(String, String)> =
            sqlx::query_as("SELECT storage, path FROM asset_files WHERE asset_id = ?")
                .bind(id)
                .fetch_all(&mut *tx)
                .await?;
        sqlx::query("DELETE FROM asset_files WHERE asset_id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM asset_edits WHERE asset_id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM jobs WHERE asset_id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        // A tombstone keeps only what devices need to forget the photo, not where or when it was.
        sqlx::query(
            "UPDATE assets SET deleted_at = ?, exif_json = NULL, client_json = NULL, \
                 title = NULL, description = NULL, latitude = NULL, longitude = NULL, \
                 altitude = NULL, location_accuracy_m = NULL, heading = NULL, \
                 edit_latitude = NULL, edit_longitude = NULL, edit_altitude = NULL, \
                 camera_make = NULL, camera_model = NULL, lens = NULL \
             WHERE id = ?",
        )
        .bind(now_ms())
        .bind(id)
        .execute(&mut *tx)
        .await?;
        assets::touch(&mut tx, id).await?;
        tx.commit().await?;
        purged += 1;

        for (storage, path) in files {
            if storage == "library" {
                if let Some(full) = paths::resolve(roots.library, &path) {
                    let _ = tokio::fs::remove_file(full).await;
                }
            } else if let Err(error) = derived::remove_if_unused(db, roots.derived, &path).await {
                tracing::warn!(%error, "could not remove a thumbnail of a deleted photo");
            }
        }
        crate::backup::mirror::forget(db, roots.mirror, id).await?;
    }
    Ok(purged)
}
