//! Uploads against the real server over pinned TLS 1.3: in pieces, resumed after a broken
//! connection, checked by SHA-256, placed in readable folders, and never duplicated.

mod common;

use std::path::Path;

use bytes::Bytes;
use common::{ANNA_PASSWORD, Api, LUCAS_PASSWORD, Reply, device, iphone};
use futures_util::StreamExt;
use halden::accounts::Role;
use reqwest::Method;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const MIB: usize = 1024 * 1024;

fn sha_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

fn random_bytes(len: usize) -> Vec<u8> {
    let mut data = vec![0u8; len];
    rand::fill(data.as_mut_slice());
    data
}

/// 23 November 2026, 15:22:10 in Berlin (UTC+1).
fn berlin_afternoon() -> Value {
    let taken = chrono::DateTime::parse_from_rfc3339("2026-11-23T15:22:10+01:00").unwrap();
    json!({
        "takenAt": taken.timestamp_millis(),
        "timeZoneOffsetMinutes": 60,
        "timeZone": "Europe/Berlin",
        "location": {
            "latitude": 50.5558, "longitude": 9.6808, "altitude": 261.0,
            "horizontalAccuracy": 4.5, "heading": 271.5
        },
        "originalFilename": "IMG_0001.HEIC"
    })
}

async fn announce(
    api: &Api,
    token: &str,
    asset_id: &str,
    data: &[u8],
    mime: &str,
    metadata: Value,
) -> Reply {
    api.post(
        "/api/v1/uploads",
        Some(token),
        json!({
            "assetId": asset_id,
            "size": data.len(),
            "sha256": sha_hex(data),
            "mimeType": mime,
            "metadata": metadata,
        }),
    )
    .await
}

async fn send(api: &Api, token: &str, upload_id: &str, offset: usize, chunk: Vec<u8>) -> Reply {
    let response = api
        .http
        .request(
            Method::PATCH,
            api.url(&format!("/api/v1/uploads/{upload_id}")),
        )
        .bearer_auth(token)
        .header("upload-offset", offset.to_string())
        .header("content-type", "application/offset+octet-stream")
        .body(chunk)
        .send()
        .await
        .unwrap();
    Api::reply(response).await
}

/// Announces and sends a file in one piece; returns the asset.
async fn upload(api: &Api, token: &str, asset_id: &str, data: &[u8], metadata: Value) -> Value {
    let created = announce(api, token, asset_id, data, "image/heic", metadata).await;
    assert_eq!(created.status, 201, "{}", created.body);
    let id = created.body["uploadId"].as_str().unwrap();
    let done = send(api, token, id, 0, data.to_vec()).await;
    assert_eq!(done.status, 200, "{}", done.body);
    assert_eq!(done.body["state"], "completed", "{}", done.body);
    done.body["asset"].clone()
}

fn library_file(api: &Api, relative: &str) -> std::path::PathBuf {
    api.config.storage.library_dir.join(relative)
}

fn incoming_is_empty(api: &Api) -> bool {
    std::fs::read_dir(api.config.incoming_dir())
        .unwrap()
        .next()
        .is_none()
}

