//! Albums against the real server: making, changing and deleting them, photos going in and out,
//! the sync, the trash, and other accounts.

mod common;

use common::{ANNA_PASSWORD, Api, LUCAS_PASSWORD, device, iphone, random_bytes};
use halden::accounts::Role;
use reqwest::Method;
use serde_json::{Value, json};
use uuid::Uuid;

async fn photo(api: &Api, token: &str) -> String {
    let id = Uuid::new_v4().to_string();
    api.upload(
        token,
        &id,
        &random_bytes(300),
        "image/heic",
        json!({ "takenAt": 1_795_443_730_000_i64 }),
    )
    .await;
    id
}

/// Every album change from `since` on, page by page.
async fn synced_albums(api: &Api, token: &str, since: i64, limit: u32) -> (Vec<Value>, i64) {
    let mut since = since;
    let mut albums = Vec::new();
    loop {
        let page = api
            .get(&format!("/api/v1/sync?since={since}&limit={limit}"), token)
            .await
            .body;
        albums.extend(page["albums"].as_array().unwrap().iter().cloned());
        since = page["nextSince"].as_i64().unwrap();
        if page["hasMore"] != true {
            return (albums, since);
        }
    }
}

#[tokio::test]
async fn albums_hold_photos_and_reach_every_device() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let lucas = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna"),
        )
        .await;
    let (a, b, c) = (
        photo(&api, &lucas).await,
        photo(&api, &lucas).await,
        photo(&api, &lucas).await,
    );
    let annas = photo(&api, &anna).await;

    // Made with an id from the phone; photos of other accounts and nonsense are left out.
    let id = Uuid::new_v4().to_string();
    let body = json!({ "id": id, "name": "  Rome  ", "assetIds": [a, b, annas, "nonsense"] });
    let made = api.post("/api/v1/albums", Some(&lucas), body.clone()).await;
    assert_eq!(made.status, 201, "{}", made.body);
    assert_eq!(made.body["name"], "Rome");
    let members: Vec<&str> = made.body["assetIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(members.len(), 2);
    assert!(members.contains(&a.as_str()) && members.contains(&b.as_str()));
    // Sent again after a lost answer: the same album.
    let again = api.post("/api/v1/albums", Some(&lucas), body).await;
    assert_eq!((again.status, again.body["id"].clone()), (200, json!(id)));
    // The id is Lucas's; Anna can't take it, nor see or change the album.
    let taken = api
        .post(
            "/api/v1/albums",
            Some(&anna),
            json!({ "id": id, "name": "Mine" }),
        )
        .await;
    assert_eq!(taken.status, 409);
    let path = format!("/api/v1/albums/{id}");
    assert_eq!(api.get(&path, &anna).await.status, 404);
    let foreign = api
        .call(
            Method::PATCH,
            &path,
            Some(&anna),
            Some(json!({ "name": "x" })),
        )
        .await;
    assert_eq!(foreign.status, 404);
    assert!(
        api.get("/api/v1/albums", &anna).await.body["albums"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let empty_name = api
        .post("/api/v1/albums", Some(&lucas), json!({ "name": "   " }))
        .await;
    assert_eq!(empty_name.status, 422);

    // Renamed, a cover chosen, moved in the list; photos in and out.
    let changed = api
        .call(
            Method::PATCH,
            &path,
            Some(&lucas),
            Some(json!({ "name": "Rome 2026", "coverAssetId": b, "sortOrder": -1 })),
        )
        .await;
    assert_eq!(changed.status, 200, "{}", changed.body);
    assert_eq!(changed.body["coverAssetId"], b.as_str());
    let path_assets = format!("{path}/assets");
    let added = api
        .call(
            Method::POST,
            &path_assets,
            Some(&lucas),
            Some(json!({ "assetIds": [c, a] })),
        )
        .await;
    assert_eq!(added.body["assetIds"].as_array().unwrap().len(), 3);
    assert_eq!(added.body["assetIds"][0], c.as_str(), "the newest first");
    let removed = api
        .call(
            Method::DELETE,
            &path_assets,
            Some(&lucas),
            Some(json!({ "assetIds": [a] })),
        )
        .await;
    assert_eq!(removed.body["assetIds"].as_array().unwrap().len(), 2);
    let second = api
        .post("/api/v1/albums", Some(&lucas), json!({ "name": "Archive" }))
        .await;
    let list = api.get("/api/v1/albums", &lucas).await.body;
    let names: Vec<&str> = list["albums"]
        .as_array()
        .unwrap()
        .iter()
        .map(|album| album["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Rome 2026", "Archive"], "in their order");

    // Another device gets photos and albums with the sync, also one change at a time.
    let (albums, mark) = synced_albums(&api, &lucas, 0, 1).await;
    let rome: Vec<&Value> = albums
        .iter()
        .filter(|album| album["id"] == id.as_str())
        .collect();
    assert_eq!(rome.len(), 1, "once, in its latest state: {albums:?}");
    assert_eq!(rome[0]["name"], "Rome 2026");
    assert_eq!(albums.len(), 2);

    // In the trash, a photo stays in its album; deleted for good, it leaves it.
    api.post("/api/v1/assets/trash", Some(&lucas), json!({ "ids": [b] }))
        .await;
    assert_eq!(
        api.get(&path, &lucas).await.body["assetIds"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let gone = api
        .post("/api/v1/assets/delete", Some(&lucas), json!({ "ids": [b] }))
        .await;
    assert_eq!(gone.status, 200, "{}", gone.body);
    let after = api.get(&path, &lucas).await.body;
    assert_eq!(after["assetIds"], json!([c]));
    assert_eq!(
        after["coverAssetId"],
        Value::Null,
        "the cover was that photo"
    );
    let (since_then, mark) = synced_albums(&api, &lucas, mark, 100).await;
    assert_eq!(since_then.len(), 1, "the album changed with it");

    // Deleting the album: its photos stay; devices hear of it.
    let deleted = api.call(Method::DELETE, &path, Some(&lucas), None).await;
    assert_eq!(deleted.status, 204);
    assert_eq!(
        api.call(Method::DELETE, &path, Some(&lucas), None)
            .await
            .status,
        204
    );
    assert_eq!(api.get(&path, &lucas).await.status, 404);
    assert_eq!(
        api.get(&format!("/api/v1/assets/{c}"), &lucas).await.status,
        200
    );
    let (last, _) = synced_albums(&api, &lucas, mark, 100).await;
    assert_eq!(last.len(), 1);
    assert!(last[0]["deletedAt"].is_i64());
    assert_eq!(last[0]["assetIds"], json!([]));
    assert_eq!(second.status, 201);
}
