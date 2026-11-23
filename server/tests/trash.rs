//! The trash and conversions against the real server: trash, restore, delete for good (only from
//! the trash), expiry after 30 days, tombstones, and extra copies in the preferred format.

mod common;

use common::{
    Api, LUCAS_PASSWORD, gradient_jpeg, iphone, random_bytes, sha_hex, tool, wait_for_files,
};
use halden::{accounts::Role, db::Db, server};
use reqwest::Method;
use serde_json::{Value, json};
use uuid::Uuid;

async fn owner(api: &Api) -> String {
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.token("lucas", LUCAS_PASSWORD, iphone()).await
}

fn ids(list: &[&str]) -> Value {
    json!({ "ids": list })
}

fn file<'a>(asset: &'a Value, role: &str) -> Option<&'a Value> {
    asset["files"]
        .as_array()?
        .iter()
        .find(|f| f["role"] == role)
}

#[tokio::test]
async fn photos_go_to_the_trash_before_they_are_gone() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let data = random_bytes(5000);
    let id = Uuid::new_v4().to_string();
    let asset = api
        .upload(
            &token,
            &id,
            &data,
            "image/heic",
            json!({ "takenAt": 1_795_443_730_000_i64,
                "timeZoneOffsetMinutes": 60, "location": { "latitude": 50.5, "longitude": 9.6 } }),
        )
        .await;
    let thumbnail = random_bytes(3000);
    api.put_derived(&token, &id, "thumbnail", &thumbnail).await;
    let since = asset["seq"].as_i64().unwrap();
    let original = api
        .config
        .storage
        .library_dir
        .join("lucas/2026/11/2026-11-23_15-22-10.heic");
    assert!(original.exists());

    let trashed = api
        .post("/api/v1/assets/trash", Some(&token), ids(&[&id]))
        .await;
    assert_eq!(trashed.body["changed"], 1);
    let again = api
        .post("/api/v1/assets/trash", Some(&token), ids(&[&id]))
        .await;
    assert_eq!(again.body["changed"], 0, "repeating is harmless");
    let change = api
        .get(&format!("/api/v1/sync?since={since}"), &token)
        .await;
    assert!(change.body["assets"][0]["trashedAt"].is_i64());

    // Deleting needs the trash first; restoring brings it back.
    let restored = api
        .post("/api/v1/assets/restore", Some(&token), ids(&[&id]))
        .await;
    assert_eq!(restored.body["changed"], 1);
    let refused = api
        .post("/api/v1/assets/delete", Some(&token), ids(&[&id]))
        .await;
    assert_eq!(refused.body["changed"], 0, "not in the trash: not deleted");
    assert!(original.exists());

    api.post("/api/v1/assets/trash", Some(&token), ids(&[&id]))
        .await;
    let deleted = api
        .post("/api/v1/assets/delete", Some(&token), ids(&[&id]))
        .await;
    assert_eq!(deleted.body["changed"], 1);
    assert!(!original.exists(), "the original is gone from the library");
    let hash = sha_hex(&thumbnail);
    let derived = api
        .config
        .derived_dir()
        .join(&hash[..2])
        .join(&hash[2..4])
        .join(format!("{hash}.jpg"));
    assert!(!derived.exists(), "and so is its thumbnail");

    // A tombstone remains, without files or place, so every device learns about it.
    let tombstone = api.get(&format!("/api/v1/assets/{id}"), &token).await;
    assert!(tombstone.body["deletedAt"].is_i64());
    assert!(tombstone.body["files"].as_array().unwrap().is_empty());
    assert!(tombstone.body["location"].is_null());
    assert!(tombstone.body["client"].is_null());
    let sync = api
        .get(&format!("/api/v1/sync?since={since}"), &token)
        .await;
    let last = sync.body["assets"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()
        .clone();
    assert!(last["deletedAt"].is_i64());
    let gone = api
        .get(&format!("/api/v1/files/{}", sha_hex(&data)), &token)
        .await;
    assert_eq!(gone.status, 404);

    // The same content can be backed up again, under a new id.
    let reused = api
        .post(
            "/api/v1/uploads",
            Some(&token),
            json!({ "assetId": id, "size": data.len(), "sha256": sha_hex(&data), "mimeType": "image/heic" }),
        )
        .await;
    assert_eq!(reused.error(), "conflict");
    let fresh = api
        .post(
            "/api/v1/uploads",
            Some(&token),
            json!({ "assetId": Uuid::new_v4(), "size": data.len(), "sha256": sha_hex(&data), "mimeType": "image/heic" }),
        )
        .await;
    assert_eq!(fresh.body["state"], "receiving");
    api.stop().await;
}

