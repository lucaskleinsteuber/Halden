//! Photos and videos ("assets") and their files in the database.

use serde::Serialize;
use serde_json::Value;
use sqlx::{Executor, Sqlite, SqliteConnection};

use crate::db::{Db, now_ms};

/// The roles a file can have within an asset.
pub const ROLES: &[&str] = &[
    "original",
    "thumbnail",
    "preview",
    "converted",
    "paired_video",
    "raw",
    "stream",
];

/// An asset as devices see it: the *effective* metadata (corrections where there are any, the
/// original otherwise). The original values stay stored; `GET /assets/{id}` shows them.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub id: String,
    pub kind: String,
    /// When it was taken, UTC milliseconds.
    pub taken_at: i64,
    /// UTC offset where it was taken, if known.
    #[serde(rename = "timeZoneOffsetMinutes")]
    pub tz_offset_min: Option<i64>,
    /// `client`, `exif`, `upload`, or `manual` when corrected.
    pub taken_at_source: String,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub duration_ms: Option<i64>,
    pub location: Option<Location>,
    pub camera: Option<Camera>,
    pub title: Option<String>,
    pub description: Option<String>,
    /// How a video was taken: `slowmo` or `timelapse`; `null` for everything else.
    pub capture_mode: Option<String>,
    /// How it plays: the slow part of a slow-motion video (a correction).
    pub playback: Option<Value>,
    /// The edit (light, colour, crop, trim) the apps apply; `null` for none.
    pub edit: Option<Value>,
    pub files: Vec<AssetFile>,
    pub created_at: i64,
    pub updated_at: i64,
    pub seq: i64,
    pub trashed_at: Option<i64>,
    pub deleted_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Location {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude: Option<f64>,
    pub accuracy_meters: Option<f64>,
    pub heading: Option<f64>,
    /// `client` (the phone's location service), `exif` (from the file), `manual` (corrected by
    /// hand), `estimated` (taken from a neighbouring photo) or `device` (where the phone was, e.g.
    /// for a screenshot).
    pub source: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Camera {
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetFile {
    pub role: String,
    /// Lowercase hex. Also the file's URL: `/api/v1/files/{sha256}`.
    pub sha256: String,
    pub size: i64,
    #[serde(rename = "mimeType")]
    pub mime: String,
    pub width: Option<i64>,
    pub height: Option<i64>,
}

macro_rules! asset_columns {
    () => {
        "a.id, a.kind, a.taken_at, a.tz_offset_min, a.taken_at_source, a.width, \
         a.height, a.duration_ms, a.camera_make, a.camera_model, a.lens, a.latitude, a.longitude, \
         a.altitude, a.location_accuracy_m, a.heading, a.location_source, a.created_at, \
         a.updated_at, a.seq, a.trashed_at, a.deleted_at, a.title, a.description, \
         a.edit_taken_at, a.edit_tz_offset_min, a.edit_latitude, a.edit_longitude, \
         a.edit_altitude, a.edit_location_source, a.location_hidden, a.capture_mode, \
         a.playback_json, a.edit_json"
    };
}
pub(crate) use asset_columns;

#[derive(sqlx::FromRow, Clone)]
pub(crate) struct AssetRow {
    pub id: String,
    kind: String,
    pub taken_at: i64,
    pub tz_offset_min: Option<i64>,
    pub taken_at_source: String,
    width: Option<i64>,
    height: Option<i64>,
    duration_ms: Option<i64>,
    camera_make: Option<String>,
    camera_model: Option<String>,
    lens: Option<String>,
    latitude: Option<f64>,
    longitude: Option<f64>,
    altitude: Option<f64>,
    location_accuracy_m: Option<f64>,
    heading: Option<f64>,
    location_source: Option<String>,
    created_at: i64,
    updated_at: i64,
    pub seq: i64,
    trashed_at: Option<i64>,
    deleted_at: Option<i64>,
    title: Option<String>,
    description: Option<String>,
    pub edit_taken_at: Option<i64>,
    pub edit_tz_offset_min: Option<i64>,
    edit_latitude: Option<f64>,
    edit_longitude: Option<f64>,
    edit_altitude: Option<f64>,
    edit_location_source: Option<String>,
    location_hidden: bool,
    capture_mode: Option<String>,
    pub playback_json: Option<String>,
    pub edit_json: Option<String>,
}

impl AssetRow {
    /// The location as recorded, before any correction.
    pub(crate) fn original_location(&self) -> Option<Location> {
        Some(Location {
            latitude: self.latitude?,
            longitude: self.longitude?,
            altitude: self.altitude,
            accuracy_meters: self.location_accuracy_m,
            heading: self.heading,
            source: self
                .location_source
                .clone()
                .unwrap_or_else(|| "client".into()),
        })
    }

    /// The location devices should show.
    pub(crate) fn effective_location(&self) -> Option<Location> {
        if self.location_hidden {
            return None;
        }
        match (self.edit_latitude, self.edit_longitude) {
            (Some(latitude), Some(longitude)) => Some(Location {
                latitude,
                longitude,
                altitude: self.edit_altitude,
                accuracy_meters: None,
                heading: None,
                source: self
                    .edit_location_source
                    .clone()
                    .unwrap_or_else(|| "manual".into()),
            }),
            _ => self.original_location(),
        }
    }

    pub(crate) fn into_asset(self, files: Vec<AssetFile>) -> Asset {
        let location = self.effective_location();
        let (taken_at, tz_offset_min, taken_at_source) = match self.edit_taken_at {
            Some(edited) => (
                edited,
                self.edit_tz_offset_min.or(self.tz_offset_min),
                "manual".to_string(),
            ),
            None => (self.taken_at, self.tz_offset_min, self.taken_at_source),
        };
        let camera =
            (self.camera_make.is_some() || self.camera_model.is_some() || self.lens.is_some())
                .then_some(Camera {
                    make: self.camera_make,
                    model: self.camera_model,
                    lens: self.lens,
                });
        Asset {
            id: self.id,
            kind: self.kind,
            taken_at,
            tz_offset_min,
            taken_at_source,
            width: self.width,
            height: self.height,
            duration_ms: self.duration_ms,
            location,
            camera,
            title: self.title,
            description: self.description,
            capture_mode: self.capture_mode,
            playback: self
                .playback_json
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok()),
            edit: self
                .edit_json
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok()),
            files,
            created_at: self.created_at,
            updated_at: self.updated_at,
            seq: self.seq,
            trashed_at: self.trashed_at,
            deleted_at: self.deleted_at,
        }
    }
}

