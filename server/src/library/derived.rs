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

/// Stores a thumbnail or preview the phone sent for one of the account's assets, replacing an
/// older one. The hash must match.
pub async fn store(
    db: &Db,
    root: &Path,
    user_id: &str,
    asset_id: &str,
    new: NewDerived,
) -> Result<Asset, DerivedError> {
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
    put(
        db,
        root,
        Derived {
            user_id,
            asset_id,
            role: new.role,
            media: new.media,
            sha256: digest,
            width: new.width,
            height: new.height,
            data: new.data,
        },
        Replace::Always,
    )
    .await?;
    assets::get(db.read(), user_id, asset_id)
        .await?
        .ok_or(DerivedError::NotFound)
}

/// A derived file ready to be stored, its hash already known.
pub struct Derived<'a> {
    pub user_id: &'a str,
    pub asset_id: &'a str,
    pub role: DerivedRole,
    pub media: MediaType,
    pub sha256: [u8; 32],
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub data: Bytes,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Replace {
    /// The phone's own file replaces whatever is there.
    Always,
    /// A file the server made is only kept if the phone hasn't sent one meanwhile.
    IfMissing,
}

/// Writes a derived file and records it. Returns false if it was not needed (`IfMissing` and
/// there is one already) or the asset is gone.
pub async fn put(
    db: &Db,
    root: &Path,
    file: Derived<'_>,
    replace: Replace,
) -> Result<bool, DerivedError> {
    let exists: Option<(i64,)> =
        sqlx::query_as("SELECT 1 FROM assets WHERE id = ? AND user_id = ? AND deleted_at IS NULL")
            .bind(file.asset_id)
            .bind(file.user_id)
            .fetch_optional(db.read())
            .await?;
    if exists.is_none() {
        return Err(DerivedError::NotFound);
    }

    let hex = hex::encode(file.sha256);
    let relative = paths::derived_path(&hex, file.media.extension);
    let size = file.data.len() as i64;
    write_once(root.join(&relative), file.data).await?;

    let relative_text = relative.to_string_lossy().into_owned();
    let mut tx = db.begin().await?;
    let previous: Option<(String,)> = sqlx::query_as(
        "SELECT path FROM asset_files WHERE asset_id = ? AND role = ? AND storage = 'derived'",
    )
    .bind(file.asset_id)
    .bind(file.role.as_str())
    .fetch_optional(&mut *tx)
    .await?;
    if previous.is_some() && replace == Replace::IfMissing {
        tx.rollback().await?;
        remove_if_unused(db, root, &relative_text).await?;
        return Ok(false);
    }
    sqlx::query(
        "INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, path, \
             width, height, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, 'derived', ?, ?, ?, ?) \
         ON CONFLICT (asset_id, role) DO UPDATE SET sha256 = excluded.sha256, \
             size = excluded.size, mime = excluded.mime, path = excluded.path, \
             width = excluded.width, height = excluded.height, created_at = excluded.created_at",
    )
    .bind(file.asset_id)
    .bind(file.role.as_str())
    .bind(file.user_id)
    .bind(file.sha256.as_slice())
    .bind(size)
    .bind(file.media.mime)
    .bind(&relative_text)
    .bind(file.width.map(i64::from))
    .bind(file.height.map(i64::from))
    .bind(now_ms())
    .execute(&mut *tx)
    .await?;
    assets::touch(&mut tx, file.asset_id).await?;
    tx.commit().await?;

    if let Some((old,)) = previous
        && old != relative_text
    {
        remove_if_unused(db, root, &old).await?;
    }
    Ok(true)
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
