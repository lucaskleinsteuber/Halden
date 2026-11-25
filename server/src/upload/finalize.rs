//! Finishing an upload: check, flush, move into the library, record.
//!
//! The order matters for "nothing gets lost": the file is flushed to disk before it is moved,
//! the move is flushed before the database records it, and the device hears "completed" only
//! after the database transaction committed. A crash at any point leaves either a partial file
//! the device can continue, or a complete, recorded file — never a recorded file that isn't
//! really there.

use std::{
    fs::{DirBuilder, File},
    os::unix::fs::DirBuilderExt,
    path::{Path, PathBuf},
    time::Duration,
};

use chrono::{DateTime, FixedOffset, Local, TimeZone};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{ClientMetadata, UploadError, UploadRole, UploadRow, Uploads};
use crate::{
    accounts::User,
    db::{Db, now_ms},
    fsutil,
    jobs::{self, JobKind},
    library::{
        assets::{self, Asset},
        journal,
        metadata::{self, FileMetadata},
        paths::{MediaKind, MediaType},
        settings::{self, PhotoFormat, VideoFormat},
    },
};

/// What finishing an upload ended in.
pub(super) enum Finished {
    Stored(Box<Asset>),
    /// The same content was stored meanwhile under this other asset id; this upload is dropped.
    Duplicate(String),
}

/// Reading metadata never holds up an upload for longer than this.
const METADATA_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) async fn finish(
    uploads: &Uploads,
    db: &Db,
    user: &User,
    row: &UploadRow,
    hasher: Sha256,
) -> Result<Finished, UploadError> {
    let part = uploads.part_path(&row.id);
    let digest: [u8; 32] = hasher.finalize().into();
    if digest.as_slice() != row.sha256.as_slice() {
        uploads.discard(db, row, "checksum_mismatch").await?;
        return Err(UploadError::ChecksumMismatch);
    }

    let synced = part.clone();
    tokio::task::spawn_blocking(move || File::open(&synced)?.sync_all())
        .await
        .map_err(|join| std::io::Error::other(join.to_string()))??;

    let media = MediaType::from_mime(&row.mime)
        .ok_or_else(|| UploadError::Failed(format!("unknown file type {}", row.mime)))?;
    let file_metadata = if row.role() == UploadRole::Original {
        let path = part.clone();
        match tokio::time::timeout(
            METADATA_TIMEOUT,
            tokio::task::spawn_blocking(move || metadata::read(&path)),
        )
        .await
        {
            Ok(Ok(found)) => found,
            _ => FileMetadata::default(),
        }
    } else {
        FileMetadata::default()
    };
    let client: ClientMetadata = row
        .metadata_json
        .as_deref()
        .and_then(|json| serde_json::from_str(json).ok())
        .unwrap_or_default();
    let now = now_ms();
    let capture = capture_time(&client, &file_metadata, now);

    let placing = uploads.placing.lock().await;
    // Another device of this account may have sent the same photo while this one arrived: it is
    // kept once, as if the duplicate had been found when the upload was announced.
    if row.role() == UploadRole::Original
        && let Some(existing) = assets::original_with_hash(db, &user.id, &digest).await?
        && existing != row.asset_id
    {
        drop(placing);
        uploads
            .discard(db, row, &format!("{}{existing}", super::DUPLICATE_OF))
            .await?;
        return Ok(Finished::Duplicate(existing));
    }
    let base = match row.role() {
        UploadRole::Original => uploads.template.render(&user.username, capture.local),
        // A Live Photo's video or a RAW sits next to its original, with the same name.
        _ => original_base(db, &row.asset_id).await?,
    };
    let relative = assets::free_library_name(db, uploads.library(), &base, media.extension).await?;
    let relative_text = relative.to_string_lossy().into_owned();
    let target = uploads.library().join(&relative);
    // Noted before the move: a crash between the move and the record is put right at the next
    // start (the file goes back to the partial file, and the upload can be finished).
    let entry = journal::will_place(db, &relative_text, Some(&row.id)).await?;
    crate::failpoint::hit("upload-before-place");
    if let Err(error) = place(&part, &target, &uploads.incoming).await {
        let _ = journal::forget(db, entry).await;
        return Err(error);
    }
    crate::failpoint::hit("upload-placed");

    let recorded = record(
        uploads,
        db,
        user,
        row,
        &digest,
        media,
        &relative_text,
        &client,
        &file_metadata,
        &capture,
        now,
        entry,
    )
    .await;
    if let Err(error) = recorded {
        // Put the file back, so the device can finish the upload again later.
        let _ = std::fs::rename(&target, &part);
        let _ = journal::forget(db, entry).await;
        return Err(error);
    }
    crate::failpoint::hit("upload-recorded");
    drop(placing);
    uploads.wake.notify_waiters();

    assets::get(db.read(), &user.id, &row.asset_id)
        .await?
        .map(|asset| Finished::Stored(Box::new(asset)))
        .ok_or(UploadError::NotFound)
}

