//! The trash. Deleting in the app moves a photo to the trash; it can be restored from there on
//! every device. After `[library] trash_days` (default 30), or when someone empties the trash,
//! it is deleted for good: its files are removed and only a tombstone stays, so every device
//! learns about the deletion. Every step can be repeated safely, so a deletion that a phone made
//! offline can simply be sent again later.

use crate::{
    db::{Db, now_ms},
    library::{assets, journal},
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
    purge(db, roots, &ids, i64::MAX).await
}

/// Where an asset's files can be: the library, the derived folder, the mirror.
pub type Roots<'a> = super::journal::Roots<'a>;

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
    purge(db, roots, &ids, cutoff).await
}

/// Turns assets into tombstones and removes their files. The database goes first, and notes in
/// the same transaction which files are to go (the file journal): if the server stops halfway,
/// the next start removes what is left, so a deleted photo never stays on any disk, and no
/// record ever points at a missing file.
///
/// Only assets that are still in the trash (since before `trashed_before`) when their
/// transaction runs: a photo restored by another device a moment ago stays.
pub async fn purge(
    db: &Db,
    roots: Roots<'_>,
    ids: &[String],
    trashed_before: i64,
) -> Result<u64, sqlx::Error> {
    let mut purged = 0;
    for id in ids {
        let mut tx = db.begin().await?;
        // Checked again here, inside the transaction: what was in the trash when the request
        // came may have been restored since. A tombstone keeps only what devices need to forget
        // the photo, not where or when it was.
        let claimed = sqlx::query(
            "UPDATE assets SET deleted_at = ?, exif_json = NULL, client_json = NULL, \
                 title = NULL, description = NULL, latitude = NULL, longitude = NULL, \
                 altitude = NULL, location_accuracy_m = NULL, heading = NULL, \
                 edit_latitude = NULL, edit_longitude = NULL, edit_altitude = NULL, \
                 camera_make = NULL, camera_model = NULL, lens = NULL \
             WHERE id = ? AND deleted_at IS NULL AND trashed_at IS NOT NULL AND trashed_at < ?",
        )
        .bind(now_ms())
        .bind(id)
        .bind(trashed_before)
        .execute(&mut *tx)
        .await?;
        if claimed.rows_affected() == 0 {
            continue;
        }
        let files: Vec<(String, String)> =
            sqlx::query_as("SELECT storage, path FROM asset_files WHERE asset_id = ?")
                .bind(id)
                .fetch_all(&mut *tx)
                .await?;
        for (storage, path) in &files {
            journal::will_remove(&mut tx, journal::Storage::parse(storage), path).await?;
        }
        let copies: Vec<(String,)> =
            sqlx::query_as("SELECT path FROM mirror_files WHERE asset_id = ?")
                .bind(id)
                .fetch_all(&mut *tx)
                .await?;
        for (path,) in &copies {
            journal::will_remove(&mut tx, journal::Storage::Mirror, path).await?;
        }
        sqlx::query("DELETE FROM mirror_files WHERE asset_id = ?")
            .bind(id)
            .execute(&mut *tx)
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
        crate::library::albums::forget_asset(&mut tx, id).await?;
        assets::touch(&mut tx, id).await?;
        tx.commit().await?;
        purged += 1;

        crate::failpoint::hit("purge-recorded");
    }
    if !ids.is_empty() {
        journal::remove_pending(db, roots).await?;
    }
    Ok(purged)
}
