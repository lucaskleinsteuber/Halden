//! Albums: an account's own collections of photos. An album only points at photos; a photo can
//! be in many. Photos in the trash stay in their albums (devices don't show them) and are back
//! when restored; deleted for good, they leave every album. Every change gives the album the next
//! number from the counter assets use, so devices get albums with the same sync.

use std::collections::HashMap;

use serde::Serialize;
use sqlx::{Executor, Sqlite, SqliteConnection};

use crate::{
    db::{Db, now_ms},
    library::assets,
};

/// Longest album name, in characters.
pub const MAX_NAME: usize = 200;

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Album {
    pub id: String,
    pub name: String,
    pub cover_asset_id: Option<String>,
    pub sort_order: i64,
    /// The photos in it, the most recently added first. Empty for a deleted album.
    pub asset_ids: Vec<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub seq: i64,
    pub deleted_at: Option<i64>,
}

#[derive(sqlx::FromRow)]
pub(crate) struct AlbumRow {
    id: String,
    name: String,
    cover_asset_id: Option<String>,
    sort_order: i64,
    created_at: i64,
    updated_at: i64,
    pub seq: i64,
    deleted_at: Option<i64>,
}

macro_rules! album_columns {
    () => {
        "id, name, cover_asset_id, sort_order, created_at, updated_at, seq, deleted_at"
    };
}

/// What to change. A missing field stays as it is.
#[derive(Debug, Default)]
pub struct AlbumChange {
    pub name: Option<String>,
    /// `Some(None)`: the newest photo again.
    pub cover_asset_id: Option<Option<String>>,
    pub sort_order: Option<i64>,
}

/// A name as it is kept: trimmed, not empty, not too long.
pub fn clean_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("An album needs a name.".into());
    }
    if name.chars().count() > MAX_NAME {
        return Err(format!(
            "Album names may have at most {MAX_NAME} characters."
        ));
    }
    Ok(name.to_string())
}

pub(crate) async fn with_assets<'e, E>(
    db: E,
    rows: Vec<AlbumRow>,
) -> Result<Vec<Album>, sqlx::Error>
where
    E: Executor<'e, Database = Sqlite>,
{
    let live: Vec<&str> = rows
        .iter()
        .filter(|row| row.deleted_at.is_none())
        .map(|row| row.id.as_str())
        .collect();
    let mut members: HashMap<String, Vec<String>> = HashMap::new();
    if !live.is_empty() {
        let ids = serde_json::to_string(&live).unwrap_or_else(|_| "[]".into());
        let found = sqlx::query_as::<_, (String, String)>(
            "SELECT album_id, asset_id FROM album_assets \
             WHERE album_id IN (SELECT value FROM json_each(?)) ORDER BY added_at DESC, asset_id",
        )
        .bind(ids)
        .fetch_all(db)
        .await?;
        for (album, asset) in found {
            members.entry(album).or_default().push(asset);
        }
    }
    Ok(rows
        .into_iter()
        .map(|row| Album {
            asset_ids: members.remove(&row.id).unwrap_or_default(),
            id: row.id,
            name: row.name,
            cover_asset_id: row.cover_asset_id,
            sort_order: row.sort_order,
            created_at: row.created_at,
            updated_at: row.updated_at,
            seq: row.seq,
            deleted_at: row.deleted_at,
        })
        .collect())
}

/// The account's albums (not the deleted ones), in their order.
pub async fn list(db: &Db, user_id: &str) -> Result<Vec<Album>, sqlx::Error> {
    let mut tx = db.read().begin().await?;
    let rows = sqlx::query_as::<_, AlbumRow>(concat!(
        "SELECT ",
        album_columns!(),
        " FROM albums WHERE user_id = ? AND deleted_at IS NULL \
         ORDER BY sort_order, name COLLATE NOCASE, id"
    ))
    .bind(user_id)
    .fetch_all(&mut *tx)
    .await?;
    let albums = with_assets(&mut *tx, rows).await?;
    tx.commit().await?;
    Ok(albums)
}