#[derive(sqlx::FromRow)]
pub(crate) struct FileRow {
    pub asset_id: String,
    pub role: String,
    pub sha256: Vec<u8>,
    pub size: i64,
    pub mime: String,
    pub width: Option<i64>,
    pub height: Option<i64>,
}

impl From<FileRow> for AssetFile {
    fn from(row: FileRow) -> Self {
        Self {
            role: row.role,
            sha256: hex::encode(row.sha256),
            size: row.size,
            mime: row.mime,
            width: row.width,
            height: row.height,
        }
    }
}

/// The files of many assets in one query, by asset id.
pub(crate) async fn files_for<'e, E>(
    db: E,
    asset_ids: &[&str],
) -> Result<std::collections::HashMap<String, Vec<AssetFile>>, sqlx::Error>
where
    E: Executor<'e, Database = Sqlite>,
{
    let mut by_asset: std::collections::HashMap<String, Vec<AssetFile>> =
        std::collections::HashMap::with_capacity(asset_ids.len());
    if asset_ids.is_empty() {
        return Ok(by_asset);
    }
    let ids = serde_json::to_string(asset_ids).unwrap_or_else(|_| "[]".into());
    let rows = sqlx::query_as::<_, FileRow>(
        "SELECT asset_id, role, sha256, size, mime, width, height FROM asset_files \
         WHERE asset_id IN (SELECT value FROM json_each(?)) ORDER BY asset_id, role",
    )
    .bind(ids)
    .fetch_all(db)
    .await?;
    for row in rows {
        by_asset
            .entry(row.asset_id.clone())
            .or_default()
            .push(row.into());
    }
    Ok(by_asset)
}

/// Turns rows into assets, loading all their files with one more query.
pub(crate) async fn with_files<'e, E>(db: E, rows: Vec<AssetRow>) -> Result<Vec<Asset>, sqlx::Error>
where
    E: Executor<'e, Database = Sqlite>,
{
    let ids: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();
    let mut files = files_for(db, &ids).await?;
    Ok(rows
        .into_iter()
        .map(|row| {
            let files = files.remove(&row.id).unwrap_or_default();
            row.into_asset(files)
        })
        .collect())
}

