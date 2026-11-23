//! Thumbnails and previews. The phone makes them and sends each in one request; they live on the
//! fast disk, named by their hash (`derived/ab/cd/<sha256>.jpg`). A name that is its content
//! never changes, so devices can cache them forever.

use std::path::{Path, PathBuf};

use bytes::Bytes;
use sha2::{Digest, Sha256};

use crate::{
    db::{Db, now_ms},
    fsutil,
    library::{
        assets::{self, Asset},
        paths::{self, MediaType},
    },
};

/// Thumbnails and previews are small; anything bigger is refused.
pub const MAX_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DerivedRole {
    Thumbnail,
    Preview,
}

impl DerivedRole {
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "thumbnail" => Some(Self::Thumbnail),
            "preview" => Some(Self::Preview),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Thumbnail => "thumbnail",
            Self::Preview => "preview",
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DerivedError {
    #[error("no such asset")]
    NotFound,
    #[error("the file does not match its SHA-256")]
    ChecksumMismatch,
    #[error(transparent)]
    Database(#[from] sqlx::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub struct NewDerived {
    pub role: DerivedRole,
    pub media: MediaType,
    pub sha256: [u8; 32],
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub data: Bytes,
}

/// Stores a thumbnail or preview for one of the account's assets, replacing an older one.
pub async fn store(
    db: &Db,
    root: &Path,
    user_id: &str,
    asset_id: &str,
    new: NewDerived,
) -> Result<Asset, DerivedError> {
    let exists: Option<(i64,)> =
        sqlx::query_as("SELECT 1 FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NULL")
            .bind(asset_id)
            .bind(user_id)
            .fetch_optional(db.read())
            .await?;
    if exists.is_none() {
        return Err(DerivedError::NotFound);
    }

    let data = new.data.clone();
    let digest: [u8; 32] = if data.len() > 256 * 1024 {
        tokio::task::spawn_blocking(move || Sha256::digest(&data).into())
            .await
            .map_err(|join| std::io::Error::other(join.to_string()))?
    } else {
        Sha256::digest(&data).into()
    };
    if digest != new.sha256 {
        return Err(DerivedError::ChecksumMismatch);
    }

    let hex = hex::encode(digest);
    let relative = paths::derived_path(&hex, new.media.extension);
    let full = root.join(&relative);
    let size = new.data.len() as i64;
    write_once(full, new.data).await?;

    let relative_text = relative.to_string_lossy().into_owned();
    let mut tx = db.begin().await?;
    let previous: Option<(String,)> = sqlx::query_as(
        "SELECT path FROM asset_files WHERE asset_id = ? AND role = ? AND storage = 'derived'",
    )
    .bind(asset_id)
    .bind(new.role.as_str())
    .fetch_optional(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, path, \
             width, height, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, 'derived', ?, ?, ?, ?) \
         ON CONFLICT (asset_id, role) DO UPDATE SET sha256 = excluded.sha256, \
             size = excluded.size, mime = excluded.mime, path = excluded.path, \
             width = excluded.width, height = excluded.height, created_at = excluded.created_at",
    )
    .bind(asset_id)
    .bind(new.role.as_str())
    .bind(user_id)
    .bind(digest.as_slice())
    .bind(size)
    .bind(new.media.mime)
    .bind(&relative_text)
    .bind(new.width.map(i64::from))
    .bind(new.height.map(i64::from))
    .bind(now_ms())
    .execute(&mut *tx)
    .await?;
    assets::touch(&mut tx, asset_id).await?;
    tx.commit().await?;

    if let Some((old,)) = previous
        && old != relative_text
    {
        remove_if_unused(db, root, &old).await?;
    }
    assets::get(db.read(), user_id, asset_id)
        .await?
        .ok_or(DerivedError::NotFound)
}

/// Writes a content-named file unless it is there already (same name, same content).
async fn write_once(full: PathBuf, data: Bytes) -> std::io::Result<()> {
    tokio::task::spawn_blocking(move || {
        if full.exists() {
            return Ok(());
        }
        if let Some(folder) = full.parent() {
            std::fs::create_dir_all(folder)?;
        }
        fsutil::write_atomic(&full, &data, 0o640).map_err(std::io::Error::other)
    })
    .await
    .map_err(|join| std::io::Error::other(join.to_string()))?
}

/// Deletes a derived file once no asset refers to it any more.
pub async fn remove_if_unused(db: &Db, root: &Path, relative: &str) -> Result<(), DerivedError> {
    if assets::derived_path_users(db, relative).await? == 0
        && let Some(full) = paths::resolve(root, relative)
    {
        let _ = tokio::fs::remove_file(full).await;
    }
    Ok(())
}
