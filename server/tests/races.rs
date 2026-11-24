//! Things happening at the same time: the same photo from two phones, and trash, restore and
//! delete-for-good fired at the same photos from several devices at once.

mod common;

use std::collections::BTreeMap;

use common::{Api, LUCAS_PASSWORD, Reply, device, iphone, random_bytes, sha_hex};
use halden::accounts::Role;
use reqwest::Method;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

async fn announce(api: &Api, token: &str, asset: &str, data: &[u8]) -> Reply {
    api.post(
        "/api/v1/uploads",
        Some(token),
        json!({ "assetId": asset, "size": data.len(), "sha256": sha_hex(data),
            "mimeType": "image/heic" }),
    )
    .await
}

async fn send(api: &Api, token: &str, upload: &str, data: Vec<u8>) -> Reply {
    let response = api
        .http
        .request(Method::PATCH, api.url(&format!("/api/v1/uploads/{upload}")))
        .bearer_auth(token)
        .header("upload-offset", "0")
        .header("content-type", "application/offset+octet-stream")
        .body(data)
        .send()
        .await
        .unwrap();
    Api::reply(response).await
}

fn library_originals(api: &Api) -> Vec<std::path::PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![api.config.storage.library_dir.clone()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            if path.file_name().is_some_and(|name| name == ".halden") {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                stack.push(path);
            } else {
                found.push(path);
            }
        }
    }
    found
}

/// Both phones announce before either has finished, so both send everything; the photo is kept
/// once and the second phone learns which asset it is.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_same_photo_from_two_phones_at_once_is_kept_once() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let phone = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let ipad = api
        .token("lucas", LUCAS_PASSWORD, device("iPad", "ipad-0001"))
        .await;
    let data = random_bytes(2_000_000);
    let (a, b) = (Uuid::new_v4().to_string(), Uuid::new_v4().to_string());

    let (first, second) = tokio::join!(
        announce(&api, &phone, &a, &data),
        announce(&api, &ipad, &b, &data)
    );
    assert_eq!((first.status, second.status), (201, 201));
    let upload_a = first.body["uploadId"].as_str().unwrap().to_string();
    let upload_b = second.body["uploadId"].as_str().unwrap().to_string();
    let (done_a, done_b) = tokio::join!(
        send(&api, &phone, &upload_a, data.clone()),
        send(&api, &ipad, &upload_b, data.clone())
    );
    assert_eq!((done_a.status, done_b.status), (200, 200));

    let mut states = [
        (done_a.body["state"].clone(), &a, &upload_a, &phone),
        (done_b.body["state"].clone(), &b, &upload_b, &ipad),
    ];
    states.sort_by_key(|(state, ..)| state.to_string());
    let [
        (stored, kept, _, _),
        (duplicate, dropped, dropped_upload, dropped_token),
    ] = states;
    assert_eq!(
        (stored, duplicate),
        (json!("completed"), json!("duplicate"))
    );
    let answer = if dropped == &a { &done_a } else { &done_b };
    assert_eq!(answer.body["existingAssetId"], kept.as_str());

    // Asked again later, the dropped upload still says where the photo is.
    let later = api
        .get(&format!("/api/v1/uploads/{dropped_upload}"), dropped_token)
        .await;
    assert_eq!(
        (
            later.status,
            &later.body["state"],
            &later.body["existingAssetId"]
        ),
        (200, &json!("duplicate"), &json!(kept))
    );

    // One file, one asset, nothing left in the incoming folder.
    assert_eq!(library_originals(&api).len(), 1);
    let sync = api.get("/api/v1/sync?since=0", &phone).await;
    let ids: Vec<&str> = sync.body["assets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|asset| asset["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![kept.as_str()]);
    assert!(
        std::fs::read_dir(api.config.incoming_dir())
            .unwrap()
            .next()
            .is_none()
    );
    api.stop().await;
}