#[tokio::test]
async fn the_trash_empties_itself_and_old_tombstones_go() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let id = Uuid::new_v4().to_string();
    let kept = Uuid::new_v4().to_string();
    api.upload(&token, &id, &random_bytes(100), "image/heic", json!({}))
        .await;
    api.upload(&token, &kept, &random_bytes(101), "image/heic", json!({}))
        .await;
    api.post("/api/v1/assets/trash", Some(&token), ids(&[&id, &kept]))
        .await;

    let db = Db::open(&api.config.db_path()).await.unwrap();
    sqlx::query("UPDATE assets SET trashed_at = 1 WHERE id = ?")
        .bind(&id)
        .execute(db.write())
        .await
        .unwrap();
    server::tidy(&db, &api.config).await;
    let expired = api.get(&format!("/api/v1/assets/{id}"), &token).await;
    assert!(
        expired.body["deletedAt"].is_i64(),
        "30 days in the trash: deleted"
    );
    let recent = api.get(&format!("/api/v1/assets/{kept}"), &token).await;
    assert!(recent.body["deletedAt"].is_null(), "still in the trash");

    sqlx::query("UPDATE assets SET deleted_at = 1 WHERE id = ?")
        .bind(&id)
        .execute(db.write())
        .await
        .unwrap();
    server::tidy(&db, &api.config).await;
    db.close().await;
    assert_eq!(
        api.get(&format!("/api/v1/assets/{id}"), &token)
            .await
            .status,
        404
    );
    let behind = api.get("/api/v1/sync?since=1", &token).await;
    assert_eq!(behind.body["resetRequired"], true);
    api.stop().await;
}

