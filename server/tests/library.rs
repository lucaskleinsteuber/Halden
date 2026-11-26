//! The library against the real server: sync in pages, files with Range and caching, thumbnails
//! in bulk, corrections with history, location suggestions and server-made thumbnails.

mod common;

use common::{
    ANNA_PASSWORD, Api, LUCAS_PASSWORD, device, gradient_jpeg, iphone, random_bytes, sha_hex, tool,
    wait_for_files,
};
use halden::accounts::Role;
use reqwest::Method;
use serde_json::{Value, json};
use uuid::Uuid;

const MINUTE_MS: i64 = 60_000;

fn taken(at: i64, location: Option<(f64, f64)>) -> Value {
    let mut metadata = json!({ "takenAt": at, "timeZoneOffsetMinutes": 60 });
    if let Some((latitude, longitude)) = location {
        metadata["location"] = json!({ "latitude": latitude, "longitude": longitude,
                                       "horizontalAccuracy": 5.0 });
    }
    metadata
}

async fn owner(api: &Api) -> String {
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.token("lucas", LUCAS_PASSWORD, iphone()).await
}

#[tokio::test]
async fn sync_comes_in_pages_and_only_brings_changes() {
    let api = Api::start().await;
    let token = owner(&api).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;
    let mut ids = Vec::new();
    for n in 0..5 {
        let id = Uuid::new_v4().to_string();
        api.upload(&token, &id, &random_bytes(100 + n), "image/heic", json!({}))
            .await;
        ids.push(id);
    }

    let first = api.get("/api/v1/sync?since=0&limit=2", &token).await;
    assert_eq!(first.status, 200, "{}", first.body);
    assert_eq!(first.body["assets"].as_array().unwrap().len(), 2);
    assert_eq!(first.body["hasMore"], true);
    assert_eq!(first.body["assets"][0]["id"], ids[0].as_str());
    let mut since = first.body["nextSince"].as_i64().unwrap();
    let mut seen = 2;
    loop {
        let page = api
            .get(&format!("/api/v1/sync?since={since}&limit=2"), &token)
            .await;
        seen += page.body["assets"].as_array().unwrap().len();
        since = page.body["nextSince"].as_i64().unwrap();
        if page.body["hasMore"] == false {
            break;
        }
    }
    assert_eq!(seen, 5);
    // Exactly one full page left: nothing more to ask for.
    let exact = api.get("/api/v1/sync?since=0&limit=5", &token).await;
    assert_eq!(exact.body["assets"].as_array().unwrap().len(), 5);
    assert_eq!(exact.body["hasMore"], false);

    // Nothing new: an empty page. Then one correction brings exactly that asset.
    let empty = api
        .get(&format!("/api/v1/sync?since={since}"), &token)
        .await;
    assert!(empty.body["assets"].as_array().unwrap().is_empty());
    assert_eq!(empty.body["nextSince"], since);
    let corrected = api
        .call(
            Method::PATCH,
            &format!("/api/v1/assets/{}", ids[2]),
            Some(&token),
            Some(json!({ "title": "Fulda" })),
        )
        .await;
    assert_eq!(corrected.status, 200, "{}", corrected.body);
    let change = api
        .get(&format!("/api/v1/sync?since={since}"), &token)
        .await;
    let changed = change.body["assets"].as_array().unwrap();
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0]["id"], ids[2].as_str());
    assert_eq!(changed[0]["title"], "Fulda");

    // Other accounts see none of it.
    let other = api.get("/api/v1/sync?since=0", &anna).await;
    assert!(other.body["assets"].as_array().unwrap().is_empty());

    // A device that is behind the removed tombstones has to start over.
    let pool = api.pool().await;
    sqlx::query("UPDATE counters SET value = 1000 WHERE name = 'sync_floor'")
        .execute(pool.write())
        .await
        .unwrap();
    pool.close().await;
    let behind = api.get("/api/v1/sync?since=3", &token).await;
    assert_eq!(behind.body["resetRequired"], true);
    let fresh = api.get("/api/v1/sync?since=0", &token).await;
    assert_eq!(fresh.body["resetRequired"], false);
    assert_eq!(fresh.body["assets"].as_array().unwrap().len(), 5);
    api.stop().await;
}

