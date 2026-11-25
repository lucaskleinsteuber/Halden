//! Shared links: photos or an album for people without Halden, as a plain web page, for as long
//! as wanted.
//!
//! The page is served on a second listener of its own (`[share] listen`, plain HTTP on this
//! computer by default), meant to be put on the internet by something that brings a real
//! certificate: Tailscale Funnel, Cloudflare Tunnel or Caddy (see `docs/SHARING.md`). That
//! listener knows nothing but `/s/<token>`: no sign-in, no API, nothing else of the server.
//!
//! A link shows previews (JPEG without the place) and videos as their small copy; originals
//! (which do contain the place) only when the link allows it. A link can have a password and an
//! end; it can be withdrawn any time.

pub mod page;

use rand::RngExt;
use serde::Serialize;
use serde_json::Value;

use crate::{
    auth::password,
    db::{Db, now_ms},
};

/// What a link shares.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Share {
    pub id: String,
    pub token: String,
    pub title: Option<String>,
    /// An album (its photos as they are when the link is opened) …
    pub album_id: Option<String>,
    /// … or these photos.
    pub asset_ids: Vec<String>,
    pub expires_at: Option<i64>,
    pub has_password: bool,
    pub allow_originals: bool,
    pub views: i64,
    pub created_at: i64,
    /// The address to send, when the server knows where it is reachable (`[share] public_url`).
    pub url: Option<String>,
}

#[derive(sqlx::FromRow)]
pub(crate) struct ShareRow {
    pub id: String,
    pub user_id: String,
    pub token: String,
    pub title: Option<String>,
    pub album_id: Option<String>,
    pub asset_ids: Option<String>,
    pub expires_at: Option<i64>,
    pub password_hash: Option<String>,
    pub allow_originals: bool,
    pub views: i64,
    pub created_at: i64,
    pub revoked_at: Option<i64>,
}

macro_rules! share_columns {
    () => {
        "id, user_id, token, title, album_id, asset_ids, expires_at, password_hash, \
         allow_originals, views, created_at, revoked_at"
    };
}

impl ShareRow {
    pub(crate) fn into_share(self, public_url: Option<&str>) -> Share {
        Share {
            url: public_url.map(|base| format!("{}/s/{}", base.trim_end_matches('/'), self.token)),
            asset_ids: self
                .asset_ids
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok())
                .unwrap_or_default(),
            id: self.id,
            token: self.token,
            title: self.title,
            album_id: self.album_id,
            expires_at: self.expires_at,
            has_password: self.password_hash.is_some(),
            allow_originals: self.allow_originals,
            views: self.views,
            created_at: self.created_at,
        }
    }

    /// Open now: not withdrawn, not over.
    pub(crate) fn open(&self, now: i64) -> bool {
        self.revoked_at.is_none() && self.expires_at.is_none_or(|end| end > now)
    }
}

/// A new link.
pub struct NewShare {
    pub title: Option<String>,
    pub album_id: Option<String>,
    pub asset_ids: Vec<String>,
    pub expires_at: Option<i64>,
    pub password: Option<String>,
    pub allow_originals: bool,
}

/// 128 bits from the system's random source, as 22 URL-safe characters.
fn new_token() -> String {
    use base64::Engine;
    let bytes: [u8; 16] = rand::rng().random();
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// Makes a link. Photos of other accounts and an album of another account are not shared
/// (`Err` with what is wrong).
pub async fn create(
    db: &Db,
    user_id: &str,
    new: NewShare,
    public_url: Option<&str>,
) -> anyhow::Result<Result<Share, String>> {
    if let Some(album) = &new.album_id {
        let found: Option<(String,)> = sqlx::query_as(
            "SELECT id FROM albums WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
        )
        .bind(album)
        .bind(user_id)
        .fetch_optional(db.read())
        .await?;
        if found.is_none() {
            return Ok(Err("There is no such album.".into()));
        }
    } else {
        if new.asset_ids.is_empty() {
            return Ok(Err("Share an album or at least one photo.".into()));
        }
        let ids = serde_json::to_string(&new.asset_ids)?;
        let (own,): (i64,) = sqlx::query_as(
            "SELECT count(*) FROM assets WHERE user_id = ? AND deleted_at IS NULL \
             AND id IN (SELECT value FROM json_each(?))",
        )
        .bind(user_id)
        .bind(&ids)
        .fetch_one(db.read())
        .await?;
        if own as usize != new.asset_ids.len() {
            return Ok(Err("Only your own photos can be shared.".into()));
        }
    }
    let password_hash = match new.password.filter(|p| !p.is_empty()) {
        Some(password) => Some(password::hash(password).await?),
        None => None,
    };
    let id = uuid::Uuid::new_v4().to_string();
    let token = new_token();
    sqlx::query(
        "INSERT INTO shares (id, user_id, token, title, album_id, asset_ids, expires_at, \
             password_hash, allow_originals, views, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)",
    )
    .bind(&id)
    .bind(user_id)
    .bind(&token)
    .bind(
        new.title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty()),
    )
    .bind(&new.album_id)
    .bind(if new.album_id.is_some() {
        None
    } else {
        Some(serde_json::to_string(&new.asset_ids)?)
    })
    .bind(new.expires_at)
    .bind(password_hash)
    .bind(new.allow_originals)
    .bind(now_ms())
    .execute(db.write())
    .await?;
    let row = by_id(db, user_id, &id).await?.expect("just made");
    Ok(Ok(row.into_share(public_url)))
}