async fn settings(api: &Api, token: &str, change: Value) -> Value {
    let reply = api
        .call(
            Method::PUT,
            "/api/v1/me/settings",
            Some(token),
            Some(change),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    reply.body
}

async fn wait_without(api: &Api, token: &str, id: &str, role: &str) -> Value {
    for _ in 0..300 {
        let asset = api.get(&format!("/api/v1/assets/{id}"), token).await.body;
        if file(&asset, role).is_none() {
            return asset;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("{role} of {id} was not removed");
}

#[tokio::test]
async fn copies_in_the_preferred_format_sit_next_to_the_original() {
    let api = Api::start_with(|config| config.jobs.thumbnail_delay_minutes = 600).await;
    let token = owner(&api).await;
    let defaults = api.get("/api/v1/me/settings", &token).await;
    assert_eq!(defaults.body["photoFormat"], "original");
    assert_eq!(defaults.body["videoFormat"], "original");

    let photo = Uuid::new_v4().to_string();
    let taken = json!({ "takenAt": 1_795_443_730_000_i64, "timeZoneOffsetMinutes": 60 });
    api.upload(
        &token,
        &photo,
        &gradient_jpeg(),
        "image/jpeg",
        taken.clone(),
    )
    .await;

    // Choosing PNG converts the existing photo in the background.
    let changed = settings(&api, &token, json!({ "photoFormat": "png" })).await;
    assert_eq!(changed["queuedConversions"], 1);
    let asset = wait_for_files(&api, &token, &photo, &["converted"]).await;
    let converted = file(&asset, "converted").unwrap();
    assert_eq!(converted["mimeType"], "image/png");
    let next_to_it = api
        .config
        .storage
        .library_dir
        .join("lucas/2026/11/2026-11-23_15-22-10.png");
    let bytes = std::fs::read(&next_to_it).unwrap();
    assert_eq!(sha_hex(&bytes), converted["sha256"].as_str().unwrap());
    let decoded = image::load_from_memory(&bytes).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (1600, 1200));

    // New uploads get their copy right away.
    let second = Uuid::new_v4().to_string();
    let mut other_photo = gradient_jpeg();
    other_photo.push(0); // other content, so it is not a duplicate
    api.upload(&token, &second, &other_photo, "image/jpeg", json!({}))
        .await;
    wait_for_files(&api, &token, &second, &["converted"]).await;

    // Back to "original": the copies go.
    settings(&api, &token, json!({ "photoFormat": "original" })).await;
    wait_without(&api, &token, &photo, "converted").await;
    assert!(!next_to_it.exists());

    if tool("ffmpeg") {
        let dir = tempfile::tempdir().unwrap();
        let clip = dir.path().join("clip.mov");
        let made = std::process::Command::new("ffmpeg")
            .args([
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc=duration=1:size=320x240:rate=25",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=1",
                "-c:v",
                "mpeg4",
                "-c:a",
                "aac",
                "-shortest",
                "-f",
                "mov",
                "-y",
            ])
            .arg(&clip)
            .status()
            .unwrap();
        assert!(made.success());
        let video = Uuid::new_v4().to_string();
        api.upload(
            &token,
            &video,
            &std::fs::read(&clip).unwrap(),
            "video/quicktime",
            taken.clone(),
        )
        .await;
        settings(&api, &token, json!({ "videoFormat": "mp4" })).await;
        let asset = wait_for_files(&api, &token, &video, &["converted"]).await;
        assert_eq!(file(&asset, "converted").unwrap()["mimeType"], "video/mp4");
        let mp4 = std::fs::read(
            api.config
                .storage
                .library_dir
                .join("lucas/2026/11/2026-11-23_15-22-10.mp4"),
        )
        .unwrap();
        assert_eq!(&mp4[4..8], b"ftyp");
        assert_ne!(&mp4[8..12], b"qt  ", "an MP4, not a QuickTime file");
    }

    if tool("heif-enc") {
        let dir = tempfile::tempdir().unwrap();
        let jpeg = dir.path().join("in.jpg");
        let heic = dir.path().join("out.heic");
        std::fs::write(&jpeg, gradient_jpeg()).unwrap();
        assert!(
            std::process::Command::new("heif-enc")
                .arg(&jpeg)
                .arg("-o")
                .arg(&heic)
                .status()
                .unwrap()
                .success()
        );
        let photo = Uuid::new_v4().to_string();
        api.upload(
            &token,
            &photo,
            &std::fs::read(&heic).unwrap(),
            "image/heic",
            json!({}),
        )
        .await;
        settings(&api, &token, json!({ "photoFormat": "jpeg" })).await;
        let asset = wait_for_files(&api, &token, &photo, &["converted"]).await;
        let converted = file(&asset, "converted").unwrap();
        assert_eq!(converted["mimeType"], "image/jpeg");
        let jpeg = api
            .http
            .get(api.url(&format!(
                "/api/v1/files/{}",
                converted["sha256"].as_str().unwrap()
            )))
            .bearer_auth(&token)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        assert_eq!(image::load_from_memory(&jpeg).unwrap().width(), 1600);
    }

    let bad = api
        .call(
            Method::PUT,
            "/api/v1/me/settings",
            Some(&token),
            Some(json!({ "photoFormat": "bmp" })),
        )
        .await;
    assert_eq!(bad.error(), "validation_failed");
    api.stop().await;
}