#[tokio::test]
async fn an_upload_in_pieces_lands_in_a_readable_folder() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let data = random_bytes(3 * MIB + 123);
    let asset_id = Uuid::new_v4().to_string();

    let created = announce(
        &api,
        &token,
        &asset_id,
        &data,
        "image/heic",
        berlin_afternoon(),
    )
    .await;
    assert_eq!(created.status, 201, "{}", created.body);
    assert_eq!(created.body["state"], "receiving");
    assert_eq!(created.body["offset"], 0);
    let upload_id = created.body["uploadId"].as_str().unwrap().to_string();

    let first = send(&api, &token, &upload_id, 0, data[..MIB].to_vec()).await;
    assert_eq!(first.status, 200, "{}", first.body);
    assert_eq!(first.body["offset"], MIB);
    assert_eq!(first.headers["upload-offset"], MIB.to_string().as_str());

    // Sending from the wrong place is refused and says where to continue.
    let wrong = send(&api, &token, &upload_id, 0, data[..10].to_vec()).await;
    assert_eq!((wrong.status, wrong.error()), (409, "offset_mismatch"));
    assert_eq!(wrong.body["offset"], MIB);

    let status = api
        .get(&format!("/api/v1/uploads/{upload_id}"), &token)
        .await;
    assert_eq!(status.body["offset"], MIB);
    let head = api
        .http
        .head(api.url(&format!("/api/v1/uploads/{upload_id}")))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(head.headers()["upload-offset"], MIB.to_string().as_str());
    assert_eq!(
        head.headers()["upload-length"],
        data.len().to_string().as_str()
    );

    let done = send(&api, &token, &upload_id, MIB, data[MIB..].to_vec()).await;
    assert_eq!(done.status, 200, "{}", done.body);
    assert_eq!(done.body["state"], "completed");
    let asset = &done.body["asset"];
    assert_eq!(asset["id"], asset_id.as_str());
    assert_eq!(asset["kind"], "photo");
    assert_eq!(asset["takenAtSource"], "client");
    assert_eq!(asset["timeZoneOffsetMinutes"], 60);
    assert_eq!(asset["location"]["source"], "client");
    assert_eq!(asset["location"]["accuracyMeters"], 4.5);
    assert_eq!(asset["location"]["heading"], 271.5);
    assert_eq!(asset["files"][0]["role"], "original");
    assert_eq!(asset["files"][0]["sha256"], sha_hex(&data).as_str());
    assert!(asset["seq"].as_i64().unwrap() > 0);

    // Byte for byte in a folder a person can read, nothing left in the incoming folder.
    let stored = library_file(&api, "lucas/2026/11/2026-11-23_15-22-10.heic");
    assert_eq!(std::fs::read(&stored).unwrap(), data);
    assert!(incoming_is_empty(&api));

    // Asking again, announcing again, or sending the last piece again: all say "completed".
    let again = api
        .get(&format!("/api/v1/uploads/{upload_id}"), &token)
        .await;
    assert_eq!(again.body["state"], "completed");
    let reannounced = announce(&api, &token, &asset_id, &data, "image/heic", json!({})).await;
    assert_eq!(
        (reannounced.status, &reannounced.body["state"]),
        (200, &json!("completed"))
    );
    let resent = send(&api, &token, &upload_id, MIB, data[MIB..].to_vec()).await;
    assert_eq!(resent.body["state"], "completed");
    let completed = api
        .post(
            &format!("/api/v1/uploads/{upload_id}/complete"),
            Some(&token),
            json!({}),
        )
        .await;
    assert_eq!(completed.body["state"], "completed");

    // The same content under another id is a duplicate; nothing is stored twice.
    let duplicate = announce(
        &api,
        &token,
        &Uuid::new_v4().to_string(),
        &data,
        "image/heic",
        json!({}),
    )
    .await;
    assert_eq!(duplicate.body["state"], "duplicate");
    assert_eq!(duplicate.body["existingAssetId"], asset_id.as_str());
    // The same id with other content is a conflict.
    let other = random_bytes(1000);
    let conflict = announce(&api, &token, &asset_id, &other, "image/heic", json!({})).await;
    assert_eq!((conflict.status, conflict.error()), (409, "conflict"));

    // Another photo from the same second gets a number instead of overwriting.
    let second = upload(
        &api,
        &token,
        &Uuid::new_v4().to_string(),
        &other,
        berlin_afternoon(),
    )
    .await;
    assert_eq!(second["files"][0]["size"], 1000);
    assert_eq!(
        std::fs::read(library_file(
            &api,
            "lucas/2026/11/2026-11-23_15-22-10_2.heic"
        ))
        .unwrap(),
        other
    );

    let fetched = api.get(&format!("/api/v1/assets/{asset_id}"), &token).await;
    assert_eq!(fetched.body["id"], asset_id.as_str());
    api.stop().await;
}