/// One album of the account (also a deleted one, so a repeated delete can answer).
pub async fn get(db: &Db, user_id: &str, id: &str) -> Result<Option<Album>, sqlx::Error> {
    let mut tx = db.read().begin().await?;
    let row = album_row(&mut tx, user_id, id).await?;
    let album = match row {
        Some(row) => with_assets(&mut *tx, vec![row]).await?.pop(),
        None => None,
    };
    tx.commit().await?;
    Ok(album)
}

async fn album_row(
    tx: &mut SqliteConnection,
    user_id: &str,
    id: &str,
) -> Result<Option<AlbumRow>, sqlx::Error> {
    sqlx::query_as::<_, AlbumRow>(concat!(
        "SELECT ",
        album_columns!(),
        " FROM albums WHERE id = ? AND user_id = ?"
    ))
    .bind(id)
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await
}

/// A new album, with photos in it from the start. Creating it again with the same id (a device
/// that didn't hear the answer) gives the one already there. `Err` when the id belongs to another
/// account.
pub async fn create(
    db: &Db,
    user_id: &str,
    id: &str,
    name: &str,
    asset_ids: &[String],
) -> Result<Result<(Album, bool), ()>, sqlx::Error> {
    let mut tx = db.begin().await?;
    let existing: Option<(String,)> = sqlx::query_as("SELECT user_id FROM albums WHERE id = ?")
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
    if let Some((owner,)) = existing {
        tx.rollback().await?;
        if owner != user_id {
            return Ok(Err(()));
        }
        let album = get(db, user_id, id).await?.expect("it is there");
        return Ok(Ok((album, false)));
    }
    let now = now_ms();
    let seq = assets::next_seq(&mut tx).await?;
    sqlx::query(
        "INSERT INTO albums (id, user_id, name, sort_order, created_at, updated_at, seq) \
         VALUES (?, ?, ?, 0, ?, ?, ?)",
    )
    .bind(id)
    .bind(user_id)
    .bind(name)
    .bind(now)
    .bind(now)
    .bind(seq)
    .execute(&mut *tx)
    .await?;
    add_in(&mut tx, user_id, id, asset_ids, now).await?;
    tx.commit().await?;
    let album = get(db, user_id, id).await?.expect("just made");
    Ok(Ok((album, true)))
}

/// Renames, chooses the cover or moves the album in the list. `None` if there is no such album.
pub async fn change(
    db: &Db,
    user_id: &str,
    id: &str,
    change: &AlbumChange,
) -> Result<Option<Album>, sqlx::Error> {
    let mut tx = db.begin().await?;
    let Some(row) = album_row(&mut tx, user_id, id).await? else {
        return Ok(None);
    };
    if row.deleted_at.is_some() {
        return Ok(None);
    }
    if let Some(name) = &change.name {
        sqlx::query("UPDATE albums SET name = ? WHERE id = ?")
            .bind(name)
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }
    if let Some(cover) = &change.cover_asset_id {
        sqlx::query("UPDATE albums SET cover_asset_id = ? WHERE id = ?")
            .bind(cover)
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }
    if let Some(order) = change.sort_order {
        sqlx::query("UPDATE albums SET sort_order = ? WHERE id = ?")
            .bind(order)
            .bind(id)
            .execute(&mut *tx)
            .await?;
    }
    touch(&mut tx, id).await?;
    tx.commit().await?;
    get(db, user_id, id).await
}

/// Puts photos of the account into the album (others' and deleted ones are skipped; one already
/// in it stays where it was). `None` if there is no such album.
pub async fn add(
    db: &Db,
    user_id: &str,
    id: &str,
    asset_ids: &[String],
) -> Result<Option<Album>, sqlx::Error> {
    let mut tx = db.begin().await?;
    match album_row(&mut tx, user_id, id).await? {
        Some(row) if row.deleted_at.is_none() => {}
        _ => return Ok(None),
    }
    if add_in(&mut tx, user_id, id, asset_ids, now_ms()).await? > 0 {
        touch(&mut tx, id).await?;
    }
    tx.commit().await?;
    get(db, user_id, id).await
}