impl AssetRow {
    /// Deleted for good: only a tombstone is left, which nothing may change any more.
    pub(crate) fn is_deleted(&self) -> bool {
        self.deleted_at.is_some()
    }
}

/// The raw row of one asset of one account.
pub(crate) async fn row<'e, E>(
    db: E,
    user_id: &str,
    asset_id: &str,
) -> Result<Option<AssetRow>, sqlx::Error>
where
    E: Executor<'e, Database = Sqlite>,
{
    sqlx::query_as::<_, AssetRow>(concat!(
        "SELECT ",
        asset_columns!(),
        " FROM assets a WHERE a.id = ? AND a.user_id = ?"
    ))
    .bind(asset_id)
    .bind(user_id)
    .fetch_optional(db)
    .await
}

/// The next number for a change. Call inside the write transaction that makes the change.
pub async fn next_seq(tx: &mut SqliteConnection) -> Result<i64, sqlx::Error> {
    let (seq,): (i64,) = sqlx::query_as(
        "UPDATE counters SET value = value + 1 WHERE name = 'asset_seq' RETURNING value",
    )
    .fetch_one(&mut *tx)
    .await?;
    Ok(seq)
}

/// One asset of one account, with its files. Other accounts' assets don't exist for it.
pub async fn get<'e, E>(db: E, user_id: &str, asset_id: &str) -> Result<Option<Asset>, sqlx::Error>
where
    E: Executor<'e, Database = Sqlite> + Copy,
{
    let Some(row) = sqlx::query_as::<_, AssetRow>(concat!(
        "SELECT ",
        asset_columns!(),
        " FROM assets a WHERE a.id = ? AND a.user_id = ?"
    ))
    .bind(asset_id)
    .bind(user_id)
    .fetch_optional(db)
    .await?
    else {
        return Ok(None);
    };
    let files = files_of(db, asset_id).await?;
    Ok(Some(row.into_asset(files)))
}

async fn files_of<'e, E>(db: E, asset_id: &str) -> Result<Vec<AssetFile>, sqlx::Error>
where
    E: Executor<'e, Database = Sqlite>,
{
    let rows = sqlx::query_as::<_, FileRow>(
        "SELECT asset_id, role, sha256, size, mime, width, height FROM asset_files \
         WHERE asset_id = ? ORDER BY role",
    )
    .bind(asset_id)
    .fetch_all(db)
    .await?;
    Ok(rows.into_iter().map(AssetFile::from).collect())
}

/// Where a file of the account lives on disk, for sending it.
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct StoredFile {
    pub storage: String,
    pub path: String,
    pub mime: String,
    pub sha256: Vec<u8>,
    pub size: i64,
}

impl StoredFile {
    /// The absolute path, checked to stay inside its root.
    pub fn resolve(
        &self,
        library: &std::path::Path,
        derived: &std::path::Path,
    ) -> Option<std::path::PathBuf> {
        let root = if self.storage == "library" {
            library
        } else {
            derived
        };
        crate::library::paths::resolve(root, &self.path)
    }

    /// A file name for saving: the readable library name, or the hash for thumbnails.
    pub fn download_name(&self) -> Option<String> {
        (self.storage == "library")
            .then(|| {
                std::path::Path::new(&self.path)
                    .file_name()?
                    .to_str()
                    .map(str::to_string)
            })
            .flatten()
    }
}

/// An asset's file in a role (only the account's own assets).
pub async fn stored_file(
    db: &Db,
    user_id: &str,
    asset_id: &str,
    role: &str,
) -> Result<Option<StoredFile>, sqlx::Error> {
    sqlx::query_as(
        "SELECT storage, path, mime, sha256, size FROM asset_files \
         WHERE asset_id = ? AND role = ? AND user_id = ?",
    )
    .bind(asset_id)
    .bind(role)
    .bind(user_id)
    .fetch_optional(db.read())
    .await
}

/// Any file of the account with this content.
pub async fn stored_file_by_hash(
    db: &Db,
    user_id: &str,
    sha256: &[u8],
) -> Result<Option<StoredFile>, sqlx::Error> {
    sqlx::query_as(
        "SELECT storage, path, mime, sha256, size FROM asset_files \
         WHERE user_id = ? AND sha256 = ? LIMIT 1",
    )
    .bind(user_id)
    .bind(sha256)
    .fetch_optional(db.read())
    .await
}