#[tokio::test]
async fn a_wrong_checksum_is_refused_and_nothing_is_kept() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let announced = random_bytes(2 * MIB);
    let created = announce(
        &api,
        &token,
        &Uuid::new_v4().to_string(),
        &announced,
        "video/quicktime",
        json!({}),
    )
    .await;
    let upload_id = created.body["uploadId"].as_str().unwrap().to_string();

    let mut damaged = announced.clone();
    damaged[MIB] ^= 0xff;
    let reply = send(&api, &token, &upload_id, 0, damaged).await;
    assert_eq!((reply.status, reply.error()), (422, "checksum_mismatch"));
    let status = api
        .get(&format!("/api/v1/uploads/{upload_id}"), &token)
        .await;
    assert_eq!((status.status, status.error()), (410, "upload_failed"));
    assert!(incoming_is_empty(&api));
    assert!(!api.config.storage.library_dir.join("lucas").exists());
    api.stop().await;
}

#[tokio::test]
async fn a_broken_connection_continues_where_it_stopped() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let data = random_bytes(4 * MIB);
    let asset_id = Uuid::new_v4().to_string();
    let created = announce(&api, &token, &asset_id, &data, "video/mp4", json!({})).await;
    let upload_id = created.body["uploadId"].as_str().unwrap().to_string();

    // The phone loses Wi-Fi after 1.5 MiB. (The break comes a moment after the data: bytes
    // still sitting in HTTP/2 buffers when a stream is reset are dropped, and the phone simply
    // sends them again from the offset the server reports.)
    let sent = futures_util::stream::iter(vec![
        Ok::<_, std::io::Error>(Bytes::copy_from_slice(&data[..MIB])),
        Ok(Bytes::copy_from_slice(&data[MIB..MIB + MIB / 2])),
    ])
    .chain(futures_util::stream::once(async {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        Err(std::io::Error::other("Wi-Fi gone"))
    }));
    let broken = api
        .http
        .patch(api.url(&format!("/api/v1/uploads/{upload_id}")))
        .bearer_auth(&token)
        .header("upload-offset", "0")
        .body(reqwest::Body::wrap_stream(sent))
        .send()
        .await;
    assert!(broken.is_err() || broken.unwrap().status() != 200);

    // The server kept what arrived; the phone asks where to go on.
    let mut offset = 0;
    for _ in 0..50 {
        let status = api
            .get(&format!("/api/v1/uploads/{upload_id}"), &token)
            .await;
        offset = status.body["offset"].as_u64().unwrap() as usize;
        if offset > 0 && status.status == 200 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(offset, MIB + MIB / 2);

    let done = send(&api, &token, &upload_id, offset, data[offset..].to_vec()).await;
    assert_eq!(done.body["state"], "completed", "{}", done.body);
    let stored = find_original(&api.config.storage.library_dir.join("lucas"));
    assert_eq!(std::fs::read(stored).unwrap(), data);
    assert_eq!(done.body["asset"]["kind"], "video");
    assert_eq!(done.body["asset"]["takenAtSource"], "upload");
    api.stop().await;
}

/// The only file below `folder`.
fn find_original(folder: &Path) -> std::path::PathBuf {
    let mut stack = vec![folder.to_path_buf()];
    let mut found = Vec::new();
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(dir).unwrap().flatten() {
            if entry.file_type().unwrap().is_dir() {
                stack.push(entry.path());
            } else {
                found.push(entry.path());
            }
        }
    }
    assert_eq!(found.len(), 1, "{found:?}");
    found.remove(0)
}

#[tokio::test]
async fn a_full_disk_is_reported_before_anything_is_sent() {
    let api = Api::start_with(|config| config.storage.min_free_gb = 1_000_000_000).await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let reply = announce(
        &api,
        &token,
        &Uuid::new_v4().to_string(),
        b"tiny",
        "image/jpeg",
        json!({}),
    )
    .await;
    assert_eq!((reply.status, reply.error()), (507, "insufficient_storage"));
    api.stop().await;
}