#[tokio::test]
async fn files_come_with_range_and_caching() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let data = random_bytes(100_000);
    let id = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &id,
        &data,
        "video/quicktime",
        taken(1_795_443_730_000, None),
    )
    .await;
    let hash = sha_hex(&data);
    let by_hash = api.url(&format!("/api/v1/files/{hash}"));
    let get = |url: String, headers: Vec<(&'static str, String)>| {
        let mut request = api.http.get(url).bearer_auth(&token);
        for (name, value) in headers {
            request = request.header(name, value);
        }
        request.send()
    };

    let full = get(by_hash.clone(), vec![]).await.unwrap();
    assert_eq!(full.status(), 200);
    assert_eq!(full.headers()["etag"], format!("\"{hash}\"").as_str());
    assert_eq!(
        full.headers()["cache-control"],
        "private, max-age=31536000, immutable"
    );
    assert_eq!(full.headers()["accept-ranges"], "bytes");
    assert_eq!(full.headers()["content-type"], "video/quicktime");
    assert_eq!(full.bytes().await.unwrap().as_ref(), data.as_slice());

    let cached = get(
        by_hash.clone(),
        vec![("if-none-match", format!("\"{hash}\""))],
    )
    .await
    .unwrap();
    assert_eq!(cached.status(), 304);

    let part = get(by_hash.clone(), vec![("range", "bytes=10-19".into())])
        .await
        .unwrap();
    assert_eq!(part.status(), 206);
    assert_eq!(part.headers()["content-range"], "bytes 10-19/100000");
    assert_eq!(part.bytes().await.unwrap().as_ref(), &data[10..20]);
    let tail = get(by_hash.clone(), vec![("range", "bytes=-5".into())])
        .await
        .unwrap();
    assert_eq!(tail.bytes().await.unwrap().as_ref(), &data[99_995..]);
    let outside = get(by_hash.clone(), vec![("range", "bytes=200000-".into())])
        .await
        .unwrap();
    assert_eq!(outside.status(), 416);
    let stale = get(
        by_hash.clone(),
        vec![
            ("range", "bytes=0-9".into()),
            ("if-range", "\"something else\"".into()),
        ],
    )
    .await
    .unwrap();
    assert_eq!(stale.status(), 200, "a changed file is sent whole");

    let by_role = get(
        api.url(&format!("/api/v1/assets/{id}/files/original")),
        vec![],
    )
    .await
    .unwrap();
    assert_eq!(by_role.status(), 200);
    assert_eq!(by_role.headers()["cache-control"], "private, no-cache");
    assert_eq!(
        by_role.headers()["content-disposition"],
        "inline; filename=\"2026-11-23_15-22-10.mov\""
    );
    let head = api
        .http
        .head(by_hash.clone())
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(head.headers()["content-length"], "100000");

    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;
    let foreign = api
        .http
        .get(by_hash)
        .bearer_auth(anna)
        .send()
        .await
        .unwrap();
    assert_eq!(foreign.status(), 404);
    assert_eq!(api.get("/api/v1/files/nothex", &token).await.status, 404);
    api.stop().await;
}

/// Splits the bulk answer: (asset id, bytes) per entry.
fn parse_bulk(body: &[u8]) -> Vec<(Uuid, Vec<u8>)> {
    let mut entries = Vec::new();
    let mut rest = body;
    while !rest.is_empty() {
        let id = Uuid::from_slice(&rest[..16]).unwrap();
        let length = u32::from_be_bytes(rest[16..20].try_into().unwrap()) as usize;
        entries.push((id, rest[20..20 + length].to_vec()));
        rest = &rest[20 + length..];
    }
    entries
}

#[tokio::test]
async fn many_thumbnails_come_in_one_answer() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let ids: Vec<String> = (0..3).map(|_| Uuid::new_v4().to_string()).collect();
    let mut thumbnails = Vec::new();
    for id in &ids {
        api.upload(&token, id, &random_bytes(500), "image/heic", json!({}))
            .await;
        thumbnails.push(random_bytes(20_000 + thumbnails.len() * 1000));
    }
    for (id, thumbnail) in ids.iter().zip(&thumbnails).take(2) {
        let reply = api.put_derived(&token, id, "thumbnail", thumbnail).await;
        assert_eq!(reply.status, 200, "{}", reply.body);
    }
    let unknown = Uuid::new_v4().to_string();
    let response = api
        .http
        .post(api.url("/api/v1/thumbnails"))
        .bearer_auth(&token)
        .json(&json!({ "ids": [ids[1], ids[0], ids[2], unknown] }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.headers()["content-type"],
        "application/vnd.halden.files"
    );
    let entries = parse_bulk(&response.bytes().await.unwrap());
    assert_eq!(entries.len(), 4);
    assert_eq!(entries[0].0.to_string(), ids[1]);
    assert_eq!(entries[0].1, thumbnails[1]);
    assert_eq!(entries[1].1, thumbnails[0]);
    assert!(entries[2].1.is_empty(), "no thumbnail yet");
    assert!(entries[3].1.is_empty(), "unknown id");

    let bad = api
        .post(
            "/api/v1/thumbnails",
            Some(&token),
            json!({ "ids": [], "role": "original" }),
        )
        .await;
    assert_eq!(bad.error(), "validation_failed");
    api.stop().await;
}

