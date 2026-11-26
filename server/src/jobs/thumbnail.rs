//! Thumbnails and previews the server makes itself, for photos whose phone didn't send them
//! (imports, older apps, a phone that went offline right after the original).
//!
//! JPEG, PNG, TIFF, WebP and GIF are decoded in-process; HEIC/HEIF/AVIF go through libheif's
//! `heif-dec`; videos through `ffmpeg`. Resizing uses SIMD (`fast_image_resize`). The heavy work
//! runs on low-priority threads.

use std::{io::Cursor, path::Path, time::Duration};

use bytes::Bytes;
use fast_image_resize::{FilterType, ResizeAlg, ResizeOptions, Resizer};
use image::{DynamicImage, ImageDecoder, ImageReader, codecs::jpeg::JpegEncoder};
use sha2::{Digest, Sha256};

use super::{Job, JobContext, tools};
use crate::library::{
    assets,
    derived::{self, Derived, DerivedRole, Replace},
    paths::{MediaKind, MediaType},
};

/// Long edge in pixels and JPEG quality.
pub const THUMBNAIL: (u32, u8) = (512, 80);
pub const PREVIEW: (u32, u8) = (2048, 85);

pub async fn run(ctx: &JobContext, job: &Job) -> Result<(), String> {
    let Some(asset) = assets::get(ctx.db.read(), &job.user_id, &job.asset_id)
        .await
        .map_err(|e| e.to_string())?
    else {
        return Ok(());
    };
    if asset.deleted_at.is_some() {
        return Ok(());
    }
    let has = |role: &str| asset.files.iter().any(|f| f.role == role);
    let missing: Vec<DerivedRole> = [DerivedRole::Thumbnail, DerivedRole::Preview]
        .into_iter()
        .filter(|role| !has(role.as_str()))
        .collect();
    if missing.is_empty() {
        return Ok(());
    }
    let original = assets::stored_file(&ctx.db, &job.user_id, &job.asset_id, "original")
        .await
        .map_err(|e| e.to_string())?
        .ok_or("the asset has no original")?;
    let path = original
        .resolve(&ctx.library, &ctx.derived)
        .ok_or("the original's path is invalid")?;
    let media = MediaType::from_mime(&original.mime).ok_or("unknown file type")?;

    let image = std::sync::Arc::new(decode(ctx, &path, media, asset.duration_ms).await?);
    for role in missing {
        let (edge, quality) = match role {
            DerivedRole::Thumbnail => THUMBNAIL,
            DerivedRole::Preview => PREVIEW,
            DerivedRole::LiveEffect => continue,
        };
        let source = image.clone();
        let (data, width, height) = ctx
            .background
            .run(move || shrink(&source, edge, quality))
            .await
            .ok_or("making the thumbnail crashed")??;
        let sha256: [u8; 32] = Sha256::digest(&data).into();
        let stored = derived::put(
            &ctx.db,
            &ctx.derived,
            Derived {
                user_id: &job.user_id,
                asset_id: &job.asset_id,
                role,
                media: MediaType::from_mime("image/jpeg").ok_or("jpeg")?,
                sha256,
                width: Some(width),
                height: Some(height),
                data: Bytes::from(data),
            },
            Replace::IfMissing,
        )
        .await;
        match stored {
            Ok(_) | Err(derived::DerivedError::NotFound) => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(())
}

/// The original as an image, upright.
async fn decode(
    ctx: &JobContext,
    path: &Path,
    media: MediaType,
    duration_ms: Option<i64>,
) -> Result<DynamicImage, String> {
    let timeout = ctx.external_timeout;
    if media.kind == MediaKind::Video {
        let ffmpeg = ctx.tools.ffmpeg.as_ref().ok_or("ffmpeg is not installed")?;
        let frame = ctx.scratch().join(format!("{}.png", uuid::Uuid::new_v4()));
        // One second in, or the start of very short clips.
        let at = if duration_ms.is_some_and(|d| d < 2000) {
            "0"
        } else {
            "1"
        };
        let result = ctx
            .tools
            .run(
                "ffmpeg",
                ffmpeg,
                &tools::args(&[
                    &"-nostdin",
                    &"-loglevel",
                    &"error",
                    &"-ss",
                    &at,
                    &"-i",
                    &path,
                    &"-frames:v",
                    &"1",
                    &"-vf",
                    &"scale='min(2048,iw)':-2",
                    &"-y",
                    &frame,
                ]),
                timeout,
            )
            .await;
        let image = match result {
            Ok(()) => read_image(ctx, frame.clone()).await,
            Err(error) => Err(error.to_string()),
        };
        let _ = tokio::fs::remove_file(&frame).await;
        return image;
    }
    match media.mime {
        "image/jpeg" | "image/png" | "image/tiff" | "image/webp" | "image/gif" => {
            read_image(ctx, path.to_path_buf()).await
        }
        "image/x-adobe-dng" | "image/dng" => {
            if let Ok(image) = read_image(ctx, path.to_path_buf()).await {
                return Ok(image);
            }
            let ffmpeg = ctx
                .tools
                .ffmpeg
                .as_ref()
                .ok_or("could not decode DNG and ffmpeg is not installed")?;
            let converted = ctx.scratch().join(format!("{}.png", uuid::Uuid::new_v4()));
            let result = ctx
                .tools
                .run(
                    "ffmpeg",
                    ffmpeg,
                    &tools::args(&[
                        &"-nostdin",
                        &"-loglevel",
                        &"error",
                        &"-i",
                        &path,
                        &"-frames:v",
                        &"1",
                        &"-vf",
                        &"scale='min(2048,iw)':-2",
                        &"-y",
                        &converted,
                    ]),
                    timeout,
                )
                .await;
            let image = match result {
                Ok(()) => read_image(ctx, converted.clone()).await,
                Err(error) => Err(error.to_string()),
            };
            let _ = tokio::fs::remove_file(&converted).await;
            image
        }
        "image/heic" | "image/heif" | "image/avif" => {
            let heif = ctx
                .tools
                .heif_dec
                .as_ref()
                .ok_or("libheif (heif-dec) is not installed")?;
            let converted = ctx.scratch().join(format!("{}.png", uuid::Uuid::new_v4()));
            let result = ctx
                .tools
                .run(
                    "heif-dec",
                    heif,
                    &tools::args(&[&path, &converted]),
                    timeout,
                )
                .await;
            let image = match result {
                Ok(()) => read_image(ctx, converted.clone()).await,
                Err(error) => Err(error.to_string()),
            };
            let _ = tokio::fs::remove_file(&converted).await;
            image
        }
        other => Err(format!("no decoder for {other}")),
    }
}

/// Pictures that would take more memory than this once decoded are not decoded. A small file can
/// claim to be gigapixels (a "decompression bomb"); allocating that much could take the whole
/// server down on a computer with little memory. 1 GiB holds a 48-megapixel photo with 16 bits
/// per channel twice over.
pub const MAX_DECODED_BYTES: u64 = 1 << 30;
/// And no side longer than this.
pub const MAX_SIDE: u32 = 50_000;

/// A decoder for the picture at `path` that refuses, before allocating anything, pictures that
/// are too big (see [`MAX_DECODED_BYTES`]).
pub fn decoder_for(path: &std::path::Path) -> Result<impl ImageDecoder, String> {
    let mut reader = ImageReader::open(path)
        .and_then(ImageReader::with_guessed_format)
        .map_err(|e| e.to_string())?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(MAX_SIDE);
    limits.max_image_height = Some(MAX_SIDE);
    limits.max_alloc = Some(MAX_DECODED_BYTES);
    reader.limits(limits);
    let decoder = reader.into_decoder().map_err(|e| e.to_string())?;
    let (width, height) = decoder.dimensions();
    if decoder.total_bytes() > MAX_DECODED_BYTES {
        return Err(format!(
            "the picture is too big to decode ({width} × {height} pixels)"
        ));
    }
    Ok(decoder)
}

async fn read_image(ctx: &JobContext, path: std::path::PathBuf) -> Result<DynamicImage, String> {
    ctx.background
        .run(move || -> Result<DynamicImage, String> {
            let mut decoder = decoder_for(&path)?;
            let orientation = decoder.orientation().map_err(|e| e.to_string())?;
            let mut image = DynamicImage::from_decoder(decoder).map_err(|e| e.to_string())?;
            image.apply_orientation(orientation);
            Ok(image)
        })
        .await
        .ok_or("decoding the photo crashed")?
}

/// Scales down so the long edge is at most `edge` (never up) and encodes as JPEG.
pub fn shrink(image: &DynamicImage, edge: u32, quality: u8) -> Result<(Vec<u8>, u32, u32), String> {
    let (width, height) = (image.width().max(1), image.height().max(1));
    let scale = (f64::from(edge) / f64::from(width.max(height))).min(1.0);
    let target_w = ((f64::from(width) * scale).round() as u32).max(1);
    let target_h = ((f64::from(height) * scale).round() as u32).max(1);
    let source = DynamicImage::ImageRgb8(image.to_rgb8());
    let mut target = DynamicImage::new_rgb8(target_w, target_h);
    Resizer::new()
        .resize(
            &source,
            &mut target,
            &ResizeOptions::new().resize_alg(ResizeAlg::Convolution(FilterType::Lanczos3)),
        )
        .map_err(|e| e.to_string())?;
    let mut out = Cursor::new(Vec::new());
    JpegEncoder::new_with_quality(&mut out, quality)
        .encode_image(&target)
        .map_err(|e| e.to_string())?;
    Ok((out.into_inner(), target_w, target_h))
}

/// How long after the upload the server makes thumbnails the phone didn't send.
pub fn delay(minutes: u32) -> Duration {
    Duration::from_secs(u64::from(minutes) * 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shrinks_to_the_long_edge_and_never_enlarges() {
        let wide = DynamicImage::new_rgb8(4032, 3024);
        let (jpeg, w, h) = shrink(&wide, 512, 80).unwrap();
        assert_eq!((w, h), (512, 384));
        assert_eq!(&jpeg[..2], &[0xff, 0xd8]);
        let small = DynamicImage::new_rgb8(300, 200);
        let (_, w, h) = shrink(&small, 512, 80).unwrap();
        assert_eq!((w, h), (300, 200));
        let tall = DynamicImage::new_rgba8(1000, 4000);
        let (_, w, h) = shrink(&tall, 2048, 85).unwrap();
        assert_eq!((w, h), (512, 2048));
    }
}