/// The files in one role of many assets, in one query: asset id → file.
pub async fn stored_files_for(
    db: &Db,
    user_id: &str,
    asset_ids: &[String],
    role: &str,
) -> Result<std::collections::HashMap<String, StoredFile>, sqlx::Error> {
    #[derive(sqlx::FromRow)]
    struct Row {
        asset_id: String,
        #[sqlx(flatten)]
        file: StoredFile,
    }
    let ids = serde_json::to_string(asset_ids).unwrap_or_else(|_| "[]".into());
    let rows = sqlx::query_as::<_, Row>(
        "SELECT asset_id, storage, path, mime, sha256, size FROM asset_files \
         WHERE user_id = ?1 AND role = ?2 AND asset_id IN (SELECT value FROM json_each(?3))",
    )
    .bind(user_id)
    .bind(role)
    .bind(ids)
    .fetch_all(db.read())
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| (row.asset_id, row.file))
        .collect())
}

/// The first library name that is free on disk and in the database. Call while holding the
/// placing lock, so nobody else takes the name before the file is moved there.
pub async fn free_library_name(
    db: &Db,
    library: &std::path::Path,
    base: &std::path::Path,
    extension: &str,
) -> Result<std::path::PathBuf, sqlx::Error> {
    let mut number = 1u32;
    loop {
        let candidate = crate::library::paths::numbered(base, number, extension);
        let text = candidate.to_string_lossy();
        let on_disk = std::fs::symlink_metadata(library.join(&candidate)).is_ok();
        let in_db: Option<(i64,)> =
            sqlx::query_as("SELECT 1 FROM asset_files WHERE storage = 'library' AND path = ?")
                .bind(text.as_ref())
                .fetch_optional(db.read())
                .await?;
        if !on_disk && in_db.is_none() {
            return Ok(candidate);
        }
        number += 1;
    }
}

/// Who owns an asset id (any account). Lets uploads refuse an id that another account uses
/// without telling whose it is.
pub async fn owner_of(db: &Db, asset_id: &str) -> Result<Option<String>, sqlx::Error> {
    let owner: Option<(String,)> = sqlx::query_as("SELECT user_id FROM assets WHERE id = ?")
        .bind(asset_id)
        .fetch_optional(db.read())
        .await?;
    Ok(owner.map(|(user,)| user))
}

/// The hash of an asset's file in a role.
pub async fn file_hash(
    db: &Db,
    asset_id: &str,
    role: &str,
) -> Result<Option<Vec<u8>>, sqlx::Error> {
    let hash: Option<(Vec<u8>,)> =
        sqlx::query_as("SELECT sha256 FROM asset_files WHERE asset_id = ? AND role = ?")
            .bind(asset_id)
            .bind(role)
            .fetch_optional(db.read())
            .await?;
    Ok(hash.map(|(hash,)| hash))
}

/// Another asset of this account whose original has exactly this content.
pub async fn original_with_hash(
    db: &Db,
    user_id: &str,
    sha256: &[u8],
) -> Result<Option<String>, sqlx::Error> {
    let found: Option<(String,)> = sqlx::query_as(
        "SELECT f.asset_id FROM asset_files f JOIN assets a ON a.id = f.asset_id \
         WHERE f.user_id = ? AND f.sha256 = ? AND f.role = 'original' AND a.deleted_at IS NULL \
         LIMIT 1",
    )
    .bind(user_id)
    .bind(sha256)
    .fetch_optional(db.read())
    .await?;
    Ok(found.map(|(id,)| id))
}

/// How many other files point at this derived path (thumbnails are shared by content).
pub async fn derived_path_users(db: &Db, path: &str) -> Result<i64, sqlx::Error> {
    let (count,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM asset_files WHERE storage = 'derived' AND path = ?")
            .bind(path)
            .fetch_one(db.read())
            .await?;
    Ok(count)
}

/// What `POST /assets/check` answers for one item.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "status"
)]
pub enum CheckResult {
    /// This asset id has an original with this hash.
    BackedUp { asset_id: String },
    /// The content is backed up under another asset id.
    Duplicate {
        asset_id: String,
        existing_asset_id: String,
    },
    /// Needs to be uploaded.
    Missing { asset_id: String },
    /// This asset id is backed up, but with different content.
    Conflict { asset_id: String },
}

