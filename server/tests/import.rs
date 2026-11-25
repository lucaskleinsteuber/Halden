//! Importing from Google Takeout (folders and ZIP files) and Immich into a running server, like
//! `halden import` does: what Google or Immich knew comes along, duplicates stay single, albums
//! are made, and a second run brings nothing twice.

mod common;

use std::{io::Write, path::Path};

use axum::{Json, Router, routing::get, routing::post};
use common::{Api, LUCAS_PASSWORD, gradient_jpeg, iphone, random_bytes};
use halden::{
    accounts::Role,
    import::{Importer, Outcome, immich::Immich, takeout::Takeout},
};
use serde_json::{Value, json};

fn write(path: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

async fn importer(api: &Api, source: &str) -> Importer {
    let mut config = api.config.clone();
    config.server.port = api.server.addr.port();
    let pool = api.pool().await;
    Importer::connect(&config, &pool, "lucas", source, source, false)
        .await
        .unwrap()
}

async fn assets(api: &Api, token: &str) -> Vec<Value> {
    let page = api.get("/api/v1/sync?since=0", token).await.body;
    page["assets"].as_array().unwrap().clone()
}

async fn album(api: &Api, token: &str, name: &str) -> Value {
    let list = api.get("/api/v1/albums", token).await.body;
    list["albums"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["name"] == name)
        .unwrap_or_else(|| panic!("no album {name}: {list}"))
        .clone()
}

#[tokio::test]
async fn google_takeout_comes_in_once() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let dir = tempfile::tempdir().unwrap();
    let photos = dir.path().join("Takeout/Google Photos");
    let first = gradient_jpeg();
    let mut second = gradient_jpeg();
    second.extend_from_slice(b"another photo");
    let video = random_bytes(5000);
    // A year folder: a photo with what Google knew, and Google's edited copy of it.
    write(&photos.join("Photos from 2021/IMG_1.jpg"), &first);
    write(
        &photos.join("Photos from 2021/IMG_1.jpg.supplemental-metadata.json"),
        json!({ "title": "IMG_1.jpg", "description": "Harbour",
                "photoTakenTime": { "timestamp": "1621234567" },
                "geoData": { "latitude": 41.9, "longitude": 12.5, "altitude": 0.0 } })
        .to_string()
        .as_bytes(),
    );
    write(
        &photos.join("Photos from 2021/IMG_1-edited.jpg"),
        &random_bytes(900),
    );
    // An album: the same photo again, and a Live Photo.
    write(&photos.join("Rome/metadata.json"), br#"{"title": "Rome"}"#);
    write(&photos.join("Rome/IMG_1.jpg"), &first);
    write(&photos.join("Rome/IMG_2.jpg"), &second);
    write(&photos.join("Rome/IMG_2.MP4"), &video);
    // A second part as a ZIP file, with an album of its own.
    let zip_path = dir.path().join("takeout-002.zip");
    {
        let mut zip = zip::ZipWriter::new(std::fs::File::create(&zip_path).unwrap());
        let options = zip::write::SimpleFileOptions::default();
        zip.start_file("Takeout/Google Photos/Paris/metadata.json", options)
            .unwrap();
        zip.write_all(br#"{"title": "Paris"}"#).unwrap();
        let mut third = gradient_jpeg();
        third.extend_from_slice(b"a third photo");
        zip.start_file("Takeout/Google Photos/Paris/IMG_3.jpg", options)
            .unwrap();
        zip.write_all(&third).unwrap();
        zip.finish().unwrap();
    }

    let inputs = [dir.path().join("Takeout"), zip_path];
    let mut takeout = Takeout::open(&inputs).unwrap();
    let items = takeout.items();
    assert_eq!(
        items.len(),
        4,
        "the edited copy and the Live Photo's video don't count"
    );
    let mut import = importer(&api, "takeout").await;
    let mut outcomes = Vec::new();
    for item in &items {
        outcomes.push(import.bring(item, &mut takeout).await.unwrap());
    }
    assert_eq!(outcomes.iter().filter(|o| **o == Outcome::Added).count(), 3);
    assert_eq!(
        outcomes
            .iter()
            .filter(|o| **o == Outcome::AlreadyThere)
            .count(),
        1
    );

    let all = assets(&api, &token).await;
    assert_eq!(all.len(), 3, "the same photo twice is one");
    let harbour = all
        .iter()
        .find(|a| a["description"] == "Harbour")
        .expect("the description came along");
    assert_eq!(
        harbour["takenAt"], 1_621_234_567_000_i64,
        "Google's time, the file had none"
    );
    assert_eq!(harbour["location"]["latitude"], 41.9);
    let live = all
        .iter()
        .find(|a| {
            a["files"]
                .as_array()
                .unwrap()
                .iter()
                .any(|f| f["role"] == "paired_video")
        })
        .expect("the Live Photo kept its video");
    let rome = album(&api, &token, "Rome").await;
    assert_eq!(rome["assetIds"].as_array().unwrap().len(), 2, "{rome}");
    assert!(rome["assetIds"].as_array().unwrap().contains(&live["id"]));
    assert!(
        rome["assetIds"]
            .as_array()
            .unwrap()
            .contains(&harbour["id"])
    );
    assert_eq!(
        album(&api, &token, "Paris").await["assetIds"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let devices = api.get("/api/v1/devices", &token).await.body;
    assert!(
        devices.to_string().contains("Import (takeout)"),
        "the import is a device of its own: {devices}"
    );

    // Again: nothing twice.
    let mut again = importer(&api, "takeout").await;
    for item in &items {
        assert_eq!(
            again.bring(item, &mut takeout).await.unwrap(),
            Outcome::DoneBefore
        );
    }
    assert_eq!(assets(&api, &token).await.len(), 3);
}

#[tokio::test]
async fn immich_comes_in_with_albums_and_favourites() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let photo = gradient_jpeg();
    let video = random_bytes(4000);
    let (photo_bytes, video_bytes) = (photo.clone(), video.clone());
    // A stand-in for Immich's API, with what the import asks.
    let immich = Router::new()
        .route(
            "/api/albums",
            get(|| async { Json(json!([{ "id": "al1", "albumName": "Holiday" }])) }),
        )
        .route(
            "/api/albums/al1",
            get(|| async { Json(json!({ "assets": [{ "id": "a1" }] })) }),
        )
        .route(
            "/api/search/metadata",
            post(|| async {
                Json(json!({ "assets": { "nextPage": null, "items": [
                    { "id": "a1", "type": "IMAGE", "originalFileName": "IMG_7.jpg",
                      "originalMimeType": "image/jpeg", "fileCreatedAt": "2022-05-01T10:00:00.000Z",
                      "isFavorite": true, "isTrashed": false, "livePhotoVideoId": "v1",
                      "exifInfo": { "latitude": 48.1, "longitude": 11.5, "description": "Lake" } },
                    { "id": "v1", "type": "VIDEO", "originalFileName": "IMG_7.MOV",
                      "originalMimeType": "video/quicktime", "isTrashed": false, "exifInfo": {} },
                    { "id": "gone", "type": "IMAGE", "originalFileName": "old.jpg",
                      "originalMimeType": "image/jpeg", "isTrashed": true, "exifInfo": {} }
                ] } }))
            }),
        )
        .route(
            "/api/assets/a1/original",
            get(move || {
                let bytes = photo_bytes.clone();
                async move { bytes }
            }),
        )
        .route(
            "/api/assets/v1/original",
            get(move || {
                let bytes = video_bytes.clone();
                async move { bytes }
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, immich).await.unwrap() });

    let mut source = Immich::new(&format!("http://{address}"), "key").unwrap();
    let items = source.items().await.unwrap();
    assert_eq!(
        items.len(),
        1,
        "the trashed one and the Live Photo's video don't count"
    );
    let mut import = importer(&api, "immich").await;
    assert_eq!(
        import.bring(&items[0], &mut source).await.unwrap(),
        Outcome::Added
    );
    let all = assets(&api, &token).await;
    assert_eq!(all.len(), 1);
    let asset = &all[0];
    assert_eq!(asset["description"], "Lake");
    assert_eq!(asset["location"]["latitude"], 48.1);
    assert!(
        asset["files"]
            .as_array()
            .unwrap()
            .iter()
            .any(|f| f["role"] == "paired_video")
    );
    assert_eq!(
        album(&api, &token, "Holiday").await["assetIds"],
        json!([asset["id"]])
    );
    assert_eq!(
        album(&api, &token, halden::import::immich::FAVOURITES).await["assetIds"],
        json!([asset["id"]])
    );
}
