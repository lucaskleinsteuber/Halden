//! An extra copy of every photo or video in the account's preferred format, next to the
//! original (same name, other extension). The original is never touched.
//!
//! Videos only change their container when possible (`-c copy`): no quality is lost and it takes
//! seconds instead of minutes. Photos: HEIC to JPEG/PNG with libheif, anything to HEIC with
//! `heif-enc`, JPEG/PNG/TIFF/WebP/GIF among each other in-process (EXIF and colour profile are
//! carried over where the target format can hold them).

use std::{
    ffi::OsString,
    io::Cursor,
    path::{Path, PathBuf},
};

use image::{DynamicImage, ImageDecoder, ImageEncoder};
use sha2::{Digest, Sha256};

use super::{Job, JobContext, tools};
use crate::{
    db::now_ms,
    fsutil,
    library::{
        assets, journal,
        paths::{MediaKind, MediaType},
        settings,
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
    if asset.deleted_at.is_some() {
        return Ok(());
    }
    let original = assets::stored_file(&ctx.db, &job.user_id, &job.asset_id, "original")
        .await
        .map_err(err)?
        .ok_or("the asset has no original")?;
    let source_media = MediaType::from_mime(&original.mime).ok_or("unknown file type")?;
    let wanted = settings::get(&ctx.db, &job.user_id).await.map_err(err)?;
    let target = match source_media.kind {
        MediaKind::Photo => wanted.photo_format.mime(),
        MediaKind::Video => wanted.video_format.mime(),
    }
    .and_then(MediaType::from_mime);
    let existing = assets::stored_file(&ctx.db, &job.user_id, &job.asset_id, "converted")
        .await
        .map_err(err)?;

    let target = match target {
        Some(target) if !same_format(source_media, target) => target,
        // No copy wanted (any more), or the original already is in that format.
        _ => {
            if let Some(existing) = existing {
                remove_converted(ctx, &job.asset_id, &existing.path).await?;
            }
            return Ok(());
        }
    };
    if existing.as_ref().is_some_and(|e| e.mime == target.mime) {
        return Ok(());
    }
    if !convertible(source_media) {
        tracing::info!(asset = %job.asset_id, from = source_media.mime, "can't convert this format");
        return Ok(());
    }

    let source = original
        .resolve(&ctx.library, &ctx.derived)
        .ok_or("the original's path is invalid")?;
    let temporary = ctx.incoming.join(format!(
        "{}.convert.{}",
        uuid::Uuid::new_v4(),
        target.extension
    ));
    let made = produce(
        ctx,
        &source,
        source_media,
        target,
        &temporary,
        asset.duration_ms,
    )
    .await;
    if let Err(error) = made {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(error);
    }
    let checked = temporary.clone();
    let (sha256, size) = ctx
        .background
        .run(move || hash_and_flush(&checked))
        .await
        .ok_or("hashing the conversion crashed")?
        .map_err(|e| e.to_string())?;

    let placing = ctx.placing.lock().await;
    let base = Path::new(&original.path).with_extension("");
    let relative = assets::free_library_name(&ctx.db, &ctx.library, &base, target.extension)
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
    crate::failpoint::hit("convert-placed");
    let recorded = record(ctx, job, target, &sha256, size, &relative_text, entry).await;
    drop(placing);
    match recorded {
        Ok(()) => {
            // The conversion it replaced (another format) goes.
            journal::remove_pending(&ctx.db, ctx.roots())
                .await
                .map_err(err)?;
            Ok(())
        }
        Err(error) => {
            let _ = tokio::fs::remove_file(&destination).await;
            let _ = journal::forget(&ctx.db, entry).await;
            Err(error.to_string())
        }
    }
}

/// HEIC and HEIF are the same family; JPEG is JPEG.
fn same_format(source: MediaType, target: MediaType) -> bool {
    source.extension == target.extension
        || matches!(
            (source.mime, target.mime),
            ("image/heif", "image/heic") | ("image/heic", "image/heif")
        )
}

/// RAW files and odd formats have no converter yet.
fn convertible(source: MediaType) -> bool {
    source.kind == MediaKind::Video
        || matches!(
            source.mime,
            "image/heic"
                | "image/heif"
                | "image/avif"
                | "image/jpeg"
                | "image/png"
                | "image/tiff"
                | "image/webp"
                | "image/gif"
        )
}

async fn produce(
    ctx: &JobContext,
    source: &Path,
    from: MediaType,
    to: MediaType,
    output: &Path,
    _duration_ms: Option<i64>,
) -> Result<(), String> {
    if from.kind == MediaKind::Video {
        return remux(ctx, source, to, output).await;
    }
    let heif_source = matches!(from.mime, "image/heic" | "image/heif" | "image/avif");
    match (heif_source, to.mime) {
        // HEIC → JPEG / PNG straight through libheif.
        (true, "image/jpeg" | "image/png") => heif_decode(ctx, source, output).await,
        // HEIC → TIFF: libheif to PNG first, then in-process.
        (true, _) => {
            let png = output.with_extension("png");
            heif_decode(ctx, source, &png).await?;
            let result = transcode(ctx, png.clone(), output.to_path_buf(), to).await;
            let _ = tokio::fs::remove_file(&png).await;
            result
        }
        // → HEIC: heif-enc reads JPEG and PNG; other formats become PNG first.
        (false, "image/heic") => {
            if matches!(from.mime, "image/jpeg" | "image/png") {
                heif_encode(ctx, source, output).await
            } else {
                let png = output.with_extension("png");
                let png_media = MediaType::from_mime("image/png").ok_or("png")?;
                transcode(ctx, source.to_path_buf(), png.clone(), png_media).await?;
                let result = heif_encode(ctx, &png, output).await;
                let _ = tokio::fs::remove_file(&png).await;
                result
            }
        }
        (false, _) => transcode(ctx, source.to_path_buf(), output.to_path_buf(), to).await,
    }
}

async fn heif_decode(ctx: &JobContext, source: &Path, output: &Path) -> Result<(), String> {
    let tool = ctx
        .tools
        .heif_dec
        .as_ref()
        .ok_or("libheif (heif-dec) is not installed")?;
    ctx.tools
        .run(
            "heif-dec",
            tool,
            &tools::args(&[&"-q", &"92", &source, &output]),
            ctx.external_timeout,
        )
        .await
        .map_err(|e| e.to_string())
}

async fn heif_encode(ctx: &JobContext, source: &Path, output: &Path) -> Result<(), String> {
    let tool = ctx
        .tools
        .heif_enc
        .as_ref()
        .ok_or("libheif (heif-enc) is not installed")?;
    ctx.tools
        .run(
            "heif-enc",
            tool,
            &tools::args(&[&"-q", &"90", &source, &"-o", &output]),
            ctx.external_timeout,
        )
        .await
        .map_err(|e| e.to_string())
}

/// Changes only the container of a video. If the sound doesn't fit the new container, only the
/// sound is converted (to AAC); the picture is always copied as it is.
async fn remux(
    ctx: &JobContext,
    source: &Path,
    to: MediaType,
    output: &Path,
) -> Result<(), String> {
    let ffmpeg = ctx.tools.ffmpeg.as_ref().ok_or("ffmpeg is not installed")?;
    let (muxer, faststart) = match to.extension {
        "mp4" => ("mp4", true),
        "mov" => ("mov", true),
        _ => ("matroska", false),
    };
    let hevc = video_codec(ctx, source).await.as_deref() == Some("hevc");
    let attempt = |audio: &[&str]| {
        let mut args: Vec<OsString> = tools::args(&[
            &"-nostdin",
            &"-loglevel",
            &"error",
            &"-i",
            &source,
            &"-map",
            &"0:v",
            &"-map",
            &"0:a?",
            &"-c:v",
            &"copy",
            &"-map_metadata",
            &"0",
        ]);
        args.extend(audio.iter().map(OsString::from));
        if faststart {
            args.extend(["-movflags", "+faststart"].map(OsString::from));
        }
        if hevc && muxer != "matroska" {
            // Apple players only play HEVC in MP4/MOV with this tag.
            args.extend(["-tag:v", "hvc1"].map(OsString::from));
        }
        args.extend(["-f", muxer, "-y"].map(OsString::from));
        args.push(output.as_os_str().to_os_string());
        args
    };
    let copied = ctx
        .tools
        .run(
            "ffmpeg",
            ffmpeg,
            &attempt(&["-c:a", "copy"]),
            ctx.external_timeout,
        )
        .await;
    if copied.is_ok() {
        return Ok(());
    }
    ctx.tools
        .run(
            "ffmpeg",
            ffmpeg,
            &attempt(&["-c:a", "aac", "-b:a", "192k"]),
            ctx.external_timeout,
        )
        .await
        .map_err(|e| e.to_string())
}

async fn video_codec(ctx: &JobContext, source: &Path) -> Option<String> {
    let ffprobe = ctx.tools.ffprobe.as_ref()?;
    let output = ctx
        .tools
        .output(
            ffprobe,
            &tools::args(&[
                &"-v",
                &"error",
                &"-select_streams",
                &"v:0",
                &"-show_entries",
                &"stream=codec_name",
                &"-of",
                &"csv=p=0",
                &source,
            ]),
            std::time::Duration::from_secs(30),
        )
        .await
        .ok()?;
    Some(output.trim().to_string()).filter(|codec| !codec.is_empty())
}

/// JPEG / PNG / TIFF / WebP / GIF into JPEG, PNG or TIFF, in-process on a low-priority thread.
/// The pixels keep their stored orientation and the EXIF (with its orientation tag) and colour
/// profile are copied, so viewers show it the same way. TIFF can't take EXIF here, so for TIFF
/// the rotation is applied to the pixels instead.
async fn transcode(
    ctx: &JobContext,
    source: PathBuf,
    output: PathBuf,
    to: MediaType,
) -> Result<(), String> {
    let to_mime = to.mime;
    ctx.background
        .run(move || -> Result<(), String> {
            let mut decoder = super::thumbnail::decoder_for(&source)?;
            let exif = decoder.exif_metadata().ok().flatten();
            let icc = decoder.icc_profile().ok().flatten();
            let orientation = decoder.orientation().map_err(|e| e.to_string())?;
            let mut picture = DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
            let mut out = Cursor::new(Vec::new());
            match to_mime {
                "image/jpeg" => {
                    let rgb = DynamicImage::ImageRgb8(picture.to_rgb8());
                    let mut encoder =
                        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 92);
                    if let Some(exif) = exif {
                        let _ = encoder.set_exif_metadata(exif);
                    }
                    if let Some(icc) = icc {
                        let _ = encoder.set_icc_profile(icc);
                    }
                    rgb.write_with_encoder(encoder).map_err(|e| e.to_string())?;
                }
                "image/png" => {
                    let mut encoder = image::codecs::png::PngEncoder::new(&mut out);
                    if let Some(exif) = exif {
                        let _ = encoder.set_exif_metadata(exif);
                    }
                    if let Some(icc) = icc {
                        let _ = encoder.set_icc_profile(icc);
                    }
                    picture
                        .write_with_encoder(encoder)
                        .map_err(|e| e.to_string())?;
                }
                "image/tiff" => {
                    picture.apply_orientation(orientation);
                    let mut encoder = image::codecs::tiff::TiffEncoder::new(&mut out);
                    if let Some(icc) = icc {
                        let _ = encoder.set_icc_profile(icc);
                    }
                    picture
                        .write_with_encoder(encoder)
                        .map_err(|e| e.to_string())?;
                }
                other => return Err(format!("can't write {other}")),
            }
            std::fs::write(&output, out.into_inner()).map_err(|e| e.to_string())
        })
        .await
        .ok_or("converting the photo crashed")?
}

