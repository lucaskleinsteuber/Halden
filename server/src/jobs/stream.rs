//! A smaller copy of a big video, to play on the go (cellular, Tailscale) and in shared links:
//! H.264 in MP4 (plays everywhere, also in browsers), the shorter side `[jobs] stream_height`
//! (720) at `[jobs] stream_kbps` (3000), ready to play while it loads (faststart). The phone
//! usually sends its own (the upload role `stream`); the server makes it only if the phone hasn't
//! after `[jobs] thumbnail_delay_minutes`, and not for videos that are small already.

use std::{ffi::OsString, path::Path};

use super::{
    Job, JobContext,
    convert::{hash_and_flush, place},
    tools,
};
use crate::{
    db::now_ms,
    library::{
        assets, journal,
        paths::{MediaKind, MediaType},
    },
};

pub async fn run(ctx: &JobContext, job: &Job) -> Result<(), String> {
    let err = |e: sqlx::Error| e.to_string();
    let Some(asset) = assets::get(ctx.db.read(), &job.user_id, &job.asset_id)
        .await
        .map_err(err)?
    else {
        return Ok(());
    };
    if asset.deleted_at.is_some() || asset.files.iter().any(|file| file.role == "stream") {
        return Ok(());
    }
    let original = assets::stored_file(&ctx.db, &job.user_id, &job.asset_id, "original")
        .await
        .map_err(err)?
        .ok_or("the asset has no original")?;
    if MediaType::from_mime(&original.mime).map(|m| m.kind) != Some(MediaKind::Video) {
        return Ok(());
    }
    if small_already(
        asset.width,
        asset.height,
        original.size,
        asset.duration_ms,
        ctx.stream_height,
        ctx.stream_kbps,
    ) {
        return Ok(());
    }
    let ffmpeg = ctx.tools.ffmpeg.as_ref().ok_or("ffmpeg is not installed")?;
    let source = original
        .resolve(&ctx.library, &ctx.derived)
        .ok_or("the original's path is invalid")?;
    let temporary = ctx
        .incoming
        .join(format!("{}.stream.mp4", uuid::Uuid::new_v4()));
    let made = ctx
        .tools
        .run(
            "ffmpeg",
            ffmpeg,
            &arguments(&source, &temporary, ctx.stream_height, ctx.stream_kbps),
            ctx.external_timeout,
        )
        .await;
    if let Err(error) = made {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(error.to_string());
    }
    let checked = temporary.clone();
    let (sha256, size) = ctx
        .background
        .run(move || hash_and_flush(&checked))
        .await
        .ok_or("hashing the small copy crashed")?
        .map_err(|e| e.to_string())?;

    let placing = ctx.placing.lock().await;
    let base = Path::new(&original.path).with_extension("");
    let base = base.with_file_name(format!(
        "{}_small",
        base.file_name().and_then(|n| n.to_str()).unwrap_or("video")
    ));
    let relative = assets::free_library_name(&ctx.db, &ctx.library, &base, "mp4")
        .await
        .map_err(err)?;
    let destination = ctx.library.join(&relative);
    let relative_text = relative.to_string_lossy().into_owned();
    let entry = journal::will_place(&ctx.db, &relative_text, None)
        .await
        .map_err(err)?;
    if let Err(error) = place(&temporary, &destination).await {
        let _ = tokio::fs::remove_file(&temporary).await;
        let _ = journal::forget(&ctx.db, entry).await;
        return Err(error.to_string());
    }
    let recorded = record(ctx, job, &sha256, size, &relative_text, entry).await;
    drop(placing);
    if let Err(error) = recorded {
        let _ = tokio::fs::remove_file(&destination).await;
        let _ = journal::forget(&ctx.db, entry).await;
        return Err(error.to_string());
    }
    Ok(())
}