async fn add_in(
    tx: &mut SqliteConnection,
    user_id: &str,
    album_id: &str,
    asset_ids: &[String],
    now: i64,
) -> Result<u64, sqlx::Error> {
    let mut added = 0;
    for asset_id in asset_ids {
        added += sqlx::query(
            "INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at) \
             SELECT ?, id, ? FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
        )
        .bind(album_id)
        .bind(now)
        .bind(asset_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    }
    Ok(added)
}

/// Takes photos out of the album; they stay in the library. `None` if there is no such album.
pub async fn remove(
    db: &Db,
    user_id: &str,
    id: &str,
    asset_ids: &[String],
) -> Result<Option<Album>, sqlx::Error> {
    let mut tx = db.begin().await?;
    match album_row(&mut tx, user_id, id).await? {
        Some(row) if row.deleted_at.is_none() => {}
        _ => return Ok(None),
    }
    let mut removed = 0;
    for asset_id in asset_ids {
        removed += sqlx::query("DELETE FROM album_assets WHERE album_id = ? AND asset_id = ?")
            .bind(id)
            .bind(asset_id)
            .execute(&mut *tx)
            .await?
            .rows_affected();
    }
    if removed > 0 {
        touch(&mut tx, id).await?;
    }
    tx.commit().await?;
    get(db, user_id, id).await
}

/// Deletes the album; its photos stay. Deleting it again changes nothing. `false` if there is
/// no such album.
pub async fn delete(db: &Db, user_id: &str, id: &str) -> Result<bool, sqlx::Error> {
    let mut tx = db.begin().await?;
    let Some(row) = album_row(&mut tx, user_id, id).await? else {
        return Ok(false);
    };
    if row.deleted_at.is_none() {
        sqlx::query("DELETE FROM album_assets WHERE album_id = ?")
            .bind(id)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE albums SET deleted_at = ?, cover_asset_id = NULL WHERE id = ?")
            .bind(now_ms())
            .bind(id)
            .execute(&mut *tx)
            .await?;
        touch(&mut tx, id).await?;
    }
    tx.commit().await?;
    Ok(true)
}

/// A photo deleted for good leaves every album; those albums change.
pub(crate) async fn forget_asset(
    tx: &mut SqliteConnection,
    asset_id: &str,
) -> Result<(), sqlx::Error> {
    let albums: Vec<(String,)> =
        sqlx::query_as("SELECT album_id FROM album_assets WHERE asset_id = ?")
            .bind(asset_id)
            .fetch_all(&mut *tx)
            .await?;
    sqlx::query("DELETE FROM album_assets WHERE asset_id = ?")
        .bind(asset_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE albums SET cover_asset_id = NULL WHERE cover_asset_id = ?")
        .bind(asset_id)
        .execute(&mut *tx)
        .await?;
    for (album,) in albums {
        touch(tx, &album).await?;
    }
    Ok(())
}

async fn touch(tx: &mut SqliteConnection, album_id: &str) -> Result<(), sqlx::Error> {
    let seq = assets::next_seq(tx).await?;
    sqlx::query("UPDATE albums SET seq = ?, updated_at = ? WHERE id = ?")
        .bind(seq)
        .bind(now_ms())
        .bind(album_id)
        .execute(&mut *tx)
        .await?;
    Ok(())
}

/// Albums of the account changed after `since`, oldest change first (also deleted ones, so
/// devices forget them).
pub(crate) async fn changed_since(
    tx: &mut SqliteConnection,
    user_id: &str,
    since: i64,
    limit: i64,
) -> Result<Vec<AlbumRow>, sqlx::Error> {
    sqlx::query_as::<_, AlbumRow>(concat!(
        "SELECT ",
        album_columns!(),
        " FROM albums WHERE user_id = ? AND seq > ? ORDER BY seq LIMIT ?"
    ))
    .bind(user_id)
    .bind(since)
    .bind(limit)
    .fetch_all(&mut *tx)
    .await
}
