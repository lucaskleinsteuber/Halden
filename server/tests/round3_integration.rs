//! End-to-end Round 3 integration and regression tests against the real server:
//! multi-device sync across bursts, Live Photos + `live_effect`, EditRecipe v2,
//! estimated `device` locations, Cinematic & Spatial videos, DNG thumbnails,
//! albums, shared links, trash/restore, account isolation and validation edge cases.

mod common;

use common::{
    ANNA_PASSWORD, Api, LUCAS_PASSWORD, device, iphone, random_bytes, sha_hex, wait_for_files,
};
use halden::accounts::Role;
use reqwest::Method;
use serde_json::{Value, json};
use uuid::Uuid;

async fn upload_role(api: &Api, token: &str, asset_id: &str, role: &str, data: &[u8], mime: &str) {
    let created = api
        .post(
            "/api/v1/uploads",
            Some(token),
            json!({
                "assetId": asset_id,
                "role": role,
                "size": data.len(),
                "sha256": sha_hex(data),
                "mimeType": mime
            }),
        )
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    let upload_id = created.body["uploadId"].as_str().unwrap();
    let response = api
        .http
        .patch(api.url(&format!("/api/v1/uploads/{upload_id}")))
        .bearer_auth(token)
        .header("upload-offset", "0")
        .body(data.to_vec())
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
}

async fn sync_all(api: &Api, token: &str, limit: u32) -> (Vec<Value>, Vec<Value>, i64) {
    let mut since = 0_i64;
    let mut assets = Vec::new();
    let mut albums = Vec::new();
    loop {
        let page = api
            .get(&format!("/api/v1/sync?since={since}&limit={limit}"), token)
            .await;
        assert_eq!(page.status, 200, "{}", page.body);
        assets.extend(page.body["assets"].as_array().unwrap().iter().cloned());
        albums.extend(page.body["albums"].as_array().unwrap().iter().cloned());
        since = page.body["nextSince"].as_i64().unwrap();
        if page.body["hasMore"] != true {
            return (assets, albums, since);
        }
    }
}