#[tokio::test]
async fn announcements_are_checked() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let id = Uuid::new_v4().to_string();
    let base = json!({ "assetId": id, "size": 10, "sha256": sha_hex(b"0123456789"), "mimeType": "image/jpeg" });

    let mut script = base.clone();
    script["mimeType"] = json!("application/x-sh");
    let reply = api.post("/api/v1/uploads", Some(&token), script).await;
    assert_eq!(
        (reply.status, reply.error()),
        (415, "unsupported_media_type")
    );

    for (key, value) in [
        ("assetId", json!("../../etc/passwd")),
        ("sha256", json!("abc")),
        ("size", json!(0)),
    ] {
        let mut bad = base.clone();
        bad[key] = value;
        let reply = api.post("/api/v1/uploads", Some(&token), bad).await;
        assert_eq!(reply.error(), "validation_failed", "{key}");
    }
    let mut far = base.clone();
    far["metadata"] = json!({ "location": { "latitude": 123.0, "longitude": 0.0 } });
    let reply = api.post("/api/v1/uploads", Some(&token), far).await;
    assert_eq!(reply.error(), "validation_failed");

    // A Live Photo's video can't come before its photo.
    let mut early = base.clone();
    early["role"] = json!("paired_video");
    early["mimeType"] = json!("video/quicktime");
    let reply = api.post("/api/v1/uploads", Some(&token), early).await;
    assert_eq!(reply.error(), "conflict");

    let missing = send(&api, &token, &Uuid::new_v4().to_string(), 0, vec![1, 2, 3]).await;
    assert_eq!(missing.status, 404);
    api.stop().await;
}

#[tokio::test]
async fn other_accounts_see_nothing() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let lucas = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;
    let data = random_bytes(1000);
    let asset_id = Uuid::new_v4().to_string();
    let pending = announce(
        &api,
        &lucas,
        &Uuid::new_v4().to_string(),
        &random_bytes(10),
        "image/jpeg",
        json!({}),
    )
    .await;
    let pending_id = pending.body["uploadId"].as_str().unwrap();
    upload(&api, &lucas, &asset_id, &data, json!({})).await;

    assert_eq!(
        api.get(&format!("/api/v1/uploads/{pending_id}"), &anna)
            .await
            .status,
        404
    );
    assert_eq!(
        send(&api, &anna, pending_id, 0, vec![0; 10]).await.status,
        404
    );
    assert_eq!(
        api.get(&format!("/api/v1/assets/{asset_id}"), &anna)
            .await
            .status,
        404
    );
    let taken = announce(&api, &anna, &asset_id, &data, "image/heic", json!({})).await;
    assert_eq!(taken.error(), "conflict");
    // Anna's copy of the same photo is hers: no "duplicate" across accounts.
    let own = announce(
        &api,
        &anna,
        &Uuid::new_v4().to_string(),
        &data,
        "image/heic",
        json!({}),
    )
    .await;
    assert_eq!(own.body["state"], "receiving");
    api.stop().await;
}

#[tokio::test]
async fn many_hashes_are_checked_at_once() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let data = random_bytes(5000);
    let asset_id = Uuid::new_v4().to_string();
    upload(&api, &token, &asset_id, &data, json!({})).await;

    let other_id = Uuid::new_v4().to_string();
    let missing_id = Uuid::new_v4().to_string();
    let reply = api
        .post(
            "/api/v1/assets/check",
            Some(&token),
            json!({ "items": [
                { "assetId": asset_id, "sha256": sha_hex(&data) },
                { "assetId": other_id, "sha256": sha_hex(&data) },
                { "assetId": missing_id, "sha256": sha_hex(b"other") },
                { "assetId": asset_id, "sha256": sha_hex(b"changed") },
            ]}),
        )
        .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let results = reply.body["results"].as_array().unwrap();
    assert_eq!(results[0]["status"], "backedUp");
    assert_eq!(results[1]["status"], "duplicate");
    assert_eq!(results[1]["existingAssetId"], asset_id.as_str());
    assert_eq!(results[2]["status"], "missing");
    assert_eq!(results[3]["status"], "conflict");
    api.stop().await;
}

