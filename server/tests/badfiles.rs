//! Files that try to hurt the server: a decompression bomb, broken JPEG, HEIC and video files,
//! content that doesn't match its type, a giant EXIF block, an empty file. The original is
//! always kept exactly as it arrived; making a thumbnail or reading metadata may fail, but only
//! that job fails, the server stays up and its memory bounded.

mod common;

use std::time::Duration;

use common::{Api, LUCAS_PASSWORD, gradient_jpeg, iphone, random_bytes, sha_hex};
use halden::accounts::Role;
use serde_json::{Value, json};
use uuid::Uuid;

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = (data.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut covered = kind.to_vec();
    covered.extend_from_slice(data);
    out.extend_from_slice(&crc32(&covered).to_be_bytes());
    out
}

/// A tiny PNG that claims to be 50,000 × 50,000 pixels (7.5 GB once decoded).
fn png_bomb() -> Vec<u8> {
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut header = Vec::new();
    header.extend_from_slice(&50_000u32.to_be_bytes());
    header.extend_from_slice(&50_000u32.to_be_bytes());
    header.extend_from_slice(&[8, 2, 0, 0, 0]); // 8 bit RGB
    png.extend(chunk(b"IHDR", &header));
    // A zlib stream of a few zero rows; the rest is missing.
    png.extend(chunk(
        b"IDAT",
        &[0x78, 0x9c, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01],
    ));
    png.extend(chunk(b"IEND", &[]));
    png
}

/// A JPEG with a 60 KB EXIF block of nonsense, then a real picture.
fn jpeg_with_giant_exif() -> Vec<u8> {
    let real = gradient_jpeg();
    let mut out = vec![0xff, 0xd8];
    let mut payload = b"Exif\0\0MM\0\x2a\0\0\0\x08".to_vec();
    payload.extend(std::iter::repeat_n(0xffu8, 60_000));
    out.extend_from_slice(&[0xff, 0xe1]);
    out.extend_from_slice(&((payload.len() + 2) as u16).to_be_bytes());
    out.extend_from_slice(&payload);
    out.extend_from_slice(&real[2..]);
    out
}

async fn upload(api: &Api, token: &str, data: &[u8], mime: &str) -> (u16, Value, String) {
    let id = Uuid::new_v4().to_string();
    let created = api
        .post(
            "/api/v1/uploads",
            Some(token),
            json!({ "assetId": id, "size": data.len(), "sha256": sha_hex(data), "mimeType": mime }),
        )
        .await;
    if created.status != 201 {
        return (created.status, created.body, id);
    }
    let upload = created.body["uploadId"].as_str().unwrap();
    let response = api
        .http
        .patch(api.url(&format!("/api/v1/uploads/{upload}")))
        .bearer_auth(token)
        .header("upload-offset", "0")
        .body(data.to_vec())
        .send()
        .await
        .unwrap();
    let reply = Api::reply(response).await;
    (reply.status, reply.body, id)
}

/// Waits for the thumbnail job of an asset to have failed at least once; returns its error.
async fn thumbnail_error(api: &Api, asset: &str) -> String {
    let pool = api.pool().await;
    for _ in 0..400 {
        let found: Option<(Option<String>,)> =
            sqlx::query_as("SELECT last_error FROM jobs WHERE kind = 'thumbnail' AND asset_id = ?")
                .bind(asset)
                .fetch_optional(pool.read())
                .await
                .unwrap();
        if let Some((Some(error),)) = found {
            pool.close().await;
            return error;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the thumbnail job of {asset} never failed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bad_files_fail_their_jobs_never_the_server() {
    let api = Api::start_with(|config| config.jobs.thumbnail_delay_minutes = 0).await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;

    let mut broken_jpeg = b"\xff\xd8\xff\xe0\0\x10JFIF\0".to_vec();
    broken_jpeg.extend(random_bytes(20_000));
    let mut cut_heic = vec![0, 0, 0, 0x18];
    cut_heic.extend_from_slice(b"ftypheic\0\0\0\0mif1heic");
    cut_heic.extend(random_bytes(5_000));
    let mut broken_video = vec![0, 0, 0, 0x14];
    broken_video.extend_from_slice(b"ftypqt  \0\0\0\0qt  ");
    broken_video.extend(random_bytes(50_000));
    let png_as_heic = {
        let mut out = std::io::Cursor::new(Vec::new());
        image::RgbImage::new(64, 64)
            .write_to(&mut out, image::ImageFormat::Png)
            .unwrap();
        out.into_inner()
    };

    let mut cases = vec![
        ("decompression bomb", png_bomb(), "image/png", true),
        ("broken JPEG", broken_jpeg, "image/jpeg", true),
        ("PNG that says it is HEIC", png_as_heic, "image/heic", false),
    ];
    if common::tool("ffmpeg") {
        cases.push(("broken video", broken_video, "video/quicktime", true));
    }
    if common::tool("heif-dec") {
        cases.push(("cut-off HEIC", cut_heic, "image/heic", true));
    }
    for (name, data, mime, must_fail) in cases {
        let (status, body, id) = upload(&api, &token, &data, mime).await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(
            body["state"], "completed",
            "{name}: the original is kept: {body}"
        );
        if must_fail {
            let error = thumbnail_error(&api, &id).await;
            assert!(!error.is_empty(), "{name}");
            if name == "decompression bomb" {
                // Refused before a single byte is allocated for the pixels.
                assert!(error.contains("too big to decode"), "{error}");
            }
            eprintln!("{name}: the thumbnail job failed with: {error}");
        }
        // The original is byte for byte what arrived.
        let original = api
            .http
            .get(api.url(&format!("/api/v1/assets/{id}/files/original")))
            .bearer_auth(&token)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        assert_eq!(original.as_ref(), data.as_slice(), "{name}");
        // And the server answers as before.
        assert_eq!(api.get("/api/v1/me", &token).await.status, 200, "{name}");
    }
    if let Some(memory) = own_memory_of_this_process() {
        assert!(
            memory < 1_000_000_000,
            "memory stayed bounded: {memory} bytes"
        );
    }

    // A giant EXIF block: read what can be read, keep the photo.
    let (status, body, _) = upload(&api, &token, &jpeg_with_giant_exif(), "image/jpeg").await;
    assert_eq!(
        (status, body["state"].as_str()),
        (200, Some("completed")),
        "{body}"
    );

    // An empty file is not a photo.
    let empty = api
        .post(
            "/api/v1/uploads",
            Some(&token),
            json!({ "assetId": Uuid::new_v4(), "size": 0, "sha256": sha_hex(b""), "mimeType": "image/jpeg" }),
        )
        .await;
    assert_eq!(empty.status, 422, "{}", empty.body);
    api.stop().await;
}

/// Resident anonymous memory (Linux only): what this test process, and the server in it, use.
fn own_memory_of_this_process() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("RssAnon:"))?;
    let kb: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb * 1024)
}
