//! Keeping devices up to date. Every change to an asset gives it the next number (`seq`) from
//! one server-wide counter. A device remembers the highest number it has seen and asks for
//! everything above it: one range scan over the `(user_id, seq)` index, however big the library
//! is. An asset changed ten times appears once, in its latest state. Deleted assets stay as
//! tombstones (`deletedAt` set, no files) for a while, so every device learns about the deletion.

use serde::Serialize;

use crate::{
    db::Db,
    library::{
        albums::{self, Album},
        assets::{self, Asset, AssetRow, asset_columns},
    },
};

pub const DEFAULT_PAGE: u32 = 1000;
pub const MAX_PAGE: u32 = 5000;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncPage {
    pub assets: Vec<Asset>,
    /// Albums changed in the same range (deleted ones with `deletedAt`).
    pub albums: Vec<Album>,
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
            albums: Vec::new(),
            next_since: 0,
            has_more: true,
            reset_required: true,
        });
    }
    let limit = limit.clamp(1, MAX_PAGE);
    // All queries read the same snapshot, so files, assets and albums always match.
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
    let mut album_rows =
        albums::changed_since(&mut tx, user_id, since, i64::from(limit) + 1).await?;
    // Assets and albums share one counter: the page is the `limit` lowest numbers of both.
    let mut seqs: Vec<i64> = rows
        .iter()
        .map(|row| row.seq)
        .chain(album_rows.iter().map(|row| row.seq))
        .collect();
    seqs.sort_unstable();
    let has_more = seqs.len() > limit as usize;
    let last = if has_more {
        seqs[limit as usize - 1]
    } else {
        seqs.last().copied().unwrap_or(since)
    };
    rows.retain(|row| row.seq <= last);
    album_rows.retain(|row| row.seq <= last);
    let assets = assets::with_files(&mut *tx, rows).await?;
    let albums = albums::with_assets(&mut *tx, album_rows).await?;
    tx.commit().await?;
    Ok(SyncPage {
        assets,
        albums,
        next_since: last,
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
        "SELECT max(seq) FROM (\
             SELECT seq FROM assets WHERE deleted_at IS NOT NULL AND deleted_at < ?1 \
             UNION ALL SELECT seq FROM albums WHERE deleted_at IS NOT NULL AND deleted_at < ?1)",
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
    sqlx::query("DELETE FROM albums WHERE deleted_at IS NOT NULL AND deleted_at < ?")
        .bind(cutoff)
        .execute(&mut *tx)
        .await?;
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