/// When a photo was taken, and the local time there (used for its file name).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Capture {
    pub utc_ms: i64,
    pub offset_min: Option<i32>,
    pub source: &'static str,
    pub local: DateTime<FixedOffset>,
}

/// The phone knows best (it has the real time zone), then the file, then the upload time. When
/// no offset is known, the server's own time zone stands in for naming the file.
pub(super) fn capture_time(
    client: &ClientMetadata,
    file: &FileMetadata,
    upload_ms: i64,
) -> Capture {
    let local_for = |utc_ms: i64, offset: Option<i32>| -> DateTime<FixedOffset> {
        let utc = DateTime::from_timestamp_millis(utc_ms).unwrap_or_default();
        match offset.and_then(|minutes| FixedOffset::east_opt(minutes * 60)) {
            Some(offset) => utc.with_timezone(&offset),
            None => utc.with_timezone(&Local).fixed_offset(),
        }
    };
    if let Some(utc_ms) = client.taken_at {
        let offset = client.time_zone_offset_minutes.or(file.offset_minutes);
        return Capture {
            utc_ms,
            offset_min: offset,
            source: "client",
            local: local_for(utc_ms, offset),
        };
    }
    if let Some(naive) = file.taken_at {
        let offset = file.offset_minutes.or(client.time_zone_offset_minutes);
        let local = match offset.and_then(|minutes| FixedOffset::east_opt(minutes * 60)) {
            Some(fixed) => fixed.from_local_datetime(&naive).single(),
            None => Local
                .from_local_datetime(&naive)
                .earliest()
                .map(|time| time.fixed_offset()),
        };
        if let Some(local) = local {
            return Capture {
                utc_ms: local.timestamp_millis(),
                offset_min: offset,
                source: "exif",
                local,
            };
        }
    }
    let offset = client.time_zone_offset_minutes;
    Capture {
        utc_ms: upload_ms,
        offset_min: offset,
        source: "upload",
        local: local_for(upload_ms, offset),
    }
}

async fn original_base(db: &Db, asset_id: &str) -> Result<PathBuf, UploadError> {
    let (path,): (String,) =
        sqlx::query_as("SELECT path FROM asset_files WHERE asset_id = ? AND role = 'original'")
            .bind(asset_id)
            .fetch_optional(db.read())
            .await?
            .ok_or(UploadError::NotFound)?;
    Ok(Path::new(&path).with_extension(""))
}

