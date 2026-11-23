//! Uploads that survive anything: a broken connection, a phone that goes to sleep, a server that
//! is killed. The protocol is in the style of tus:
//!
//! 1. `POST /uploads` announces a file (asset id, size, SHA-256, type, metadata).
//! 2. `PATCH /uploads/{id}` with `Upload-Offset` sends bytes. A broken request keeps what
//!    arrived; the next one continues there. The request that delivers the last byte also
//!    finishes the upload.
//! 3. Finishing checks the SHA-256, flushes the file to disk, moves it into the readable library
//!    folder and records it in one database transaction. Only then does the server say
//!    "completed".
//!
//! Partial files live in `<library>/.halden/incoming/`, on the same disk as the library, so the
//! final move is an atomic rename.

mod finalize;
pub mod store;

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use axum::body::Body;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

use self::store::{BodyEnd, Slot};
use crate::{
    accounts::User,
    config::Config,
    db::{Db, now_ms},
    library::{
        assets::{self, Asset},
        paths::{MediaKind, MediaType, PathTemplate},
        space::{NotEnoughSpace, SpaceBook},
    },
};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
/// Finished and failed uploads are forgotten after this long.
const KEEP_FINISHED_MS: i64 = 30 * DAY_MS;
/// Nobody sends a single file bigger than this; it guards against nonsense sizes.
pub const MAX_FILE_BYTES: u64 = 1 << 40;

/// Which file of an asset an upload carries. Thumbnails and previews are small and go up in one
/// request instead (`PUT /assets/{id}/files/{role}`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UploadRole {
    Original,
    /// The video half of a Live Photo.
    PairedVideo,
    /// The RAW of a RAW+HEIC pair.
    Raw,
}

impl UploadRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Original => "original",
            Self::PairedVideo => "paired_video",
            Self::Raw => "raw",
        }
    }

    fn from_db(text: &str) -> Self {
        match text {
            "paired_video" => Self::PairedVideo,
            "raw" => Self::Raw,
            _ => Self::Original,
        }
    }
}

/// What the device knows about a photo. Everything is optional; unknown fields are kept (in the
/// asset's `client_json`) but not used.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientMetadata {
    /// Capture time, UTC milliseconds.
    pub taken_at: Option<i64>,
    /// UTC offset where the photo was taken, e.g. 60 for Berlin in winter.
    pub time_zone_offset_minutes: Option<i32>,
    /// IANA name, e.g. "Europe/Berlin". Stored for display only.
    pub time_zone: Option<String>,
    pub location: Option<ClientLocation>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
    /// Shown in the app, never used for a path on the server.
    pub original_filename: Option<String>,
    #[serde(flatten)]
    pub other: Map<String, Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientLocation {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude: Option<f64>,
    /// Radius in metres in which the true position lies (Core Location's horizontalAccuracy).
    pub horizontal_accuracy: Option<f64>,
    pub vertical_accuracy: Option<f64>,
    /// Compass direction the camera pointed, 0–360 degrees from north.
    pub heading: Option<f64>,
    pub heading_accuracy: Option<f64>,
    #[serde(flatten)]
    pub other: Map<String, Value>,
}

impl ClientMetadata {
    /// Refuses values that can't be true, so nonsense never reaches the library.
    pub fn check(&self) -> Result<(), String> {
        // Years 1900 to 2200.
        const EARLIEST: i64 = -2_208_988_800_000;
        const LATEST: i64 = 7_258_118_400_000;
        if let Some(taken) = self.taken_at
            && !(EARLIEST..=LATEST).contains(&taken)
        {
            return Err("takenAt must be between 1900 and 2200.".into());
        }
        if let Some(offset) = self.time_zone_offset_minutes
            && !(-18 * 60..=18 * 60).contains(&offset)
        {
            return Err("timeZoneOffsetMinutes must be between -1080 and 1080.".into());
        }
        if let Some(location) = &self.location {
            let finite = |v: Option<f64>| v.is_none_or(f64::is_finite);
            if !(-90.0..=90.0).contains(&location.latitude)
                || !(-180.0..=180.0).contains(&location.longitude)
            {
                return Err("The location is outside the valid range.".into());
            }
            if !finite(location.altitude)
                || location
                    .horizontal_accuracy
                    .is_some_and(|a| !a.is_finite() || a < 0.0)
                || location
                    .heading
                    .is_some_and(|h| !(0.0..=360.0).contains(&h))
            {
                return Err("The location has invalid accuracy, altitude or heading.".into());
            }
        }
        if self.time_zone.as_ref().is_some_and(|z| z.len() > 64)
            || self
                .original_filename
                .as_ref()
                .is_some_and(|n| n.len() > 255)
        {
            return Err("timeZone or originalFilename is too long.".into());
        }
        Ok(())
    }
}

