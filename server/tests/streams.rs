//! Small copies of big videos, to play on the go: the server makes one when the phone hasn't
//! sent its own, and keeps the phone's when it has.

mod common;

use common::{Api, LUCAS_PASSWORD, iphone, sha_hex, tool, wait_for_files};
use halden::accounts::Role;
use serde_json::json;
use uuid::Uuid;

/// A 1080p clip at a high bit rate: worth a small copy.
fn big_clip(dir: &std::path::Path) -> Vec<u8> {
    let clip = dir.join("big.mp4");
    let made = std::process::Command::new("ffmpeg")
        .args([
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc=duration=2:size=1920x1080:rate=30",
            // Noise: a file as big as a phone's, not one a test pattern makes.
            "-vf",
            "noise=alls=40:allf=t",
            "-c:v",
            "mpeg4",
            "-q:v",
            "2",
            "-y",
        ])
        .arg(&clip)
        .status()
        .unwrap();
    assert!(made.success());
    std::fs::read(&clip).unwrap()
}

#[tokio::test]
async fn big_videos_get_a_small_copy() {
    if !tool("ffmpeg") {
        eprintln!("ffmpeg is not installed: skipped");
        return;
    }
    let api = Api::start_with(|config| config.jobs.thumbnail_delay_minutes = 0).await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let dir = tempfile::tempdir().unwrap();
    let original = big_clip(dir.path());

    // Nothing from the phone: the server makes it.
    let id = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &id,
        &original,
        "video/mp4",
        json!({ "durationMs": 2000 }),
    )
    .await;
    let asset = wait_for_files(&api, &token, &id, &["stream"]).await;
    let stream = asset["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["role"] == "stream")
        .unwrap()
        .clone();
    assert_eq!(stream["mimeType"], "video/mp4");
    assert!(
        stream["size"].as_i64().unwrap() < original.len() as i64 / 2,
        "{stream}"
    );
    let bytes = api
        .http
        .get(api.url(&format!("/api/v1/assets/{id}/files/stream")))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    let small = dir.path().join("small.mp4");
    std::fs::write(&small, &bytes).unwrap();
    let probe = std::process::Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,height",
            "-of",
            "csv=p=0",
        ])
        .arg(&small)
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&probe.stdout).trim(), "h264,720");

    // The phone's own copy (the role `stream`) is kept; the server makes none.
    let second = Uuid::new_v4().to_string();
    let other = {
        let mut other = original.clone();
        other.extend_from_slice(b"another file");
        other
    };
    api.upload(
        &token,
        &second,
        &other,
        "video/mp4",
        json!({ "durationMs": 2000 }),
    )
    .await;
    let phone_copy = bytes.to_vec();
    let created = api
        .post(
            "/api/v1/uploads",
            Some(&token),
            json!({ "assetId": second, "role": "stream", "size": phone_copy.len(),
                    "sha256": sha_hex(&phone_copy), "mimeType": "video/mp4" }),
        )
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    let upload = created.body["uploadId"].as_str().unwrap();
    let sent = api
        .http
        .patch(api.url(&format!("/api/v1/uploads/{upload}")))
        .bearer_auth(&token)
        .header("Upload-Offset", "0")
        .header("Content-Type", "application/offset+octet-stream")
        .body(phone_copy.clone())
        .send()
        .await
        .unwrap();
    assert!(sent.status().is_success(), "{}", sent.status());
    let asset = wait_for_files(&api, &token, &second, &["stream"]).await;
    let kept = asset["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["role"] == "stream")
        .unwrap()
        .clone();
    assert_eq!(kept["sha256"], sha_hex(&phone_copy));

    // A photo can't have one.
    let photo = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &photo,
        &common::gradient_jpeg(),
        "image/jpeg",
        json!({}),
    )
    .await;
    let refused = api
        .post(
            "/api/v1/uploads",
            Some(&token),
            json!({ "assetId": photo, "role": "stream", "size": 3, "sha256": sha_hex(b"abc"),
                    "mimeType": "image/jpeg" }),
        )
        .await;
    assert_eq!(refused.status, 409, "{}", refused.body);
}