#[tokio::test]
async fn corrections_keep_the_original_and_their_history() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let id = Uuid::new_v4().to_string();
    let at = 1_795_443_730_000;
    api.upload(
        &token,
        &id,
        &random_bytes(300),
        "image/heic",
        taken(at, Some((50.55, 9.68))),
    )
    .await;
    let path = format!("/api/v1/assets/{id}");

    let corrected = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({
                "takenAt": at - 3_600_000,
                "timeZoneOffsetMinutes": 120,
                "location": { "latitude": 48.137, "longitude": 11.575 },
                "title": "  Munich  ",
                "description": "Trip"
            })),
        )
        .await;
    assert_eq!(corrected.status, 200, "{}", corrected.body);
    let asset = &corrected.body;
    assert_eq!(asset["takenAt"], at - 3_600_000);
    // The same limits as for uploads (found by the app's tests: the year 5000 was taken).
    for impossible in [95_617_584_000_000_i64, -2_208_988_800_001] {
        let refused = api
            .call(
                Method::PATCH,
                &path,
                Some(&token),
                Some(json!({ "takenAt": impossible })),
            )
            .await;
        assert_eq!(
            (refused.status, refused.error()),
            (422, "validation_failed"),
            "{impossible}"
        );
    }
    assert_eq!(asset["timeZoneOffsetMinutes"], 120);
    assert_eq!(asset["takenAtSource"], "manual");
    assert_eq!(asset["location"]["latitude"], 48.137);
    assert_eq!(asset["location"]["source"], "manual");
    assert_eq!(asset["title"], "Munich");

    let detail = api.get(&path, &token).await;
    assert_eq!(detail.body["original"]["takenAt"], at);
    assert_eq!(detail.body["original"]["location"]["latitude"], 50.55);
    assert_eq!(detail.body["client"]["takenAt"], at);
    let edits = detail.body["edits"].as_array().unwrap();
    assert_eq!(edits.len(), 4, "{edits:?}");
    assert_eq!(edits[0]["field"], "takenAt");
    assert_eq!(edits[0]["old"]["takenAt"], at);
    assert!(edits[0]["deviceId"].is_string());

    // Removing the place hides it; restoring brings back the original.
    let hidden = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "location": null })),
        )
        .await;
    assert!(hidden.body["location"].is_null());
    let restored = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "restore": ["location", "takenAt"] })),
        )
        .await;
    assert_eq!(restored.body["location"]["latitude"], 50.55);
    assert_eq!(restored.body["location"]["source"], "client");
    assert_eq!(restored.body["takenAt"], at);
    assert_eq!(restored.body["takenAtSource"], "client");

    for bad in [
        json!({ "location": { "latitude": 91.0, "longitude": 0.0 } }),
        json!({ "timeZoneOffsetMinutes": 5000 }),
        json!({ "restore": ["camera"] }),
        json!({ "nonsense": true }),
    ] {
        let reply = api
            .call(Method::PATCH, &path, Some(&token), Some(bad))
            .await;
        assert_eq!(reply.error(), "validation_failed", "{}", reply.body);
    }
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;
    let foreign = api
        .call(
            Method::PATCH,
            &path,
            Some(&anna),
            Some(json!({ "title": "mine" })),
        )
        .await;
    assert_eq!(foreign.status, 404);
    api.stop().await;
}