#[tokio::test]
async fn thumbnails_go_up_in_one_request() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let asset_id = Uuid::new_v4().to_string();
    upload(&api, &token, &asset_id, &random_bytes(2000), json!({})).await;
    let thumbnail = random_bytes(30_000);
    let put = |token: String, role: &str, mime: &str, sha: String, body: Vec<u8>| {
        api.http
            .put(api.url(&format!("/api/v1/assets/{asset_id}/files/{role}")))
            .bearer_auth(token)
            .header("content-type", mime)
            .header("halden-sha256", sha)
            .header("halden-width", "512")
            .header("halden-height", "384")
            .body(body)
            .send()
    };

    let reply = Api::reply(
        put(
            token.clone(),
            "thumbnail",
            "image/jpeg",
            sha_hex(&thumbnail),
            thumbnail.clone(),
        )
        .await
        .unwrap(),
    )
    .await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let files = reply.body["files"].as_array().unwrap();
    let thumb = files.iter().find(|f| f["role"] == "thumbnail").unwrap();
    assert_eq!(
        (thumb["width"].clone(), thumb["height"].clone()),
        (json!(512), json!(384))
    );
    let hash = sha_hex(&thumbnail);
    let stored = api
        .config
        .derived_dir()
        .join(&hash[..2])
        .join(&hash[2..4])
        .join(format!("{hash}.jpg"));
    assert_eq!(std::fs::read(stored).unwrap(), thumbnail);

    let wrong = Api::reply(
        put(
            token.clone(),
            "thumbnail",
            "image/jpeg",
            sha_hex(b"x"),
            thumbnail.clone(),
        )
        .await
        .unwrap(),
    )
    .await;
    assert_eq!(wrong.error(), "checksum_mismatch");
    let original = Api::reply(
        put(
            token.clone(),
            "original",
            "image/jpeg",
            hash.clone(),
            thumbnail.clone(),
        )
        .await
        .unwrap(),
    )
    .await;
    assert_eq!(original.error(), "validation_failed");
    let video = Api::reply(
        put(
            token.clone(),
            "preview",
            "video/mp4",
            hash.clone(),
            thumbnail.clone(),
        )
        .await
        .unwrap(),
    )
    .await;
    assert_eq!(video.error(), "unsupported_media_type");
    let too_big = random_bytes(9 * MIB);
    let big = Api::reply(
        put(
            token.clone(),
            "preview",
            "image/jpeg",
            sha_hex(&too_big),
            too_big,
        )
        .await
        .unwrap(),
    )
    .await;
    assert_eq!(big.error(), "too_large");

    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;
    let foreign = Api::reply(
        put(anna, "thumbnail", "image/jpeg", hash, thumbnail)
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(foreign.status, 404);
    api.stop().await;
}

