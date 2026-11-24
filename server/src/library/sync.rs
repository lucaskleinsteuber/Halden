//! Keeping devices up to date. Every change to an asset gives it the next number (`seq`) from
//! one server-wide counter. A device remembers the highest number it has seen and asks for
//! everything above it: one range scan over the `(user_id, seq)` index, however big the library
//! is. An asset changed ten times appears once, in its latest state. Deleted assets stay as
//! tombstones (`deletedAt` set, no files) for a while, so every device learns about the deletion.

use serde::Serialize;

use crate::{
    db::Db,
    library::assets::{self, Asset, AssetRow, asset_columns},
};

pub const DEFAULT_PAGE: u32 = 1000;
pub const MAX_PAGE: u32 = 5000;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncPage {
    pub assets: Vec<Asset>,
    /// Ask with `since` = this next time.
    pub next_since: i64,
    /// More changes are waiting; ask again right away.
    pub has_more: bool,
    /// The device is too far behind (its tombstones are gone): forget everything and sync
    /// from `since=0`.
    pub reset_required: bool,
}

/// The highest number below which tombstones may have been removed.
pub async fn floor(db: &Db) -> Result<i64, sqlx::Error> {
    let (floor,): (i64,) = sqlx::query_as("SELECT value FROM counters WHERE name = 'sync_floor'")
        .fetch_one(db.read())
        .await?;
    Ok(floor)
}

/// Changes of one account after `since`, oldest first.
pub async fn changes(
    db: &Db,
    user_id: &str,
    since: i64,
    limit: u32,
) -> Result<SyncPage, sqlx::Error> {
    if since > 0 && since < floor(db).await? {
        return Ok(SyncPage {
            assets: Vec::new(),
            next_since: 0,
            has_more: true,
            reset_required: true,
        });
    }
    let limit = limit.clamp(1, MAX_PAGE);
    // Both queries read the same snapshot, so files and assets always match.
    let mut tx = db.read().begin().await?;
    let mut rows = sqlx::query_as::<_, AssetRow>(concat!(
        "SELECT ",
        asset_columns!(),
        " FROM assets a WHERE a.user_id = ? AND a.seq > ? ORDER BY a.seq LIMIT ?"
    ))
    .bind(user_id)
    .bind(since)
    .bind(i64::from(limit) + 1)
    .fetch_all(&mut *tx)
    .await?;
    let has_more = rows.len() > limit as usize;
    rows.truncate(limit as usize);
    let assets = assets::with_files(&mut *tx, rows).await?;
    tx.commit().await?;
    let next_since = assets.last().map_or(since, |asset| asset.seq);
    Ok(SyncPage {
        assets,
        next_since,
        has_more,
        reset_required: false,
    })
}

/// Removes tombstones older than `days` and raises the floor below which devices must start
/// over. Returns how many went.
pub async fn purge_tombstones(db: &Db, days: u32, now: i64) -> Result<u64, sqlx::Error> {
    let cutoff = now - i64::from(days.max(1)) * 24 * 60 * 60 * 1000;
    let mut tx = db.begin().await?;
    let (highest,): (Option<i64>,) = sqlx::query_as(
        "SELECT max(seq) FROM assets WHERE deleted_at IS NOT NULL AND deleted_at < ?",
    )
    .bind(cutoff)
    .fetch_one(&mut *tx)
    .await?;
    let Some(highest) = highest else {
        return Ok(0);
    };
    let removed = sqlx::query("DELETE FROM assets WHERE deleted_at IS NOT NULL AND deleted_at < ?")
        .bind(cutoff)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    // `seq` numbers are only ever handed out upwards, so a device that saw `highest` (or
    // anything after it) has seen every removed tombstone; one that is further behind may
    // have missed one and must start over.
    sqlx::query("UPDATE counters SET value = max(value, ?) WHERE name = 'sync_floor'")
        .bind(highest)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(removed)
}