/// A slow-motion video says so, and its slow part is a correction next to the unchanged
/// original, with its history; a photo never gets a capture mode.
#[tokio::test]
async fn slow_motion_keeps_its_slow_part_next_to_the_original() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let video = Uuid::new_v4().to_string();
    let mut metadata = taken(1_795_443_730_000, None);
    metadata["captureMode"] = json!("slowmo");
    api.upload(
        &token,
        &video,
        &random_bytes(400),
        "video/quicktime",
        metadata.clone(),
    )
    .await;
    let photo = Uuid::new_v4().to_string();
    api.upload(&token, &photo, &random_bytes(300), "image/heic", metadata)
        .await;
    let other = Uuid::new_v4().to_string();
    let mut unknown = taken(1_795_443_730_000, None);
    unknown["captureMode"] = json!("unknown_mode");
    api.upload(
        &token,
        &other,
        &random_bytes(500),
        "video/quicktime",
        unknown,
    )
    .await;

    let path = format!("/api/v1/assets/{video}");
    let asset = api.get(&path, &token).await.body;
    assert_eq!(asset["captureMode"], "slowmo", "{asset}");
    assert_eq!(asset["playback"], Value::Null);
    let photo_asset = api
        .get(&format!("/api/v1/assets/{photo}"), &token)
        .await
        .body;
    assert_eq!(photo_asset["captureMode"], Value::Null, "only videos");
    let other_asset = api
        .get(&format!("/api/v1/assets/{other}"), &token)
        .await
        .body;
    assert_eq!(
        other_asset["captureMode"],
        Value::Null,
        "unknown modes are not used"
    );
    assert_eq!(other_asset["playback"], Value::Null);

    let slow = json!({ "slowFromMs": 500, "slowToMs": 2500, "rate": 0.125 });
    let changed = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "playback": slow })),
        )
        .await;
    assert_eq!(changed.status, 200, "{}", changed.body);
    assert_eq!(changed.body["playback"], slow);
    for wrong in [
        json!({ "slowFromMs": 500, "slowToMs": 100, "rate": 0.125 }),
        json!({ "slowFromMs": -1, "slowToMs": 100, "rate": 0.125 }),
        json!({ "slowFromMs": 0, "slowToMs": 100, "rate": 2 }),
        json!({ "slowFromMs": 0, "slowToMs": 100, "rate": 0.5, "speed": 3 }),
    ] {
        let refused = api
            .call(
                Method::PATCH,
                &path,
                Some(&token),
                Some(json!({ "playback": wrong })),
            )
            .await;
        assert_eq!(refused.status, 422, "{wrong}: {}", refused.body);
    }
    // Other devices hear of it through sync.
    let page = api.get("/api/v1/sync?since=0", &token).await.body;
    let synced = page["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == video.as_str())
        .unwrap();
    assert_eq!(synced["playback"], slow);
    assert_eq!(synced["captureMode"], "slowmo");

    let back = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "playback": null })),
        )
        .await;
    assert_eq!(back.body["playback"], Value::Null);
    let edits = api.get(&path, &token).await.body["edits"].clone();
    let fields: Vec<_> = edits
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["field"].clone())
        .collect();
    assert_eq!(fields, [json!("playback"), json!("playback")], "{edits}");
    assert_eq!(edits[0]["new"], slow);
    assert_eq!(edits[1]["old"], slow);
    assert_eq!(edits[1]["new"], Value::Null);
}

/// An edit is kept as what was set, next to the unchanged original, with its history; the
/// server only checks it is one, and forgets it with the photo.
#[tokio::test]
async fn edits_are_kept_next_to_the_original() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let id = Uuid::new_v4().to_string();
    let original = random_bytes(300);
    api.upload(
        &token,
        &id,
        &original,
        "image/heic",
        taken(1_795_443_730_000, None),
    )
    .await;
    let path = format!("/api/v1/assets/{id}");
    let edit = json!({ "version": 1, "exposure": 0.5, "crop": { "x": 0.1, "y": 0, "width": 0.8, "height": 1 } });
    let changed = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "edit": edit })),
        )
        .await;
    assert_eq!(changed.status, 200, "{}", changed.body);
    assert_eq!(changed.body["edit"], edit);
    let files = changed.body["files"].as_array().unwrap();
    let kept = files.iter().find(|f| f["role"] == "original").unwrap();
    assert_eq!(
        kept["sha256"],
        sha_hex(&original),
        "the original never changes"
    );
    for wrong in [
        json!([1, 2]),
        json!({ "exposure": 1 }),
        json!({ "version": 0 }),
        json!({ "version": 1, "notes": "x".repeat(20_000) }),
    ] {
        let refused = api
            .call(
                Method::PATCH,
                &path,
                Some(&token),
                Some(json!({ "edit": wrong })),
            )
            .await;
        assert_eq!(refused.status, 422, "{}", refused.body);
    }
    let back = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "edit": null })),
        )
        .await;
    assert_eq!(back.body["edit"], Value::Null);
    let edits = api.get(&path, &token).await.body["edits"].clone();
    assert_eq!(edits.as_array().unwrap().len(), 2, "{edits}");
    assert_eq!(edits[1]["old"], edit);
}

