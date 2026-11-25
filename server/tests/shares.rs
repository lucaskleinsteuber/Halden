//! Shared links against the real server: made by the owner of the photos, opened by anybody with
//! the link on the public listener, with a password and an end, withdrawn; and nothing else of
//! the server can be reached there.

mod common;

use common::{
    ANNA_PASSWORD, Api, LUCAS_PASSWORD, device, gradient_jpeg, iphone, random_bytes, wait_for_files,
};
use halden::accounts::Role;
use reqwest::{Method, redirect::Policy};
use serde_json::{Value, json};
use uuid::Uuid;

/// A browser without a certificate check (the public listener is plain HTTP), keeping cookies
/// by hand and not following redirects.
fn browser() -> reqwest::Client {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .redirect(Policy::none())
        .build()
        .unwrap()
}

#[tokio::test]
async fn a_shared_link_shows_the_photos_and_nothing_else() {
    let api = Api::start_with(|config| {
        config.share.enabled = true;
        config.share.listen = "127.0.0.1:0".parse().unwrap();
        config.share.public_url = "https://photos.example.com".into();
        config.jobs.thumbnail_delay_minutes = 0;
    })
    .await;
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
    let public = format!(
        "http://{}",
        api.server.share_addr().expect("the share listener")
    );
    let photo = Uuid::new_v4().to_string();
    api.upload(&lucas, &photo, &gradient_jpeg(), "image/jpeg", json!({}))
        .await;
    let other = Uuid::new_v4().to_string();
    api.upload(&lucas, &other, &random_bytes(300), "image/heic", json!({}))
        .await;
    wait_for_files(&api, &lucas, &photo, &["thumbnail", "preview"]).await;
    let annas = Uuid::new_v4().to_string();
    api.upload(&anna, &annas, &random_bytes(400), "image/heic", json!({}))
        .await;

    // Only own photos; an end in the past is refused.
    let foreign = api
        .post(
            "/api/v1/shares",
            Some(&lucas),
            json!({ "assetIds": [annas] }),
        )
        .await;
    assert_eq!(foreign.status, 422, "{}", foreign.body);
    let past = api
        .post(
            "/api/v1/shares",
            Some(&lucas),
            json!({ "assetIds": [photo], "expiresAt": 1000 }),
        )
        .await;
    assert_eq!(past.status, 422);

    let made = api
        .post(
            "/api/v1/shares",
            Some(&lucas),
            json!({ "title": "Harbour", "assetIds": [photo] }),
        )
        .await;
    assert_eq!(made.status, 201, "{}", made.body);
    let token = made.body["token"].as_str().unwrap().to_string();
    assert_eq!(
        made.body["url"],
        format!("https://photos.example.com/s/{token}")
    );
    assert!(token.len() >= 22, "128 bits");
    let list = api.get("/api/v1/shares", &lucas).await.body;
    assert_eq!(list["shares"].as_array().unwrap().len(), 1);
    assert_eq!(list["reachable"], true);
    assert!(
        api.get("/api/v1/shares", &anna).await.body["shares"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    // The page: the shared photo, not the other one; previews yes, originals no.
    let web = browser();
    let page = web.get(format!("{public}/s/{token}")).send().await.unwrap();
    assert_eq!(page.status(), 200);
    assert_eq!(page.headers()["x-robots-tag"], "noindex, nofollow");
    assert!(
        page.headers()["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("default-src 'none'")
    );
    let html = page.text().await.unwrap();
    assert!(
        html.contains("Harbour") && html.contains(&photo) && !html.contains(&other),
        "{html}"
    );
    let preview = web
        .get(format!("{public}/s/{token}/{photo}/preview"))
        .send()
        .await
        .unwrap();
    assert_eq!(preview.status(), 200);
    assert_eq!(preview.headers()["content-type"], "image/jpeg");
    for (path, why) in [
        (
            format!("/s/{token}/{photo}/original"),
            "originals are not allowed",
        ),
        (format!("/s/{token}/{other}/preview"), "not shared"),
        ("/api/v1/server".to_string(), "no API here"),
        ("/api/v1/health".to_string(), "nothing of the server"),
        (format!("/s/{}", "x".repeat(22)), "an unknown link"),
    ] {
        let answer = web.get(format!("{public}{path}")).send().await.unwrap();
        assert_eq!(answer.status(), 404, "{why}: {path}");
    }

    // With a password and the originals; the views are counted.
    let locked = api
        .post(
            "/api/v1/shares",
            Some(&lucas),
            json!({ "assetIds": [photo], "password": "harbour 2026", "allowOriginals": true }),
        )
        .await
        .body;
    let locked_token = locked["token"].as_str().unwrap();
    let ask = web
        .get(format!("{public}/s/{locked_token}"))
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(ask.contains("password") && !ask.contains(&photo));
    let closed = web
        .get(format!("{public}/s/{locked_token}/{photo}/original"))
        .send()
        .await
        .unwrap();
    assert_eq!(closed.status(), 401);
    let wrong = web
        .post(format!("{public}/s/{locked_token}"))
        .header("content-type", "application/x-www-form-urlencoded")
        .body("password=guess")
        .send()
        .await
        .unwrap();
    assert_eq!(wrong.status(), 401);
    let right = web
        .post(format!("{public}/s/{locked_token}"))
        .header("content-type", "application/x-www-form-urlencoded")
        .body("password=harbour+2026")
        .send()
        .await
        .unwrap();
    assert_eq!(right.status(), 303);
    let cookie = right.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_string();
    let original = web
        .get(format!("{public}/s/{locked_token}/{photo}/original"))
        .header("cookie", &cookie)
        .send()
        .await
        .unwrap();
    assert_eq!(original.status(), 200);
    let opened = web
        .get(format!("{public}/s/{locked_token}"))
        .header("cookie", &cookie)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(opened.contains(&photo) && opened.contains("contain where the photo was taken"));
    assert_eq!(original.bytes().await.unwrap().to_vec(), gradient_jpeg());
    let log = api.get("/api/v1/security-log?limit=20", &lucas).await.body;
    assert!(log.to_string().contains("share_wrong_password"), "{log}");

    // Withdrawn: "ended", for everything below it too.
    let id = made.body["id"].as_str().unwrap();
    let revoked = api
        .call(
            Method::DELETE,
            &format!("/api/v1/shares/{id}"),
            Some(&lucas),
            None,
        )
        .await;
    assert_eq!(revoked.status, 204);
    let ended = web.get(format!("{public}/s/{token}")).send().await.unwrap();
    assert_eq!(ended.status(), 410);
    let ended_file = web
        .get(format!("{public}/s/{token}/{photo}/preview"))
        .send()
        .await
        .unwrap();
    assert_eq!(ended_file.status(), 410);
    let list: Value = api.get("/api/v1/shares", &lucas).await.body;
    assert_eq!(
        list["shares"].as_array().unwrap().len(),
        1,
        "only the open one"
    );
    let views = list["shares"][0]["views"].as_i64().unwrap();
    assert_eq!(views, 1, "the page with the password was seen once");
}

#[tokio::test]
async fn an_album_link_shows_the_album_as_it_is_now() {
    let api = Api::start_with(|config| {
        config.share.enabled = true;
        config.share.listen = "127.0.0.1:0".parse().unwrap();
    })
    .await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let lucas = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let public = format!("http://{}", api.server.share_addr().unwrap());
    let first = Uuid::new_v4().to_string();
    api.upload(&lucas, &first, &random_bytes(300), "image/heic", json!({}))
        .await;
    let album = api
        .post(
            "/api/v1/albums",
            Some(&lucas),
            json!({ "name": "Rome", "assetIds": [first] }),
        )
        .await
        .body;
    let made = api
        .post(
            "/api/v1/shares",
            Some(&lucas),
            json!({ "albumId": album["id"] }),
        )
        .await;
    assert_eq!(made.status, 201, "{}", made.body);
    assert_eq!(made.body["url"], Value::Null, "no public address set");
    assert_eq!(
        api.get("/api/v1/shares", &lucas).await.body["reachable"],
        false
    );
    let token = made.body["token"].as_str().unwrap();
    let second = Uuid::new_v4().to_string();
    api.upload(&lucas, &second, &random_bytes(500), "image/heic", json!({}))
        .await;
    api.post(
        &format!("/api/v1/albums/{}/assets", album["id"].as_str().unwrap()),
        Some(&lucas),
        json!({ "assetIds": [second] }),
    )
    .await;
    let html = browser()
        .get(format!("{public}/s/{token}"))
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(
        html.contains("Rome") && html.contains(&first) && html.contains(&second),
        "{html}"
    );
    api.post(
        "/api/v1/assets/trash",
        Some(&lucas),
        json!({ "ids": [second] }),
    )
    .await;
    let html = browser()
        .get(format!("{public}/s/{token}"))
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    assert!(!html.contains(&second), "photos in the trash are not shown");
}