/// A tiny JPEG whose EXIF says: Apple iPhone 15, taken 23.11.2026 15:22:10 at UTC+1, at
/// 50°33'20.88" N 9°40'50.88" E, 261 m. Enough for the server's metadata reader.
fn jpeg_with_exif() -> Vec<u8> {
    const ASCII: u16 = 2;
    const LONG: u16 = 4;
    const RATIONAL: u16 = 5;
    const BYTE: u16 = 1;
    type Entry = (u16, u16, u32, Vec<u8>);

    fn ascii(text: &str) -> (u32, Vec<u8>) {
        let mut bytes = text.as_bytes().to_vec();
        bytes.push(0);
        (bytes.len() as u32, bytes)
    }
    fn rationals(values: &[(u32, u32)]) -> Vec<u8> {
        values
            .iter()
            .flat_map(|(n, d)| [n.to_be_bytes(), d.to_be_bytes()].concat())
            .collect()
    }
    fn size(entries: &[Entry]) -> u32 {
        let data: u32 = entries
            .iter()
            .filter(|e| e.3.len() > 4)
            .map(|e| (e.3.len() as u32).next_multiple_of(2))
            .sum();
        2 + 12 * entries.len() as u32 + 4 + data
    }
    fn build(start: u32, entries: &[Entry]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut data = Vec::new();
        let data_start = start + 2 + 12 * entries.len() as u32 + 4;
        out.extend((entries.len() as u16).to_be_bytes());
        for (tag, kind, count, value) in entries {
            out.extend(tag.to_be_bytes());
            out.extend(kind.to_be_bytes());
            out.extend(count.to_be_bytes());
            if value.len() <= 4 {
                let mut inline = value.clone();
                inline.resize(4, 0);
                out.extend(inline);
            } else {
                out.extend((data_start + data.len() as u32).to_be_bytes());
                data.extend(value);
                if data.len() % 2 == 1 {
                    data.push(0);
                }
            }
        }
        out.extend(0u32.to_be_bytes());
        out.extend(data);
        out
    }

    let (make_n, make) = ascii("Apple");
    let (model_n, model) = ascii("iPhone 15");
    let (time_n, time) = ascii("2026:11:23 15:22:10");
    let (offset_n, offset) = ascii("+01:00");
    let ifd0 = |exif: u32, gps: u32| -> Vec<Entry> {
        vec![
            (0x010f, ASCII, make_n, make.clone()),
            (0x0110, ASCII, model_n, model.clone()),
            (0x8769, LONG, 1, exif.to_be_bytes().to_vec()),
            (0x8825, LONG, 1, gps.to_be_bytes().to_vec()),
        ]
    };
    let exif = vec![
        (0x9003, ASCII, time_n, time),
        (0x9011, ASCII, offset_n, offset),
    ];
    let gps = vec![
        (0x0001, ASCII, 2, b"N\0".to_vec()),
        (
            0x0002,
            RATIONAL,
            3,
            rationals(&[(50, 1), (33, 1), (2088, 100)]),
        ),
        (0x0003, ASCII, 2, b"E\0".to_vec()),
        (
            0x0004,
            RATIONAL,
            3,
            rationals(&[(9, 1), (40, 1), (5088, 100)]),
        ),
        (0x0005, BYTE, 1, vec![0]),
        (0x0006, RATIONAL, 1, rationals(&[(261, 1)])),
    ];
    let exif_start = 8 + size(&ifd0(0, 0));
    let gps_start = exif_start + size(&exif);
    let mut tiff = b"MM\0\x2a\0\0\0\x08".to_vec();
    tiff.extend(build(8, &ifd0(exif_start, gps_start)));
    tiff.extend(build(exif_start, &exif));
    tiff.extend(build(gps_start, &gps));

    let mut app1 = b"Exif\0\0".to_vec();
    app1.extend(tiff);
    let mut jpeg = vec![0xff, 0xd8, 0xff, 0xe1];
    jpeg.extend(((app1.len() + 2) as u16).to_be_bytes());
    jpeg.extend(app1);
    // An (empty) image after the metadata, then the end marker.
    jpeg.extend([0xff, 0xda, 0x00, 0x02]);
    jpeg.extend(random_bytes(64));
    jpeg.extend([0xff, 0xd9]);
    jpeg
}

#[tokio::test]
async fn without_phone_metadata_the_file_tells_time_and_place() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let photo = jpeg_with_exif();
    let created = announce(
        &api,
        &token,
        &Uuid::new_v4().to_string(),
        &photo,
        "image/jpeg",
        json!({}),
    )
    .await;
    let done = send(
        &api,
        &token,
        created.body["uploadId"].as_str().unwrap(),
        0,
        photo.clone(),
    )
    .await;
    assert_eq!(done.body["state"], "completed", "{}", done.body);
    let asset = &done.body["asset"];
    assert_eq!(asset["takenAtSource"], "exif");
    assert_eq!(asset["timeZoneOffsetMinutes"], 60);
    let taken = chrono::DateTime::parse_from_rfc3339("2026-11-23T15:22:10+01:00").unwrap();
    assert_eq!(asset["takenAt"], taken.timestamp_millis());
    assert_eq!(asset["camera"]["make"], "Apple");
    assert_eq!(asset["camera"]["model"], "iPhone 15");
    assert_eq!(asset["location"]["source"], "exif");
    let latitude = asset["location"]["latitude"].as_f64().unwrap();
    let longitude = asset["location"]["longitude"].as_f64().unwrap();
    assert!((latitude - 50.5558).abs() < 0.0001, "{latitude}");
    assert!((longitude - 9.6808).abs() < 0.0001, "{longitude}");
    assert_eq!(
        std::fs::read(library_file(&api, "lucas/2026/11/2026-11-23_15-22-10.jpg")).unwrap(),
        photo
    );
    api.stop().await;
}