pub(crate) async fn by_id(
    db: &Db,
    user_id: &str,
    id: &str,
) -> Result<Option<ShareRow>, sqlx::Error> {
    sqlx::query_as::<_, ShareRow>(concat!(
        "SELECT ",
        share_columns!(),
        " FROM shares WHERE id = ? AND user_id = ?"
    ))
    .bind(id)
    .bind(user_id)
    .fetch_optional(db.read())
    .await
}

pub(crate) async fn by_token(db: &Db, token: &str) -> Result<Option<ShareRow>, sqlx::Error> {
    sqlx::query_as::<_, ShareRow>(concat!(
        "SELECT ",
        share_columns!(),
        " FROM shares WHERE token = ?"
    ))
    .bind(token)
    .fetch_optional(db.read())
    .await
}

/// The account's links that are still open, newest first.
pub async fn list(
    db: &Db,
    user_id: &str,
    public_url: Option<&str>,
) -> Result<Vec<Share>, sqlx::Error> {
    let now = now_ms();
    let rows = sqlx::query_as::<_, ShareRow>(concat!(
        "SELECT ",
        share_columns!(),
        " FROM shares WHERE user_id = ? AND revoked_at IS NULL ORDER BY created_at DESC"
    ))
    .bind(user_id)
    .fetch_all(db.read())
    .await?;
    Ok(rows
        .into_iter()
        .filter(|row| row.open(now))
        .map(|row| row.into_share(public_url))
        .collect())
}

/// Withdraws a link; it answers "gone" from now on. `false` if there is no such link.
pub async fn revoke(db: &Db, user_id: &str, id: &str) -> Result<bool, sqlx::Error> {
    let changed = sqlx::query(
        "UPDATE shares SET revoked_at = coalesce(revoked_at, ?) WHERE id = ? AND user_id = ?",
    )
    .bind(now_ms())
    .bind(id)
    .bind(user_id)
    .execute(db.write())
    .await?
    .rows_affected();
    Ok(changed > 0)
}

/// The photos a link shows now, newest first: the album's or the chosen ones, without those
/// in the trash or deleted.
pub(crate) async fn shared_assets(
    db: &Db,
    share: &ShareRow,
) -> Result<Vec<(String, String, i64)>, sqlx::Error> {
    let (sql, bind): (&str, String) = match &share.album_id {
        Some(album) => (
            "SELECT a.id, a.kind, coalesce(a.edit_taken_at, a.taken_at) FROM assets a \
             JOIN album_assets m ON m.asset_id = a.id \
             WHERE m.album_id = ?1 AND a.user_id = ?2 AND a.trashed_at IS NULL AND a.deleted_at IS NULL \
             ORDER BY 3 DESC",
            album.clone(),
        ),
        None => (
            "SELECT a.id, a.kind, coalesce(a.edit_taken_at, a.taken_at) FROM assets a \
             WHERE a.id IN (SELECT value FROM json_each(?1)) AND a.user_id = ?2 \
               AND a.trashed_at IS NULL AND a.deleted_at IS NULL \
             ORDER BY 3 DESC",
            share.asset_ids.clone().unwrap_or_else(|| "[]".into()),
        ),
    };
    sqlx::query_as::<_, (String, String, i64)>(sql)
        .bind(bind)
        .bind(&share.user_id)
        .fetch_all(db.read())
        .await
}

/// One more view of the page.
pub(crate) async fn viewed(db: &Db, id: &str) {
    let _ = sqlx::query("UPDATE shares SET views = views + 1 WHERE id = ?")
        .bind(id)
        .execute(db.write())
        .await;
}

/// The album's name, for a link without a title of its own.
pub(crate) async fn album_name(db: &Db, album: &str) -> Option<String> {
    sqlx::query_as::<_, (String,)>("SELECT name FROM albums WHERE id = ?")
        .bind(album)
        .fetch_optional(db.read())
        .await
        .ok()
        .flatten()
        .map(|(name,)| name)
}

/// For the API: a share's fields from JSON (checked).
pub fn parse_ids(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|id| id.as_str())
        .filter_map(|id| uuid::Uuid::parse_str(id.trim()).ok())
        .map(|id| id.to_string())
        .collect()
}