/// A video that is no bigger than the small copy would be needs none.
pub fn small_already(
    width: Option<i64>,
    height: Option<i64>,
    size: i64,
    duration_ms: Option<i64>,
    stream_height: u32,
    stream_kbps: u32,
) -> bool {
    let shorter = match (width, height) {
        (Some(w), Some(h)) => w.min(h),
        _ => return false,
    };
    let Some(duration) = duration_ms.filter(|d| *d > 0) else {
        return false;
    };
    let kbps = size as f64 * 8.0 / duration as f64;
    shorter <= i64::from(stream_height) && kbps <= f64::from(stream_kbps) * 1.5
}

/// ffmpeg: H.264 and AAC in MP4, the shorter side `height` (never larger than it was), upright,
/// the place and time kept.
fn arguments(source: &Path, output: &Path, height: u32, kbps: u32) -> Vec<OsString> {
    let scale =
        format!("scale='if(gt(iw,ih),-2,min({height},iw))':'if(gt(iw,ih),min({height},ih),-2)'");
    let rate = format!("{kbps}k");
    let buffer = format!("{}k", kbps * 2);
    let mut args = tools::args(&[
        &"-nostdin",
        &"-loglevel",
        &"error",
        &"-i",
        &source,
        &"-map",
        &"0:v:0",
        &"-map",
        &"0:a:0?",
        &"-vf",
        &scale,
        &"-c:v",
        &"libx264",
        &"-preset",
        &"veryfast",
        &"-profile:v",
        &"high",
        &"-pix_fmt",
        &"yuv420p",
        &"-b:v",
        &rate,
        &"-maxrate",
        &rate,
        &"-bufsize",
        &buffer,
        &"-c:a",
        &"aac",
        &"-b:a",
        &"128k",
        &"-map_metadata",
        &"0",
        &"-movflags",
        &"+faststart",
        &"-f",
        &"mp4",
        &"-y",
    ]);
    args.push(output.as_os_str().to_os_string());
    args
}

async fn record(
    ctx: &JobContext,
    job: &Job,
    sha256: &[u8; 32],
    size: u64,
    relative: &str,
    entry: i64,
) -> Result<(), sqlx::Error> {
    let mut tx = ctx.db.begin().await?;
    journal::placed(&mut tx, entry).await?;
    let inserted = sqlx::query(
        "INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, \
             path, created_at) \
         VALUES (?, 'stream', ?, ?, ?, 'video/mp4', 'library', ?, ?) \
         ON CONFLICT (asset_id, role) DO NOTHING",
    )
    .bind(&job.asset_id)
    .bind(&job.user_id)
    .bind(sha256.as_slice())
    .bind(size as i64)
    .bind(relative)
    .bind(now_ms())
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if inserted == 0 {
        // The phone's copy came in meanwhile: this one goes.
        journal::will_remove(&mut tx, journal::Storage::Library, relative).await?;
    } else {
        assets::touch(&mut tx, &job.asset_id).await?;
        if ctx.mirror.is_some() {
            super::enqueue(
                &mut tx,
                super::JobKind::Mirror,
                &job.asset_id,
                &job.user_id,
                0,
            )
            .await?;
        }
    }
    tx.commit().await?;
    if inserted == 0 {
        let _ = journal::remove_pending(&ctx.db, ctx.roots()).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 4K at 50 Mbit/s needs a small copy; 720p at 2 Mbit/s doesn't; without facts, it gets one.
    #[test]
    fn only_big_videos_get_a_small_copy() {
        let minute = Some(60_000);
        let mb = |m: i64| m * 1_000_000;
        assert!(!small_already(
            Some(3840),
            Some(2160),
            mb(375),
            minute,
            720,
            3000
        ));
        assert!(small_already(
            Some(1280),
            Some(720),
            mb(15),
            minute,
            720,
            3000
        ));
        assert!(small_already(
            Some(720),
            Some(1280),
            mb(15),
            minute,
            720,
            3000
        ));
        assert!(!small_already(
            Some(1280),
            Some(720),
            mb(60),
            minute,
            720,
            3000
        ));
        assert!(!small_already(None, None, mb(1), minute, 720, 3000));
        assert!(!small_already(Some(640), Some(360), mb(1), None, 720, 3000));
    }
}