/// Answers for many (asset id, hash) pairs with two queries, however many items there are.
pub async fn check_many(
    db: &Db,
    user_id: &str,
    items: &[(String, [u8; 32])],
) -> Result<Vec<CheckResult>, sqlx::Error> {
    use std::collections::HashMap;

    let ids: Vec<&str> = items.iter().map(|(id, _)| id.as_str()).collect();
    let hashes: Vec<String> = items.iter().map(|(_, hash)| hex::encode(hash)).collect();
    let ids_json = serde_json::to_string(&ids).unwrap_or_else(|_| "[]".into());
    let hashes_json = serde_json::to_string(&hashes).unwrap_or_else(|_| "[]".into());

    let by_id: HashMap<String, Vec<u8>> = sqlx::query_as::<_, (String, Vec<u8>)>(
        "SELECT f.asset_id, f.sha256 FROM asset_files f JOIN assets a ON a.id = f.asset_id \
         WHERE f.user_id = ?1 AND f.role = 'original' AND a.deleted_at IS NULL \
           AND f.asset_id IN (SELECT value FROM json_each(?2))",
    )
    .bind(user_id)
    .bind(ids_json)
    .fetch_all(db.read())
    .await?
    .into_iter()
    .collect();
    let by_hash: HashMap<Vec<u8>, String> = sqlx::query_as::<_, (Vec<u8>, String)>(
        "SELECT f.sha256, f.asset_id FROM asset_files f JOIN assets a ON a.id = f.asset_id \
         WHERE f.user_id = ?1 AND f.role = 'original' AND a.deleted_at IS NULL \
           AND f.sha256 IN (SELECT unhex(value) FROM json_each(?2))",
    )
    .bind(user_id)
    .bind(hashes_json)
    .fetch_all(db.read())
    .await?
    .into_iter()
    .collect();

    Ok(items
        .iter()
        .map(
            |(id, hash)| match (by_id.get(id), by_hash.get(hash.as_slice())) {
                (Some(stored), _) if stored.as_slice() == hash => CheckResult::BackedUp {
                    asset_id: id.clone(),
                },
                (Some(_), _) => CheckResult::Conflict {
                    asset_id: id.clone(),
                },
                (None, Some(existing)) => CheckResult::Duplicate {
                    asset_id: id.clone(),
                    existing_asset_id: existing.clone(),
                },
                (None, None) => CheckResult::Missing {
                    asset_id: id.clone(),
                },
            },
        )
        .collect())
}

/// Counts for `halden status` and the library overview.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryStats {
    pub photos: i64,
    pub videos: i64,
    pub trashed: i64,
    /// Bytes of originals and conversions on the library disk.
    pub library_bytes: i64,
}

pub async fn stats(db: &Db, user_id: Option<&str>) -> Result<LibraryStats, sqlx::Error> {
    let (photos, videos, trashed): (i64, i64, i64) = sqlx::query_as(
        "SELECT \
             coalesce(sum(kind = 'photo' AND trashed_at IS NULL), 0), \
             coalesce(sum(kind = 'video' AND trashed_at IS NULL), 0), \
             coalesce(sum(trashed_at IS NOT NULL), 0) \
         FROM assets WHERE deleted_at IS NULL AND (?1 IS NULL OR user_id = ?1)",
    )
    .bind(user_id)
    .fetch_one(db.read())
    .await?;
    let (library_bytes,): (i64,) = sqlx::query_as(
        "SELECT coalesce(sum(size), 0) FROM asset_files \
         WHERE storage = 'library' AND (?1 IS NULL OR user_id = ?1)",
    )
    .bind(user_id)
    .fetch_one(db.read())
    .await?;
    Ok(LibraryStats {
        photos,
        videos,
        trashed,
        library_bytes,
    })
}

/// Marks an asset as changed: new `seq`, new `updated_at`.
pub async fn touch(tx: &mut SqliteConnection, asset_id: &str) -> Result<i64, sqlx::Error> {
    let seq = next_seq(tx).await?;
    sqlx::query("UPDATE assets SET seq = ?, updated_at = ? WHERE id = ?")
        .bind(seq)
        .bind(now_ms())
        .bind(asset_id)
        .execute(&mut *tx)
        .await?;
    Ok(seq)
}