fn hash_and_flush(path: &Path) -> std::io::Result<([u8; 32], u64)> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    let mut size = 0u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        size += read as u64;
    }
    file.sync_all()?;
    Ok((hasher.finalize().into(), size))
}

async fn place(temporary: &Path, destination: &Path) -> std::io::Result<()> {
    let (temporary, destination) = (temporary.to_path_buf(), destination.to_path_buf());
    tokio::task::spawn_blocking(move || {
        let folder = destination.parent().unwrap_or(Path::new("/")).to_path_buf();
        std::fs::create_dir_all(&folder)?;
        std::fs::rename(&temporary, &destination)?;
        fsutil::sync_dir(&folder).map_err(std::io::Error::other)
    })
    .await
    .map_err(|join| std::io::Error::other(join.to_string()))?
}

/// Records the conversion; a conversion it replaces is noted for removal.
async fn record(
    ctx: &JobContext,
    job: &Job,
    target: MediaType,
    sha256: &[u8; 32],
    size: u64,
    relative: &str,
    entry: i64,
) -> Result<(), sqlx::Error> {
    let mut tx = ctx.db.begin().await?;
    journal::placed(&mut tx, entry).await?;
    let previous: Option<(String,)> =
        sqlx::query_as("SELECT path FROM asset_files WHERE asset_id = ? AND role = 'converted'")
            .bind(&job.asset_id)
            .fetch_optional(&mut *tx)
            .await?;
    if let Some((previous,)) = &previous
        && previous != relative
    {
        journal::will_remove(&mut tx, journal::Storage::Library, previous).await?;
    }
    sqlx::query(
        "INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, path, \
             created_at) \
         VALUES (?, 'converted', ?, ?, ?, ?, 'library', ?, ?) \
         ON CONFLICT (asset_id, role) DO UPDATE SET sha256 = excluded.sha256, \
             size = excluded.size, mime = excluded.mime, path = excluded.path, \
             created_at = excluded.created_at",
    )
    .bind(&job.asset_id)
    .bind(&job.user_id)
    .bind(sha256.as_slice())
    .bind(size as i64)
    .bind(target.mime)
    .bind(relative)
    .bind(now_ms())
    .execute(&mut *tx)
    .await?;
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
    tx.commit().await?;
    Ok(())
}

/// The account no longer wants a copy (or the original is in that format): remove it.
async fn remove_converted(ctx: &JobContext, asset_id: &str, path: &str) -> Result<(), String> {
    let mut tx = ctx.db.begin().await.map_err(|e| e.to_string())?;
    journal::will_remove(&mut tx, journal::Storage::Library, path)
        .await
        .map_err(|e| e.to_string())?;
    sqlx::query("DELETE FROM asset_files WHERE asset_id = ? AND role = 'converted'")
        .bind(asset_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
    assets::touch(&mut tx, asset_id)
        .await
        .map_err(|e| e.to_string())?;
    tx.commit().await.map_err(|e| e.to_string())?;
    journal::remove_pending(&ctx.db, ctx.roots())
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}