/// Three devices throw trash, restore and delete-for-good at the same photos at the same time.
/// Afterwards every photo is in exactly one state, its file matches that state, and a device
/// syncing from zero sees exactly that.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn trash_restore_and_delete_at_the_same_time_stay_consistent() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let tokens = [
        api.token("lucas", LUCAS_PASSWORD, iphone()).await,
        api.token("lucas", LUCAS_PASSWORD, device("iPad", "ipad-0001"))
            .await,
        api.token("lucas", LUCAS_PASSWORD, device("Mac", "mac-0001"))
            .await,
    ];
    let mut contents = BTreeMap::new();
    for _ in 0..12 {
        let id = Uuid::new_v4().to_string();
        let data = random_bytes(20_000);
        api.upload(&tokens[0], &id, &data, "image/heic", json!({}))
            .await;
        contents.insert(id, hex::encode(Sha256::digest(&data)));
    }
    let ids: Vec<String> = contents.keys().cloned().collect();

    let mut tasks = tokio::task::JoinSet::new();
    for round in 0..60 {
        let token = tokens[round % tokens.len()].clone();
        let action = ["trash", "restore", "delete"][(round / 3) % 3];
        // Overlapping groups of photos, so the same photo is hit from several sides.
        let group: Vec<String> = ids
            .iter()
            .enumerate()
            .filter(|(i, _)| (i + round) % 3 != 0)
            .map(|(_, id)| id.clone())
            .collect();
        let http = api.http.clone();
        let url = api.url(&format!("/api/v1/assets/{action}"));
        tasks.spawn(async move {
            let response = http
                .post(url)
                .bearer_auth(token)
                .json(&json!({ "ids": group }))
                .send()
                .await
                .unwrap();
            (action, response.status().as_u16())
        });
    }
    while let Some(result) = tasks.join_next().await {
        let (action, status) = result.unwrap();
        assert_eq!(status, 200, "{action}");
    }

    let sync = api.get("/api/v1/sync?since=0", &tokens[2]).await;
    let seen: BTreeMap<String, Value> = sync.body["assets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|asset| (asset["id"].as_str().unwrap().to_string(), asset.clone()))
        .collect();
    let mut files_expected = 0;
    for (id, sha) in &contents {
        let asset = &seen[id];
        let deleted = asset["deletedAt"].is_i64();
        let stored = api.get(&format!("/api/v1/assets/{id}"), &tokens[1]).await;
        assert_eq!(stored.status, 200, "{id}");
        assert_eq!(stored.body["deletedAt"], asset["deletedAt"], "{id}");
        assert_eq!(stored.body["trashedAt"], asset["trashedAt"], "{id}");
        if deleted {
            // Only from the trash: a tombstone remembers when it went there.
            assert!(asset["trashedAt"].is_i64(), "{asset}");
            assert!(
                asset["files"].as_array().is_none_or(Vec::is_empty),
                "{asset}"
            );
            assert!(stored.body["files"].as_array().unwrap().is_empty());
        } else {
            files_expected += 1;
            assert_eq!(stored.status, 200, "{id}");
            let original = stored.body["files"]
                .as_array()
                .unwrap()
                .iter()
                .find(|file| file["role"] == "original")
                .unwrap()
                .clone();
            assert_eq!(original["sha256"], sha.as_str());
            let file = api
                .http
                .get(api.url(&format!("/api/v1/assets/{id}/files/original")))
                .bearer_auth(&tokens[1])
                .send()
                .await
                .unwrap();
            assert_eq!(file.status(), 200);
            let bytes = file.bytes().await.unwrap();
            assert_eq!(hex::encode(Sha256::digest(&bytes)), *sha);
        }
    }
    // Every photo deleted for good has left the disk; every other one is still there.
    assert_eq!(library_originals(&api).len(), files_expected);
    api.stop().await;
}

/// The moment a device restores a photo, another one's delete-for-good (or the automatic emptying
/// of the trash) may already have picked it: it must stay.
#[tokio::test]
async fn a_photo_restored_a_moment_ago_is_not_deleted() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let id = Uuid::new_v4().to_string();
    api.upload(&token, &id, &random_bytes(5000), "image/heic", json!({}))
        .await;
    let derived = api.config.derived_dir();
    let roots = halden::library::trash::Roots {
        library: &api.config.storage.library_dir,
        derived: &derived,
        mirror: None,
    };
    let db = api.pool().await;
    let ids = [id.clone()];

    // Not in the trash (restored meanwhile): nothing happens.
    assert_eq!(
        halden::library::trash::purge(&db, roots, &ids, i64::MAX)
            .await
            .unwrap(),
        0
    );
    assert_eq!(library_originals(&api).len(), 1);
    // Back in the trash, but since after the emptying's cut-off: stays too.
    api.post("/api/v1/assets/trash", Some(&token), json!({ "ids": ids }))
        .await;
    assert_eq!(
        halden::library::trash::purge(&db, roots, &ids, 0)
            .await
            .unwrap(),
        0
    );
    assert_eq!(library_originals(&api).len(), 1);
    // In the trash and meant: gone.
    assert_eq!(
        halden::library::trash::purge(&db, roots, &ids, i64::MAX)
            .await
            .unwrap(),
        1
    );
    assert!(library_originals(&api).is_empty());
    db.close().await;
    api.stop().await;
}
