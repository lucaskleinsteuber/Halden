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