/// A checked `POST /uploads`.
pub struct NewUpload {
    pub asset_id: Uuid,
    pub role: UploadRole,
    pub size: u64,
    pub sha256: [u8; 32],
    pub media: MediaType,
    pub metadata: ClientMetadata,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadProgress {
    pub upload_id: String,
    pub asset_id: String,
    pub offset: u64,
    pub size: u64,
    pub expires_at: i64,
}

/// Where an upload stands.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum UploadState {
    /// Send the rest, starting at `offset`.
    Receiving(UploadProgress),
    /// Safely stored.
    Completed { asset: Box<Asset> },
    /// The same content is already stored under another asset id; nothing to upload.
    #[serde(rename_all = "camelCase")]
    Duplicate { existing_asset_id: String },
}

#[derive(Debug, thiserror::Error)]
pub enum UploadError {
    #[error("no such upload")]
    NotFound,
    #[error("another request is sending this upload right now")]
    Busy,
    #[error("the upload is at byte {expected}")]
    OffsetMismatch { expected: u64 },
    #[error("the file does not match its SHA-256")]
    ChecksumMismatch,
    #[error("the upload failed: {0}")]
    Failed(String),
    #[error("{0}")]
    Conflict(String),
    #[error("not enough space")]
    NotEnoughSpace(NotEnoughSpace),
    #[error(transparent)]
    Database(#[from] sqlx::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(sqlx::FromRow, Clone)]
struct UploadRow {
    id: String,
    asset_id: String,
    role: String,
    size: i64,
    sha256: Vec<u8>,
    mime: String,
    metadata_json: Option<String>,
    state: String,
    error: Option<String>,
    expires_at: i64,
}

macro_rules! upload_columns {
    () => {
        "id, asset_id, role, size, sha256, mime, metadata_json, state, error, expires_at"
    };
}

/// Everything about uploads that lives in memory: partial-file state and promised space.
pub struct Uploads {
    library: PathBuf,
    incoming: PathBuf,
    template: PathTemplate,
    expiry_ms: i64,
    space: SpaceBook,
    slots: Mutex<HashMap<Uuid, Arc<tokio::sync::Mutex<Slot>>>>,
    /// Choosing a name and moving a file into the library happen one at a time, so two uploads
    /// taken in the same second can't pick the same name.
    placing: tokio::sync::Mutex<()>,
    /// The server makes thumbnails the phone didn't send after this long.
    thumbnail_delay_ms: i64,
    /// Wakes the background workers when a finished upload queued work for them.
    wake: Arc<tokio::sync::Notify>,
}

impl Uploads {
    pub fn new(config: &Config, wake: Arc<tokio::sync::Notify>) -> anyhow::Result<Self> {
        let template = PathTemplate::parse(&config.storage.path_template)
            .map_err(|problem| anyhow::anyhow!("storage.path_template: {problem}"))?;
        Ok(Self {
            library: config.storage.library_dir.clone(),
            incoming: config.incoming_dir(),
            template,
            expiry_ms: i64::from(config.storage.upload_expiry_days.max(1)) * DAY_MS,
            space: SpaceBook::new(
                &config.storage.library_dir,
                config.storage.min_free_gb.saturating_mul(1_000_000_000),
            ),
            slots: Mutex::new(HashMap::new()),
            placing: tokio::sync::Mutex::new(()),
            thumbnail_delay_ms: i64::from(config.jobs.thumbnail_delay_minutes) * 60_000,
            wake,
        })
    }

    fn part_path(&self, id: &str) -> PathBuf {
        self.incoming.join(format!("{id}.part"))
    }

    fn slots(&self) -> std::sync::MutexGuard<'_, HashMap<Uuid, Arc<tokio::sync::Mutex<Slot>>>> {
        self.slots
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn slot(&self, id: Uuid) -> Arc<tokio::sync::Mutex<Slot>> {
        self.slots()
            .entry(id)
            .or_insert_with(|| {
                Arc::new(tokio::sync::Mutex::new(Slot {
                    received: 0,
                    hasher: None,
                }))
            })
            .clone()
    }

    fn forget(&self, id: Uuid) {
        self.slots().remove(&id);
        self.space.release(id);
    }

    /// Uploads that are receiving right now or waiting to continue.
    pub fn in_progress(&self) -> usize {
        self.slots().len()
    }

    /// After a start: counts the space unfinished uploads still need and removes partial files
    /// nobody is waiting for.
    pub async fn recover(&self, db: &Db) -> anyhow::Result<()> {
        let rows: Vec<(String, i64)> =
            sqlx::query_as("SELECT id, size FROM uploads WHERE state = 'receiving'")
                .fetch_all(db.read())
                .await?;
        let mut waiting = std::collections::HashSet::new();
        for (id, size) in rows {
            let Ok(uuid) = Uuid::parse_str(&id) else {
                continue;
            };
            let on_disk = std::fs::metadata(self.part_path(&id)).map_or(0, |m| m.len());
            self.space
                .update(uuid, (size as u64).saturating_sub(on_disk));
            waiting.insert(format!("{id}.part"));
        }
        if let Ok(entries) = std::fs::read_dir(&self.incoming) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.ends_with(".part") && !waiting.contains(&name) {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
        Ok(())
    }

    async fn load(&self, db: &Db, user_id: &str, id: &str) -> Result<UploadRow, UploadError> {
        sqlx::query_as::<_, UploadRow>(concat!(
            "SELECT ",
            upload_columns!(),
            " FROM uploads WHERE id = ? AND user_id = ?"
        ))
        .bind(id)
        .bind(user_id)
        .fetch_optional(db.read())
        .await?
        .ok_or(UploadError::NotFound)
    }

    /// `POST /uploads`.
    pub async fn create(
        &self,
        db: &Db,
        user: &User,
        device_id: &str,
        new: NewUpload,
    ) -> Result<UploadState, UploadError> {
        let asset_id = new.asset_id.to_string();
        match assets::owner_of(db, &asset_id).await? {
            Some(owner) if owner != user.id => {
                return Err(UploadError::Conflict(
                    "This asset id is already in use.".into(),
                ));
            }
            Some(_) => {
                if let Some(stored) = assets::file_hash(db, &asset_id, new.role.as_str()).await? {
                    if stored.as_slice() != new.sha256 {
                        return Err(UploadError::Conflict(format!(
                            "This asset already has a different {} file.",
                            new.role.as_str()
                        )));
                    }
                    return self.completed(db, &user.id, &asset_id).await;
                }
                if new.role == UploadRole::Original {
                    return Err(UploadError::Conflict(
                        "This asset already exists without an original.".into(),
                    ));
                }
            }
            None if new.role != UploadRole::Original => {
                return Err(UploadError::Conflict(
                    "Upload the original of this asset first.".into(),
                ));
            }
            None => {
                if let Some(existing) =
                    assets::original_with_hash(db, &user.id, &new.sha256).await?
                {
                    return Ok(UploadState::Duplicate {
                        existing_asset_id: existing,
                    });
                }
            }
        }
        match (new.role, new.media.kind) {
            (UploadRole::PairedVideo, MediaKind::Photo) => {
                return Err(UploadError::Conflict(
                    "The paired file of a Live Photo must be a video.".into(),
                ));
            }
            (UploadRole::Raw, MediaKind::Video) => {
                return Err(UploadError::Conflict("A RAW file must be a photo.".into()));
            }
            _ => {}
        }

        // The same file announced again (the app lost the upload id): continue that upload.
        let earlier = sqlx::query_as::<_, UploadRow>(concat!(
            "SELECT ",
            upload_columns!(),
            " FROM uploads WHERE user_id = ? AND asset_id = ? AND role = ? AND state = 'receiving'"
        ))
        .bind(&user.id)
        .bind(&asset_id)
        .bind(new.role.as_str())
        .fetch_all(db.read())
        .await?;
        for row in earlier {
            if row.sha256 == new.sha256 && row.size as u64 == new.size {
                let offset = self.offset_of(&row).await;
                if let Ok(uuid) = Uuid::parse_str(&row.id) {
                    self.space.update(uuid, new.size.saturating_sub(offset));
                }
                return Ok(UploadState::Receiving(self.progress(&row, offset)));
            }
            self.discard(db, &row, "replaced by a newer upload").await?;
        }

        let id = Uuid::new_v4();
        self.space
            .reserve(id, new.size)
            .map_err(UploadError::NotEnoughSpace)?;
        let now = now_ms();
        let metadata_json = serde_json::to_string(&new.metadata).ok();
        let result = async {
            store::create_part(&self.part_path(&id.to_string()))?;
            sqlx::query(
                "INSERT INTO uploads (id, user_id, device_id, asset_id, role, kind, size, sha256, \
                     mime, metadata_json, state, created_at, updated_at, expires_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'receiving', ?, ?, ?)",
            )
            .bind(id.to_string())
            .bind(&user.id)
            .bind(device_id)
            .bind(&asset_id)
            .bind(new.role.as_str())
            .bind(new.media.kind.as_str())
            .bind(new.size as i64)
            .bind(new.sha256.as_slice())
            .bind(new.media.mime)
            .bind(metadata_json)
            .bind(now)
            .bind(now)
            .bind(now + self.expiry_ms)
            .execute(db.write())
            .await?;
            Ok::<_, UploadError>(())
        }
        .await;
        if let Err(error) = result {
            self.space.release(id);
            let _ = std::fs::remove_file(self.part_path(&id.to_string()));
            return Err(error);
        }
        Ok(UploadState::Receiving(UploadProgress {
            upload_id: id.to_string(),
            asset_id,
            offset: 0,
            size: new.size,
            expires_at: now + self.expiry_ms,
        }))
    }

    async fn completed(
        &self,
        db: &Db,
        user_id: &str,
        asset_id: &str,
    ) -> Result<UploadState, UploadError> {
        let asset = assets::get(db.read(), user_id, asset_id)
            .await?
            .ok_or(UploadError::NotFound)?;
        Ok(UploadState::Completed {
            asset: Box::new(asset),
        })
    }

    fn progress(&self, row: &UploadRow, offset: u64) -> UploadProgress {
        UploadProgress {
            upload_id: row.id.clone(),
            asset_id: row.asset_id.clone(),
            offset,
            size: row.size as u64,
            expires_at: row.expires_at,
        }
    }

    /// Bytes safely received: what the slot knows, or else what is on disk.
    async fn offset_of(&self, row: &UploadRow) -> u64 {
        if let Ok(id) = Uuid::parse_str(&row.id) {
            let slot = self.slots().get(&id).cloned();
            if let Some(slot) = slot
                && let Ok(slot) = slot.try_lock()
                && slot.hasher.is_some()
            {
                return slot.received;
            }
        }
        std::fs::metadata(self.part_path(&row.id)).map_or(0, |m| m.len())
    }

    /// `GET`/`HEAD /uploads/{id}`.
    pub async fn status(&self, db: &Db, user: &User, id: &str) -> Result<UploadState, UploadError> {
        let row = self.load(db, &user.id, id).await?;
        match row.state.as_str() {
            "completed" => self.completed(db, &user.id, &row.asset_id).await,
            "failed" => Err(UploadError::Failed(row.error.unwrap_or_default())),
            _ => {
                let offset = self.offset_of(&row).await;
                Ok(UploadState::Receiving(self.progress(&row, offset)))
            }
        }
    }

    /// `PATCH /uploads/{id}`: appends the body at `offset`. Finishes the upload when its last
    /// byte arrives. `POST /uploads/{id}/complete` calls this with an empty body.
    pub async fn receive(
        &self,
        db: &Db,
        user: &User,
        id: &str,
        offset: u64,
        body: Body,
    ) -> Result<UploadState, UploadError> {
        let row = self.load(db, &user.id, id).await?;
        match row.state.as_str() {
            "completed" => return self.completed(db, &user.id, &row.asset_id).await,
            "failed" => return Err(UploadError::Failed(row.error.unwrap_or_default())),
            _ => {}
        }
        let uuid = Uuid::parse_str(&row.id).map_err(|_| UploadError::NotFound)?;
        let slot = self.slot(uuid);
        let Ok(mut slot) = slot.try_lock_owned() else {
            return Err(UploadError::Busy);
        };
        let part = self.part_path(&row.id);
        let size = row.size as u64;

        if slot.hasher.is_none() {
            let (hasher, length) = store::rehash(part.clone()).await?;
            slot.hasher = Some(hasher);
            slot.received = length;
        }
        if offset != slot.received {
            return Err(UploadError::OffsetMismatch {
                expected: slot.received,
            });
        }

        let remaining = size - slot.received;
        let mut end = BodyEnd::Complete;
        if remaining > 0 {
            let hasher = slot.hasher.take().unwrap_or_default();
            let appended = store::append(part.clone(), hasher, body, remaining).await;
            slot.hasher = appended.hasher;
            end = appended.end;
            if let Some(error) = appended.error {
                // What exactly reached the disk is unclear; the next request rehashes the file.
                slot.received = std::fs::metadata(&part).map_or(slot.received, |m| m.len());
                tracing::error!(%error, upload = %row.id, "could not write an upload");
                return Err(UploadError::Io(error));
            }
            slot.received += appended.written;
            self.space.update(uuid, size - slot.received);
            sqlx::query("UPDATE uploads SET updated_at = ?1, expires_at = ?2 WHERE id = ?3")
                .bind(now_ms())
                .bind(now_ms() + self.expiry_ms)
                .bind(&row.id)
                .execute(db.write())
                .await?;
        }
        if end == BodyEnd::TooLong {
            tracing::debug!(upload = %row.id, "the client sent more than the upload's size");
        }

        if slot.received < size {
            return Ok(UploadState::Receiving(self.progress(&row, slot.received)));
        }
        let hasher = slot.hasher.take().unwrap_or_default();
        let result = finalize::finish(self, db, user, &row, hasher).await;
        // Whatever the outcome, this upload needs no memory any more.
        drop(slot);
        self.forget(uuid);
        match result {
            Ok(asset) => Ok(UploadState::Completed {
                asset: Box::new(asset),
            }),
            Err(error) => Err(error),
        }
    }

    /// `DELETE /uploads/{id}`.
    pub async fn cancel(&self, db: &Db, user: &User, id: &str) -> Result<(), UploadError> {
        let row = self.load(db, &user.id, id).await?;
        if row.state != "receiving" {
            return Ok(());
        }
        let uuid = Uuid::parse_str(&row.id).map_err(|_| UploadError::NotFound)?;
        let slot = self.slot(uuid);
        let Ok(_sending) = slot.try_lock() else {
            return Err(UploadError::Busy);
        };
        self.discard(db, &row, "cancelled").await
    }

    /// Marks an upload failed and throws its partial file away.
    async fn discard(&self, db: &Db, row: &UploadRow, reason: &str) -> Result<(), UploadError> {
        sqlx::query("UPDATE uploads SET state = 'failed', error = ?, updated_at = ? WHERE id = ?")
            .bind(reason)
            .bind(now_ms())
            .bind(&row.id)
            .execute(db.write())
            .await?;
        let _ = std::fs::remove_file(self.part_path(&row.id));
        if let Ok(uuid) = Uuid::parse_str(&row.id) {
            self.forget(uuid);
        }
        Ok(())
    }

    /// Throws away uploads that made no progress for too long, and forgets old finished ones.
    pub async fn expire(&self, db: &Db, now: i64) -> Result<u64, UploadError> {
        let stale = sqlx::query_as::<_, UploadRow>(concat!(
            "SELECT ",
            upload_columns!(),
            " FROM uploads WHERE state = 'receiving' AND expires_at < ?"
        ))
        .bind(now)
        .fetch_all(db.read())
        .await?;
        let mut expired = 0;
        for row in &stale {
            let busy = Uuid::parse_str(&row.id)
                .ok()
                .and_then(|id| self.slots().get(&id).cloned())
                .is_some_and(|slot| slot.try_lock().is_err());
            if !busy {
                self.discard(db, row, "expired").await?;
                expired += 1;
            }
        }
        sqlx::query("DELETE FROM uploads WHERE state <> 'receiving' AND updated_at < ?")
            .bind(now - KEEP_FINISHED_MS)
            .execute(db.write())
            .await?;
        Ok(expired)
    }

    pub(crate) fn library(&self) -> &Path {
        &self.library
    }
}

impl UploadRow {
    fn role(&self) -> UploadRole {
        UploadRole::from_db(&self.role)
    }
}