#[tokio::test]
async fn photos_without_a_place_get_one_suggested() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let at = 1_795_443_730_000;
    let with_place = Uuid::new_v4().to_string();
    let soon_after = Uuid::new_v4().to_string();
    let much_later = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &with_place,
        &random_bytes(100),
        "image/heic",
        taken(at, Some((50.55, 9.68))),
    )
    .await;
    api.upload(
        &token,
        &soon_after,
        &random_bytes(101),
        "image/heic",
        taken(at + 10 * MINUTE_MS, None),
    )
    .await;
    api.upload(
        &token,
        &much_later,
        &random_bytes(102),
        "image/heic",
        taken(at + 300 * MINUTE_MS, None),
    )
    .await;

    let list = api.get("/api/v1/assets/without-location", &token).await;
    assert_eq!(list.status, 200, "{}", list.body);
    let assets = list.body["assets"].as_array().unwrap();
    assert_eq!(assets.len(), 2);
    assert_eq!(assets[0]["id"], much_later.as_str(), "newest first");
    assert!(
        assets[0]["suggestion"].is_null(),
        "nothing within two hours"
    );
    assert_eq!(assets[1]["suggestion"]["fromAssetId"], with_place.as_str());
    assert_eq!(assets[1]["suggestion"]["minutesApart"], 10);
    assert_eq!(assets[1]["suggestion"]["latitude"], 50.55);

    let single = api
        .get(
            &format!("/api/v1/assets/{soon_after}/location-suggestion"),
            &token,
        )
        .await;
    assert_eq!(
        single.body["suggestion"]["fromAssetId"],
        with_place.as_str()
    );

    let set = api
        .post(
            "/api/v1/assets/location",
            Some(&token),
            json!({ "ids": [soon_after, much_later, Uuid::new_v4()],
                    "location": { "latitude": 50.55, "longitude": 9.68, "estimated": true } }),
        )
        .await;
    assert_eq!(set.body["changed"], 2);
    let empty = api.get("/api/v1/assets/without-location", &token).await;
    assert!(empty.body["assets"].as_array().unwrap().is_empty());
    let asset = api
        .get(&format!("/api/v1/assets/{soon_after}"), &token)
        .await;
    assert_eq!(asset.body["location"]["source"], "estimated");
    api.stop().await;
}

/// Screenshots without GPS can carry the device's place (`device`) or a nearby photo's place
/// (`estimated`), kept as an estimated location without pretending the file had GPS.
#[tokio::test]
async fn device_location_source_is_stored_and_synced() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let at = 1_795_443_730_000;
    let screenshot = Uuid::new_v4().to_string();
    let mut metadata = taken(at, Some((50.55, 9.68)));
    metadata["location"]["source"] = json!("device");
    api.upload(
        &token,
        &screenshot,
        &random_bytes(120),
        "image/png",
        metadata,
    )
    .await;

    let path = format!("/api/v1/assets/{screenshot}");
    let detail = api.get(&path, &token).await;
    assert_eq!(detail.status, 200, "{}", detail.body);
    assert_eq!(detail.body["location"]["latitude"], 50.55);
    assert_eq!(detail.body["location"]["longitude"], 9.68);
    assert_eq!(detail.body["location"]["source"], "device");
    assert!(
        detail.body["original"]["location"].is_null(),
        "a guessed place does not become the file's original location"
    );

    // Sync carries `device`, and the screenshot isn't listed as missing a place.
    let synced = api.get("/api/v1/sync?since=0", &token).await;
    let found = synced.body["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == screenshot.as_str())
        .unwrap();
    assert_eq!(found["location"]["source"], "device");
    let missing = api.get("/api/v1/assets/without-location", &token).await;
    assert!(missing.body["assets"].as_array().unwrap().is_empty());

    // An estimated (`device`) location is not used as a suggestion for another unlocated photo.
    let unlocated = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &unlocated,
        &random_bytes(121),
        "image/png",
        taken(at + 5 * MINUTE_MS, None),
    )
    .await;
    let suggestion = api
        .get(
            &format!("/api/v1/assets/{unlocated}/location-suggestion"),
            &token,
        )
        .await;
    assert!(suggestion.body["suggestion"].is_null());

    // `PATCH` and `POST /assets/location` accept `source: "device"` too, and reject unknown ones.
    let patched = api
        .call(
            Method::PATCH,
            &format!("/api/v1/assets/{unlocated}"),
            Some(&token),
            Some(json!({ "location": { "latitude": 48.13, "longitude": 11.57, "source": "device" } })),
        )
        .await;
    assert_eq!(patched.status, 200, "{}", patched.body);
    assert_eq!(patched.body["location"]["source"], "device");

    let bad_patch = api
        .call(
            Method::PATCH,
            &format!("/api/v1/assets/{unlocated}"),
            Some(&token),
            Some(
                json!({ "location": { "latitude": 48.13, "longitude": 11.57, "source": "bogus" } }),
            ),
        )
        .await;
    assert_eq!(
        (bad_patch.status, bad_patch.error()),
        (422, "validation_failed")
    );

    // Unknown source on upload is rejected.
    let bad_upload = api
        .post(
            "/api/v1/uploads",
            Some(&token),
            json!({
                "assetId": Uuid::new_v4(),
                "size": 10,
                "sha256": sha_hex(&[0u8; 10]),
                "mimeType": "image/png",
                "metadata": { "location": { "latitude": 50.0, "longitude": 9.0, "source": "bogus" } }
            }),
        )
        .await;
    assert_eq!(
        (bad_upload.status, bad_upload.error()),
        (422, "validation_failed")
    );

    // Restoring the location removes the guessed place because there was no original GPS.
    let restored = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "restore": ["location"] })),
        )
        .await;
    assert!(restored.body["location"].is_null());
    api.stop().await;
}

