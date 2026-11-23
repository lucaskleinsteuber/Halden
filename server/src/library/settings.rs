//! Settings of an account that the server acts on: the preferred formats for an extra copy of
//! every photo and video.

use serde::{Deserialize, Serialize};

use crate::{
    db::{Db, now_ms},
    jobs::{self, JobKind},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PhotoFormat {
    Original,
    Jpeg,
    Heic,
    Png,
    Tiff,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VideoFormat {
    Original,
    Mp4,
    Mov,
    Mkv,
}

impl PhotoFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Original => "original",
            Self::Jpeg => "jpeg",
            Self::Heic => "heic",
            Self::Png => "png",
            Self::Tiff => "tiff",
        }
    }

    fn parse(text: &str) -> Self {
        match text {
            "jpeg" => Self::Jpeg,
            "heic" => Self::Heic,
            "png" => Self::Png,
            "tiff" => Self::Tiff,
            _ => Self::Original,
        }
    }

    /// The MIME type of the copy, `None` for no copy.
    pub fn mime(self) -> Option<&'static str> {
        match self {
            Self::Original => None,
            Self::Jpeg => Some("image/jpeg"),
            Self::Heic => Some("image/heic"),
            Self::Png => Some("image/png"),
            Self::Tiff => Some("image/tiff"),
        }
    }
}

impl VideoFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Original => "original",
            Self::Mp4 => "mp4",
            Self::Mov => "mov",
            Self::Mkv => "mkv",
        }
    }

    fn parse(text: &str) -> Self {
        match text {
            "mp4" => Self::Mp4,
            "mov" => Self::Mov,
            "mkv" => Self::Mkv,
            _ => Self::Original,
        }
    }

    pub fn mime(self) -> Option<&'static str> {
        match self {
            Self::Original => None,
            Self::Mp4 => Some("video/mp4"),
            Self::Mov => Some("video/quicktime"),
            Self::Mkv => Some("video/x-matroska"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub photo_format: PhotoFormat,
    pub video_format: VideoFormat,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            photo_format: PhotoFormat::Original,
            video_format: VideoFormat::Original,
        }
    }
}

pub async fn get(db: &Db, user_id: &str) -> Result<Settings, sqlx::Error> {
    let row: Option<(String, String)> =
        sqlx::query_as("SELECT photo_format, video_format FROM user_settings WHERE user_id = ?")
            .bind(user_id)
            .fetch_optional(db.read())
            .await?;
    Ok(
        row.map_or_else(Settings::default, |(photo, video)| Settings {
            photo_format: PhotoFormat::parse(&photo),
            video_format: VideoFormat::parse(&video),
        }),
    )
}

/// Saves new settings. When a format changed, every existing photo or video of that kind gets a
/// conversion job (they run in the background, one after the other, at the lowest priority).
pub async fn set(db: &Db, user_id: &str, new: Settings) -> Result<u64, sqlx::Error> {
    let old = get(db, user_id).await?;
    let mut tx = db.begin().await?;
    sqlx::query(
        "INSERT INTO user_settings (user_id, photo_format, video_format, updated_at) \
         VALUES (?1, ?2, ?3, ?4) ON CONFLICT (user_id) DO UPDATE SET \
             photo_format = excluded.photo_format, video_format = excluded.video_format, \
             updated_at = excluded.updated_at",
    )
    .bind(user_id)
    .bind(new.photo_format.as_str())
    .bind(new.video_format.as_str())
    .bind(now_ms())
    .execute(&mut *tx)
    .await?;
    let mut queued = 0;
    for (kind, changed) in [
        ("photo", old.photo_format != new.photo_format),
        ("video", old.video_format != new.video_format),
    ] {
        if changed {
            queued += jobs::enqueue_for_kind(&mut tx, JobKind::Convert, user_id, kind).await?;
        }
    }
    tx.commit().await?;
    Ok(queued)
}