/// Full Round 3 lifecycle from Device 1 (iPhone) synced page-by-page to Device 2 (iPad),
/// while verifying strict isolation from a second account (`anna`).
#[tokio::test]
async fn round3_multi_device_full_lifecycle() {
    let api = Api::start_with(|config| {
        config.jobs.thumbnail_delay_minutes = 0;
        config.share.enabled = true;
        config.share.listen = "127.0.0.1:0".parse().unwrap();
        config.share.public_url = "https://photos.example.com".into();
    })
    .await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;

    let phone = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let ipad = api
        .token(
            "lucas",
            LUCAS_PASSWORD,
            device("Lucas' iPad", "install-lucas-ipad"),
        )
        .await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-r3"),
        )
        .await;

    let base_time = 1_795_443_730_000_i64;

    // 1. Burst of 3 photos sharing one burstId.
    let burst_id = Uuid::new_v4().to_string();
    let mut burst_assets = Vec::new();
    for i in 0..3 {
        let id = Uuid::new_v4().to_string();
        api.upload(
            &phone,
            &id,
            &random_bytes(320 + i),
            "image/heic",
            json!({
                "takenAt": base_time + (i as i64) * 200,
                "burstId": burst_id
            }),
        )
        .await;
        burst_assets.push(id);
    }

    // 2. Live Photo with `live_effect` transition (Loop MP4 → Bounce MP4 → Long Exposure HEIC).
    let live_id = Uuid::new_v4().to_string();
    api.upload(
        &phone,
        &live_id,
        &random_bytes(400),
        "image/heic",
        json!({ "takenAt": base_time + 1_000 }),
    )
    .await;
    upload_role(
        &api,
        &phone,
        &live_id,
        "paired_video",
        &random_bytes(600),
        "video/quicktime",
    )
    .await;
    let loop_bytes = random_bytes(900);
    let effect_path = format!("/api/v1/assets/{live_id}/files/live_effect");
    let put1 = api
        .http
        .put(api.url(&effect_path))
        .bearer_auth(&phone)
        .header("content-type", "video/mp4")
        .header("halden-sha256", sha_hex(&loop_bytes))
        .body(loop_bytes)
        .send()
        .await
        .unwrap();
    assert_eq!(put1.status(), 200);

    // Wrong checksum must be rejected with 422.
    let bad_sha = api
        .http
        .put(api.url(&effect_path))
        .bearer_auth(&phone)
        .header("content-type", "video/mp4")
        .header("halden-sha256", "0".repeat(64))
        .body(random_bytes(128))
        .send()
        .await
        .unwrap();
    assert_eq!(bad_sha.status(), 422);

    // Replace with Long Exposure HEIC + edit recipe.
    let long_bytes = random_bytes(700);
    let put2 = api
        .http
        .put(api.url(&effect_path))
        .bearer_auth(&phone)
        .header("content-type", "image/heic")
        .header("halden-sha256", sha_hex(&long_bytes))
        .body(long_bytes.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(put2.status(), 200);
    let patch_live = api
        .call(
            Method::PATCH,
            &format!("/api/v1/assets/{live_id}"),
            Some(&phone),
            Some(json!({
                "edit": {
                    "version": 2,
                    "liveEffect": "long_exposure",
                    "liveKeyFrameMs": 450,
                    "style": { "preset": "amber", "tone": 0.2, "color": 0.35, "palette": 0.7 },
                    "filter": "vivid_warm",
                    "portraitAperture": 2.8,
                    "portraitLighting": "studio"
                }
            })),
        )
        .await;
    assert_eq!(patch_live.status, 200, "{}", patch_live.body);

    // 3. Screenshot with `location.source = "device"`: original stays null, effective shows `device`.
    let shot_id = Uuid::new_v4().to_string();
    api.upload(
        &phone,
        &shot_id,
        &random_bytes(350),
        "image/png",
        json!({
            "takenAt": base_time + 2_000,
            "location": {
                "latitude": 52.52,
                "longitude": 13.405,
                "horizontalAccuracy": 12.0,
                "source": "device"
            }
        }),
    )
    .await;
    let shot_detail = api.get(&format!("/api/v1/assets/{shot_id}"), &phone).await;
    assert_eq!(shot_detail.status, 200);
    assert!(shot_detail.body["original"]["location"].is_null());
    assert_eq!(shot_detail.body["location"]["source"], "device");

    // 4. Cinematic & Spatial videos + Audio Mix edit.
    let cin_id = Uuid::new_v4().to_string();
    api.upload(
        &phone,
        &cin_id,
        &random_bytes(512),
        "video/quicktime",
        json!({ "takenAt": base_time + 3_000, "captureMode": "cinematic" }),
    )
    .await;
    let spatial_id = Uuid::new_v4().to_string();
    api.upload(
        &phone,
        &spatial_id,
        &random_bytes(520),
        "video/quicktime",
        json!({ "takenAt": base_time + 4_000, "captureMode": "spatial" }),
    )
    .await;
    let patch_spatial = api
        .call(
            Method::PATCH,
            &format!("/api/v1/assets/{spatial_id}"),
            Some(&phone),
            Some(json!({
                "edit": { "version": 2, "audioMix": "cinematic", "audioMixIntensity": 0.65 }
            })),
        )
        .await;
    assert_eq!(patch_spatial.status, 200);

    // 5. DNG original gets server-generated thumbnail + preview.
    let mut dng = Vec::new();
    image::DynamicImage::new_rgb8(480, 360)
        .write_to(
            &mut std::io::Cursor::new(&mut dng),
            image::ImageFormat::Tiff,
        )
        .unwrap();
    let dng_id = Uuid::new_v4().to_string();
    api.upload(
        &phone,
        &dng_id,
        &dng,
        "image/dng",
        json!({ "takenAt": base_time + 5_000 }),
    )
    .await;
    wait_for_files(&api, &phone, &dng_id, &["thumbnail", "preview"]).await;

    // 6. Album & Shared Link + Trash/Restore of burst extras.
    let album_id = Uuid::new_v4().to_string();
    let album = api
        .post(
            "/api/v1/albums",
            Some(&phone),
            json!({
                "id": album_id,
                "name": "Round 3 Highlights",
                "assetIds": [burst_assets[0], live_id, cin_id, spatial_id]
            }),
        )
        .await;
    assert_eq!(album.status, 201);

    let share = api
        .post(
            "/api/v1/shares",
            Some(&phone),
            json!({ "title": "Shared R3", "assetIds": [live_id, dng_id] }),
        )
        .await;
    assert_eq!(share.status, 201);

    // Trash 2 burst extras, then restore 1 of them and permanently delete the other.
    let trash_resp = api
        .post(
            "/api/v1/assets/trash",
            Some(&phone),
            json!({ "ids": [burst_assets[1], burst_assets[2]] }),
        )
        .await;
    assert_eq!(trash_resp.status, 200);
    let restore_resp = api
        .post(
            "/api/v1/assets/restore",
            Some(&phone),
            json!({ "ids": [burst_assets[1]] }),
        )
        .await;
    assert_eq!(restore_resp.status, 200);
    let purge_resp = api
        .post(
            "/api/v1/assets/delete",
            Some(&phone),
            json!({ "ids": [burst_assets[2]] }),
        )
        .await;
    assert_eq!(purge_resp.status, 200);
    assert_eq!(purge_resp.body["changed"], 1);

    // 7. Device 2 (iPad) syncs everything in small pages (`limit=2`) and verifies complete fidelity.
    let (synced_assets, synced_albums, cursor) = sync_all(&api, &ipad, 2).await;
    assert!(cursor > 0);
    assert_eq!(
        synced_assets.len(),
        8,
        "3 burst + live + shot + cin + spatial + dng"
    );

    let by_id = |target: &str| {
        synced_assets
            .iter()
            .find(|a| a["id"] == target)
            .unwrap_or_else(|| panic!("missing {target} in sync"))
    };
    assert_eq!(by_id(&burst_assets[0])["burstId"], burst_id.as_str());
    assert!(by_id(&burst_assets[1])["trashedAt"].is_null());
    assert!(!by_id(&burst_assets[2])["deletedAt"].is_null());
    assert!(by_id(&burst_assets[2])["burstId"].is_null());
    assert_eq!(by_id(&live_id)["edit"]["liveEffect"], "long_exposure");
    assert_eq!(by_id(&live_id)["edit"]["style"]["preset"], "amber");
    assert!(
        by_id(&live_id)["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["role"] == "live_effect" && f["sha256"] == sha_hex(&long_bytes).as_str())
    );
    assert_eq!(by_id(&shot_id)["location"]["source"], "device");
    assert_eq!(by_id(&cin_id)["captureMode"], "cinematic");
    assert_eq!(by_id(&spatial_id)["captureMode"], "spatial");
    assert_eq!(by_id(&spatial_id)["edit"]["audioMix"], "cinematic");
    assert!(
        by_id(&dng_id)["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["role"] == "thumbnail")
    );
    assert_eq!(synced_albums.len(), 1);
    assert_eq!(synced_albums[0]["name"], "Round 3 Highlights");

    // 8. Account isolation: Anna cannot read, edit, or delete Lucas's Round 3 assets or albums.
    assert_eq!(
        api.get(&format!("/api/v1/assets/{live_id}"), &anna)
            .await
            .status,
        404
    );
    assert_eq!(
        api.call(Method::DELETE, &effect_path, Some(&anna), None)
            .await
            .status,
        404
    );
    assert_eq!(
        api.get(&format!("/api/v1/albums/{album_id}"), &anna)
            .await
            .status,
        404
    );
    api.stop().await;
}

/// Boundary & negative validation matrix for `EditRecipe` v2 fields.
#[tokio::test]
async fn round3_edit_recipe_v2_boundary_and_negative_validation() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let id = Uuid::new_v4().to_string();
    api.upload(&token, &id, &random_bytes(256), "image/heic", json!({}))
        .await;
    let path = format!("/api/v1/assets/{id}");

    // Valid boundary recipes must succeed.
    for valid in [
        json!({ "version": 1, "exposure": -3.0 }),
        json!({
            "version": 2,
            "style": { "preset": "standard", "tone": -1.0, "color": 1.0, "palette": 0.0 },
            "filter": "noir",
            "liveEffect": "live",
            "liveKeyFrameMs": 0,
            "audioMix": "standard",
            "audioMixIntensity": 0.0
        }),
        json!({
            "version": 2,
            "style": { "preset": "stark_bw", "tone": 1.0, "color": -1.0, "palette": 1.0 },
            "portraitAperture": 1.4,
            "portraitLighting": "highKeyMono",
            "cinematicAperture": 2.0,
            "cinematicFocusPoints": [
                { "timeMs": 0, "x": 0.0, "y": 1.0 },
                { "timeMs": 4200, "x": 0.5, "y": 0.5 }
            ],
            "liveEffect": "bounce",
            "liveKeyFrameMs": 600_000,
            "audioMix": "in_frame",
            "audioMixIntensity": 1.0
        }),
    ] {
        let resp = api
            .call(
                Method::PATCH,
                &path,
                Some(&token),
                Some(json!({ "edit": valid })),
            )
            .await;
        assert_eq!(
            resp.status, 200,
            "valid edit rejected: {valid} -> {}",
            resp.body
        );
    }

    // Invalid recipes must be rejected with 422.
    let huge_text = "x".repeat(17_000);
    for invalid in [
        json!({ "version": 0 }),
        json!("not an object"),
        json!({ "version": 2, "style": "amber" }),
        json!({ "version": 2, "style": { "preset": "a".repeat(33) } }),
        json!({ "version": 2, "style": { "preset": "amber", "tone": -1.01 } }),
        json!({ "version": 2, "style": { "preset": "amber", "color": 1.01 } }),
        json!({ "version": 2, "style": { "preset": "amber", "palette": 1.01 } }),
        json!({ "version": 2, "filter": "f".repeat(33) }),
        json!({ "version": 2, "portraitAperture": 1.3 }),
        json!({ "version": 2, "portraitAperture": 16.1 }),
        json!({ "version": 2, "portraitLighting": "neon" }),
        json!({ "version": 2, "cinematicAperture": 1.9 }),
        json!({ "version": 2, "cinematicAperture": 16.1 }),
        json!({ "version": 2, "cinematicFocusPoints": "bad" }),
        json!({ "version": 2, "cinematicFocusPoints": [{ "timeMs": -1, "x": 0.5, "y": 0.5 }] }),
        json!({ "version": 2, "cinematicFocusPoints": [{ "timeMs": 100, "x": 1.1, "y": 0.5 }] }),
        json!({ "version": 2, "liveEffect": "boomerang" }),
        json!({ "version": 2, "liveKeyFrameMs": -5 }),
        json!({ "version": 2, "liveKeyFrameMs": 600_001 }),
        json!({ "version": 2, "audioMix": "dolby" }),
        json!({ "version": 2, "audioMixIntensity": -0.01 }),
        json!({ "version": 2, "audioMixIntensity": 1.01 }),
        json!({ "version": 2, "note": huge_text }),
    ] {
        let resp = api
            .call(
                Method::PATCH,
                &path,
                Some(&token),
                Some(json!({ "edit": invalid })),
            )
            .await;
        assert_eq!(
            resp.status, 422,
            "expected 422 for invalid edit, got {}: {}",
            resp.status, resp.body
        );
    }

    // Clearing the edit back to null succeeds and records the full edit history.
    let clear = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "edit": null })),
        )
        .await;
    assert_eq!(clear.status, 200);
    assert!(clear.body["edit"].is_null());
    let detail = api.get(&path, &token).await;
    assert_eq!(detail.body["edits"].as_array().unwrap().len(), 4);
    api.stop().await;
}