#[tokio::test]
async fn the_server_makes_thumbnails_the_phone_did_not_send() {
    let api = Api::start_with(|config| config.jobs.thumbnail_delay_minutes = 0).await;
    let token = owner(&api).await;
    let photo = Uuid::new_v4().to_string();
    api.upload(&token, &photo, &gradient_jpeg(), "image/jpeg", json!({}))
        .await;
    let asset = wait_for_files(&api, &token, &photo, &["thumbnail", "preview"]).await;
    let files = asset["files"].as_array().unwrap();
    let thumbnail = files.iter().find(|f| f["role"] == "thumbnail").unwrap();
    assert_eq!(
        (thumbnail["width"].clone(), thumbnail["height"].clone()),
        (json!(512), json!(384))
    );
    let preview = files.iter().find(|f| f["role"] == "preview").unwrap();
    assert_eq!(preview["width"], 1600, "never enlarged");
    let bytes = api
        .http
        .get(api.url(&format!(
            "/api/v1/files/{}",
            thumbnail["sha256"].as_str().unwrap()
        )))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert_eq!(image::load_from_memory(&bytes).unwrap().width(), 512);

    if tool("ffmpeg") {
        let dir = tempfile::tempdir().unwrap();
        let clip = dir.path().join("clip.mp4");
        let made = std::process::Command::new("ffmpeg")
            .args([
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc=duration=2:size=640x360:rate=25",
                "-c:v",
                "mpeg4",
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
            "video/mp4",
            json!({}),
        )
        .await;
        let asset = wait_for_files(&api, &token, &video, &["thumbnail", "preview"]).await;
        let thumbnail = asset["files"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["role"] == "thumbnail")
            .unwrap()
            .clone();
        assert_eq!(
            (thumbnail["width"].clone(), thumbnail["height"].clone()),
            (json!(512), json!(288))
        );
    }

    if tool("heif-enc") {
        let dir = tempfile::tempdir().unwrap();
        let jpeg = dir.path().join("in.jpg");
        let heic = dir.path().join("out.heic");
        std::fs::write(&jpeg, gradient_jpeg()).unwrap();
        let made = std::process::Command::new("heif-enc")
            .arg(&jpeg)
            .arg("-o")
            .arg(&heic)
            .status()
            .unwrap();
        assert!(made.success());
        let photo = Uuid::new_v4().to_string();
        api.upload(
            &token,
            &photo,
            &std::fs::read(&heic).unwrap(),
            "image/heic",
            json!({}),
        )
        .await;
        wait_for_files(&api, &token, &photo, &["thumbnail", "preview"]).await;
    }
    api.stop().await;
}

#[tokio::test]
async fn thumbnails_from_the_phone_are_never_replaced() {
    let api = Api::start_with(|config| config.jobs.thumbnail_delay_minutes = 60).await;
    let token = owner(&api).await;
    let id = Uuid::new_v4().to_string();
    api.upload(&token, &id, &gradient_jpeg(), "image/jpeg", json!({}))
        .await;
    let own = random_bytes(10_000);
    api.put_derived(&token, &id, "thumbnail", &own).await;

    // Make the queued job due now and let it run: it only adds the missing preview.
    let pool = api.pool().await;
    sqlx::query("UPDATE jobs SET run_after = 0")
        .execute(pool.write())
        .await
        .unwrap();
    pool.close().await;
    // Any finished upload wakes the workers.
    api.upload(
        &token,
        &Uuid::new_v4().to_string(),
        &random_bytes(50),
        "image/heic",
        json!({}),
    )
    .await;
    let asset = wait_for_files(&api, &token, &id, &["thumbnail", "preview"]).await;
    let thumbnail = asset["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["role"] == "thumbnail")
        .unwrap()
        .clone();
    assert_eq!(thumbnail["sha256"], sha_hex(&own).as_str());
    api.stop().await;
}

/// Photos shot together in a burst carry a shared `burstId` through `GET /assets/{id}` and
/// `/sync`; videos ignore `burstId`, and overly long ids are refused.
#[tokio::test]
async fn burst_photos_keep_their_burst_id_and_sync() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let burst_id = Uuid::new_v4().to_string();
    let first = Uuid::new_v4().to_string();
    let second = Uuid::new_v4().to_string();
    let video = Uuid::new_v4().to_string();

    api.upload(
        &token,
        &first,
        &random_bytes(111),
        "image/heic",
        json!({ "takenAt": 1_795_443_730_000_i64, "burstId": burst_id }),
    )
    .await;
    api.upload(
        &token,
        &second,
        &random_bytes(112),
        "image/heic",
        json!({ "takenAt": 1_795_443_730_200_i64, "burstId": burst_id }),
    )
    .await;
    api.upload(
        &token,
        &video,
        &random_bytes(113),
        "video/quicktime",
        json!({ "takenAt": 1_795_443_731_000_i64, "burstId": burst_id }),
    )
    .await;

    let detail = api.get(&format!("/api/v1/assets/{first}"), &token).await;
    assert_eq!(detail.status, 200, "{}", detail.body);
    assert_eq!(detail.body["burstId"], burst_id.as_str());

    let synced = api.get("/api/v1/sync?since=0", &token).await;
    let assets = synced.body["assets"].as_array().unwrap();
    let a1 = assets.iter().find(|a| a["id"] == first.as_str()).unwrap();
    let a2 = assets.iter().find(|a| a["id"] == second.as_str()).unwrap();
    let v1 = assets.iter().find(|a| a["id"] == video.as_str()).unwrap();
    assert_eq!(a1["burstId"], burst_id.as_str());
    assert_eq!(a2["burstId"], burst_id.as_str());
    assert!(
        v1["burstId"].is_null(),
        "videos do not store a photo burst id"
    );

    // Overly long burstId is rejected when announcing the upload.
    let too_long = "b".repeat(65);
    let data = random_bytes(64);
    let refused = api
        .post(
            "/api/v1/uploads",
            Some(&token),
            json!({
                "assetId": Uuid::new_v4().to_string(),
                "role": "original",
                "size": data.len(),
                "sha256": sha_hex(&data),
                "mimeType": "image/heic",
                "metadata": { "burstId": too_long }
            }),
        )
        .await;
    assert_eq!(refused.status, 422, "{}", refused.body);
    api.stop().await;
}

/// Edit recipe version 2 carries photographic `style` and `filter`, records history, syncs to
/// other devices, and rejects malformed look payloads.
#[tokio::test]
async fn edit_recipe_v2_style_and_filter_sync_and_keep_history() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let photo = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &photo,
        &random_bytes(128),
        "image/heic",
        json!({ "takenAt": 1_795_443_730_000_i64 }),
    )
    .await;

    let path = format!("/api/v1/assets/{photo}");
    let v2 = json!({
        "version": 2,
        "style": { "preset": "amber", "tone": 0.25, "color": 0.4, "palette": 0.7 },
        "filter": "vividWarm"
    });
    let saved = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "edit": v2 })),
        )
        .await;
    assert_eq!(saved.status, 200, "{}", saved.body);
    assert_eq!(saved.body["edit"], v2);

    // Sync carries the v2 edit with style and filter intact.
    let synced = api.get("/api/v1/sync?since=0", &token).await;
    let found = synced.body["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == photo.as_str())
        .unwrap();
    assert_eq!(found["edit"]["version"], 2);
    assert_eq!(found["edit"]["style"]["preset"], "amber");
    assert_eq!(found["edit"]["filter"], "vividWarm");

    // Changing style/filter appends to edit history.
    let updated = json!({
        "version": 2,
        "style": { "preset": "starkBW", "tone": -0.3, "color": 0.0, "palette": 0.8 },
        "filter": "noir"
    });
    let res = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "edit": updated })),
        )
        .await;
    assert_eq!(res.status, 200, "{}", res.body);
    let detail = api.get(&path, &token).await;
    let edits = detail.body["edits"].as_array().unwrap();
    assert_eq!(edits.len(), 2);
    assert_eq!(edits[1]["old"], v2);
    assert_eq!(edits[1]["new"], updated);

    // Malformed style or filter values are rejected with 422.
    for bad in [
        json!({ "version": 2, "style": { "preset": "" } }),
        json!({ "version": 2, "style": { "preset": "amber", "tone": 2.5 } }),
        json!({ "version": 2, "style": { "preset": "amber", "palette": -0.2 } }),
        json!({ "version": 2, "filter": 42 }),
        json!({ "version": 2, "filter": "" }),
    ] {
        let refused = api
            .call(
                Method::PATCH,
                &path,
                Some(&token),
                Some(json!({ "edit": bad })),
            )
            .await;
        assert_eq!(
            refused.status, 422,
            "expected 422 for {bad}: {}",
            refused.body
        );
    }
    api.stop().await;
}