/// Moves the flushed partial file to its place and flushes both folders, so the move survives
/// a power cut.
async fn place(part: &Path, target: &Path, incoming: &Path) -> Result<(), UploadError> {
    let (part, target, incoming) = (
        part.to_path_buf(),
        target.to_path_buf(),
        incoming.to_path_buf(),
    );
    tokio::task::spawn_blocking(move || -> std::io::Result<()> {
        let folder = target.parent().unwrap_or(Path::new("/")).to_path_buf();
        DirBuilder::new()
            .recursive(true)
            .mode(0o750)
            .create(&folder)?;
        std::fs::rename(&part, &target)?;
        fsutil::sync_dir(&folder).map_err(std::io::Error::other)?;
        fsutil::sync_dir(&incoming).map_err(std::io::Error::other)?;
        Ok(())
    })
    .await
    .map_err(|join| std::io::Error::other(join.to_string()))??;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn record(
    uploads: &Uploads,
    db: &Db,
    user: &User,
    row: &UploadRow,
    digest: &[u8; 32],
    media: MediaType,
    relative: &str,
    client: &ClientMetadata,
    file: &FileMetadata,
    capture: &Capture,
    now: i64,
    entry: i64,
) -> Result<(), UploadError> {
    let mut tx = db.begin().await?;
    journal::placed(&mut tx, entry).await?;
    let seq = assets::next_seq(&mut tx).await?;
    if row.role() == UploadRole::Original {
        let client_source = client.location.as_ref().and_then(|l| l.source.as_deref());
        // `device` and `estimated` are guesses (e.g. for screenshots without GPS), never original
        // camera readings: keep the original location empty (or from EXIF if the file had one) and
        // store the guess next to it as a correction.
        let guessed_source = client_source.filter(|s| matches!(*s, "device" | "estimated"));
        let original_location = if guessed_source.is_none() {
            client
                .location
                .as_ref()
                .map(|l| {
                    (
                        l.latitude,
                        l.longitude,
                        l.altitude,
                        l.horizontal_accuracy,
                        l.heading,
                        "client",
                    )
                })
                .or_else(|| {
                    Some((
                        file.latitude?,
                        file.longitude?,
                        file.altitude,
                        None,
                        None,
                        "exif",
                    ))
                })
        } else {
            file.latitude
                .zip(file.longitude)
                .map(|(lat, lon)| (lat, lon, file.altitude, None, None, "exif"))
        };
        let edit_location = match (
            original_location.is_none(),
            guessed_source,
            &client.location,
        ) {
            (true, Some(source), Some(l)) => Some((l.latitude, l.longitude, l.altitude, source)),
            _ => None,
        };
        let width = client.width.or(file.width);
        let height = client.height.or(file.height);
        let duration = client.duration_ms.or(file.duration_ms);
        sqlx::query(
            "INSERT INTO assets (id, user_id, kind, taken_at, tz_offset_min, taken_at_source, \
                 width, height, duration_ms, camera_make, camera_model, lens, latitude, longitude, \
                 altitude, location_accuracy_m, heading, location_source, edit_latitude, \
                 edit_longitude, edit_altitude, edit_location_source, exif_json, client_json, \
                 capture_mode, burst_id, created_at, updated_at, seq) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&row.asset_id)
        .bind(&user.id)
        .bind(media.kind.as_str())
        .bind(capture.utc_ms)
        .bind(capture.offset_min)
        .bind(capture.source)
        .bind(width.map(i64::from))
        .bind(height.map(i64::from))
        .bind(duration.map(|d| d as i64))
        .bind(&file.make)
        .bind(&file.model)
        .bind(&file.lens)
        .bind(original_location.map(|l| l.0))
        .bind(original_location.map(|l| l.1))
        .bind(original_location.and_then(|l| l.2))
        .bind(original_location.and_then(|l| l.3))
        .bind(original_location.and_then(|l| l.4))
        .bind(original_location.map(|l| l.5))
        .bind(edit_location.map(|l| l.0))
        .bind(edit_location.map(|l| l.1))
        .bind(edit_location.and_then(|l| l.2))
        .bind(edit_location.map(|l| l.3))
        .bind(exif_json(file))
        .bind(serde_json::to_string(client).ok())
        .bind(
            client
                .known_capture_mode()
                .filter(|_| media.kind.as_str() == "video"),
        )
        .bind(
            client
                .clean_burst_id()
                .filter(|_| media.kind.as_str() == "photo"),
        )
        .bind(now)
        .bind(now)
        .bind(seq)
        .execute(&mut *tx)
        .await?;
    } else {
        sqlx::query("UPDATE assets SET seq = ?, updated_at = ? WHERE id = ?")
            .bind(seq)
            .bind(now)
            .bind(&row.asset_id)
            .execute(&mut *tx)
            .await?;
    }
    sqlx::query(
        "INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, path, \
             width, height, created_at) \
         VALUES (?, ?, ?, ?, ?, ?, 'library', ?, ?, ?, ?)",
    )
    .bind(&row.asset_id)
    .bind(row.role().as_str())
    .bind(&user.id)
    .bind(digest.as_slice())
    .bind(row.size)
    .bind(media.mime)
    .bind(relative)
    .bind(file.width.map(i64::from))
    .bind(file.height.map(i64::from))
    .bind(now)
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE uploads SET state = 'completed', updated_at = ? WHERE id = ?")
        .bind(now)
        .bind(&row.id)
        .execute(&mut *tx)
        .await?;
    if row.role() == UploadRole::Original {
        // Made only if the phone hasn't sent its own thumbnails by then.
        jobs::enqueue(
            &mut tx,
            JobKind::Thumbnail,
            &row.asset_id,
            &user.id,
            uploads.thumbnail_delay_ms,
        )
        .await?;
        let wanted = settings::get(db, &user.id).await?;
        let copy_wanted = match media.kind {
            MediaKind::Photo => wanted.photo_format != PhotoFormat::Original,
            MediaKind::Video => wanted.video_format != VideoFormat::Original,
        };
        if copy_wanted {
            jobs::enqueue(&mut tx, JobKind::Convert, &row.asset_id, &user.id, 0).await?;
        }
        // A small copy to stream: made here only if the phone hasn't sent one by then.
        if media.kind == MediaKind::Video && uploads.stream_versions {
            jobs::enqueue(
                &mut tx,
                JobKind::Stream,
                &row.asset_id,
                &user.id,
                uploads.thumbnail_delay_ms,
            )
            .await?;
        }
    }
    if uploads.mirror {
        jobs::enqueue(&mut tx, JobKind::Mirror, &row.asset_id, &user.id, 0).await?;
    }
    tx.commit().await?;
    Ok(())
}

fn exif_json(file: &FileMetadata) -> Option<String> {
    let mut fields = file.fields.clone();
    if let Some(time) = file.taken_at {
        fields.insert("dateTimeOriginal".into(), json!(time.to_string()));
    }
    if let Some(offset) = file.offset_minutes {
        fields.insert("offsetMinutes".into(), json!(offset));
    }
    if let (Some(lat), Some(lon)) = (file.latitude, file.longitude) {
        fields.insert(
            "gps".into(),
            json!({ "latitude": lat, "longitude": lon, "altitude": file.altitude }),
        );
    }
    (!fields.is_empty()).then(|| Value::Object(fields).to_string())
}

#[cfg(test)]
mod tests {
    use chrono::NaiveDateTime;

    use super::*;

    #[test]
    fn the_phone_knows_the_time_best() {
        let file = FileMetadata {
            taken_at: NaiveDateTime::parse_from_str("2026-11-23 10:00:00", "%Y-%m-%d %H:%M:%S")
                .ok(),
            offset_minutes: Some(60),
            ..FileMetadata::default()
        };
        let client = ClientMetadata {
            taken_at: Some(1_795_443_720_000),
            time_zone_offset_minutes: Some(-300),
            ..ClientMetadata::default()
        };
        let capture = capture_time(&client, &file, 0);
        assert_eq!(capture.source, "client");
        assert_eq!(capture.utc_ms, 1_795_443_720_000);
        assert_eq!(capture.local.offset().local_minus_utc(), -300 * 60);

        let capture = capture_time(&ClientMetadata::default(), &file, 0);
        assert_eq!(capture.source, "exif");
        assert_eq!(
            capture.local.to_rfc3339(),
            "2026-11-23T10:00:00+01:00",
            "the file's local time names the file"
        );
        assert_eq!(capture.utc_ms, capture.local.timestamp_millis());

        let capture = capture_time(&ClientMetadata::default(), &FileMetadata::default(), 42);
        assert_eq!((capture.source, capture.utc_ms), ("upload", 42));
    }
}