/// Cinematic video captureMode is accepted on videos, carried through sync, and ignored on photos.
#[tokio::test]
async fn cinematic_capture_mode_is_kept_on_videos_and_synced() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let video = Uuid::new_v4().to_string();
    let mut meta = taken(1_795_443_730_000, None);
    meta["captureMode"] = json!("cinematic");
    api.upload(
        &token,
        &video,
        &random_bytes(512),
        "video/quicktime",
        meta.clone(),
    )
    .await;

    let photo = Uuid::new_v4().to_string();
    api.upload(&token, &photo, &random_bytes(256), "image/heic", meta)
        .await;

    let got = api.get(&format!("/api/v1/assets/{video}"), &token).await;
    assert_eq!(got.status, 200);
    assert_eq!(got.body["captureMode"], "cinematic");

    let synced = api.get("/api/v1/sync?since=0", &token).await;
    let found = synced.body["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == video.as_str())
        .unwrap();
    assert_eq!(found["captureMode"], "cinematic");

    let photo_got = api.get(&format!("/api/v1/assets/{photo}"), &token).await;
    assert_eq!(photo_got.body["captureMode"], Value::Null);
    api.stop().await;
}

/// Live Photo effects store `liveEffect` / `liveKeyFrameMs` in the edit recipe and upload,
/// replace, sync and delete rendered files under the `live_effect` derived role.
#[tokio::test]
async fn live_photo_effect_derived_file_uploads_replaces_deletes_and_syncs() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let photo = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &photo,
        &random_bytes(256),
        "image/heic",
        json!({ "takenAt": 1_795_443_730_000_i64 }),
    )
    .await;

    let path = format!("/api/v1/assets/{photo}");
    let effect_url = format!("{path}/files/live_effect");

    // Upload a rendered Loop MP4 under role `live_effect`.
    let loop_mp4 = random_bytes(1024);
    let put_loop = api
        .http
        .put(api.url(&effect_url))
        .bearer_auth(&token)
        .header("content-type", "video/mp4")
        .header("halden-sha256", sha_hex(&loop_mp4))
        .header("halden-width", "1080")
        .header("halden-height", "1440")
        .body(loop_mp4.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(put_loop.status(), 200);
    let body: Value = put_loop.json().await.unwrap();
    let effect_file = body["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["role"] == "live_effect")
        .expect("live_effect file listed");
    assert_eq!(effect_file["sha256"], sha_hex(&loop_mp4).as_str());
    assert_eq!(effect_file["mimeType"], "video/mp4");

    // Store non-destructive edit with `liveEffect` and `liveKeyFrameMs`.
    let edit_resp = api
        .call(
            Method::PATCH,
            &path,
            Some(&token),
            Some(json!({ "edit": { "version": 2, "liveEffect": "loop", "liveKeyFrameMs": 650 } })),
        )
        .await;
    assert_eq!(edit_resp.status, 200, "{}", edit_resp.body);
    assert_eq!(edit_resp.body["edit"]["liveEffect"], "loop");
    assert_eq!(edit_resp.body["edit"]["liveKeyFrameMs"], 650);

    // Replace with a Long Exposure HEIC still: previous derived hash is replaced and cleaned up.
    let long_exp = random_bytes(768);
    let put_long = api
        .http
        .put(api.url(&effect_url))
        .bearer_auth(&token)
        .header("content-type", "image/heic")
        .header("halden-sha256", sha_hex(&long_exp))
        .body(long_exp.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(put_long.status(), 200);
    let fetched = api
        .http
        .get(api.url(&effect_url))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(fetched.status(), 200);
    assert_eq!(fetched.bytes().await.unwrap().as_ref(), long_exp.as_slice());

    // Sync carries the live_effect file and edit fields.
    let synced = api.get("/api/v1/sync?since=0", &token).await;
    let synced_asset = synced.body["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == photo.as_str())
        .unwrap();
    assert!(
        synced_asset["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["role"] == "live_effect" && f["sha256"] == sha_hex(&long_exp).as_str())
    );

    // Invalid liveEffect / liveKeyFrameMs values are rejected with 422.
    for bad in [
        json!({ "version": 2, "liveEffect": "spin" }),
        json!({ "version": 2, "liveKeyFrameMs": -1 }),
        json!({ "version": 2, "liveKeyFrameMs": 999_999 }),
    ] {
        let refused = api
            .call(
                Method::PATCH,
                &path,
                Some(&token),
                Some(json!({ "edit": bad })),
            )
            .await;
        assert_eq!(refused.status, 422, "expected 422 for {bad}");
    }

    // Deleting `live_effect` removes the derived file; deleting `thumbnail` is refused.
    let del_thumb = api
        .call(
            Method::DELETE,
            &format!("{path}/files/thumbnail"),
            Some(&token),
            None,
        )
        .await;
    assert_eq!(del_thumb.status, 422);

    let del_effect = api
        .call(Method::DELETE, &effect_url, Some(&token), None)
        .await;
    assert_eq!(del_effect.status, 200, "{}", del_effect.body);
    assert!(
        !del_effect.body["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["role"] == "live_effect")
    );
    api.stop().await;
}
