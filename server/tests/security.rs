//! Attacks from the outside, systematically: every route without a token, with a forged token,
//! with a signed-out device, as a member on owner routes, and as one account on another's
//! photos; paths that try to climb out of the library; oversized requests; forged client
//! addresses; idle and deliberately slow connections.

mod common;

use std::{
    io::{Read, Write},
    net::TcpStream,
    sync::Arc,
    time::{Duration, Instant},
};

use common::{
    ANNA_PASSWORD, Api, LUCAS_PASSWORD, device, gradient_jpeg, iphone, random_bytes, sha_hex,
};
use halden::accounts::Role;
use reqwest::Method;
use serde_json::{Value, json};
use uuid::Uuid;

/// Every route that needs a signed-in device, with a body that parses.
fn routes(
    asset: &str,
    upload: &str,
    device_id: &str,
    user: &str,
    hash: &str,
) -> Vec<(Method, String, Option<Value>)> {
    let mut list = vec![
        (Method::GET, "/api/v1/me".to_string(), None),
        (
            Method::PUT,
            "/api/v1/me/password".into(),
            Some(json!({ "currentPassword": "x", "newPassword": "a long new password" })),
        ),
        (Method::POST, "/api/v1/auth/logout".into(), Some(json!({}))),
        (
            Method::POST,
            "/api/v1/pairing-codes".into(),
            Some(json!({})),
        ),
        (Method::GET, "/api/v1/devices".into(), None),
        (Method::DELETE, format!("/api/v1/devices/{device_id}"), None),
        (
            Method::POST,
            format!("/api/v1/devices/{device_id}/confirm"),
            Some(json!({})),
        ),
        (
            Method::POST,
            format!("/api/v1/devices/{device_id}/block"),
            Some(json!({})),
        ),
        (Method::GET, "/api/v1/security-log".into(), None),
        (
            Method::POST,
            "/api/v1/uploads".into(),
            Some(
                json!({ "assetId": Uuid::new_v4(), "size": 1, "sha256": "00".repeat(32), "mimeType": "image/jpeg" }),
            ),
        ),
        (Method::GET, format!("/api/v1/uploads/{upload}"), None),
        (Method::DELETE, format!("/api/v1/uploads/{upload}"), None),
        (
            Method::POST,
            format!("/api/v1/uploads/{upload}/complete"),
            Some(json!({})),
        ),
        (
            Method::POST,
            "/api/v1/assets/check".into(),
            Some(json!({ "items": [] })),
        ),
        (
            Method::POST,
            "/api/v1/assets/location".into(),
            Some(json!({ "ids": [asset], "latitude": 1.0, "longitude": 1.0 })),
        ),
        (
            Method::POST,
            "/api/v1/assets/trash".into(),
            Some(json!({ "ids": [asset] })),
        ),
        (
            Method::POST,
            "/api/v1/assets/restore".into(),
            Some(json!({ "ids": [asset] })),
        ),
        (
            Method::POST,
            "/api/v1/assets/delete".into(),
            Some(json!({ "ids": [asset] })),
        ),
        (Method::GET, "/api/v1/me/settings".into(), None),
        (
            Method::PUT,
            "/api/v1/me/settings".into(),
            Some(json!({ "photoFormat": "original" })),
        ),
        (Method::GET, "/api/v1/assets/without-location".into(), None),
        (Method::GET, format!("/api/v1/assets/{asset}"), None),
        (
            Method::PATCH,
            format!("/api/v1/assets/{asset}"),
            Some(json!({ "title": "x" })),
        ),
        (
            Method::GET,
            format!("/api/v1/assets/{asset}/location-suggestion"),
            None,
        ),
        (Method::GET, "/api/v1/sync".into(), None),
        (
            Method::GET,
            format!("/api/v1/assets/{asset}/files/original"),
            None,
        ),
        (Method::GET, format!("/api/v1/files/{hash}"), None),
        (
            Method::POST,
            "/api/v1/thumbnails".into(),
            Some(json!({ "ids": [asset] })),
        ),
    ];
    list.extend(admin_routes(user));
    list
}

/// The owners' routes, with bodies that parse.
fn admin_routes(user: &str) -> Vec<(Method, String, Option<Value>)> {
    vec![
        (Method::GET, "/api/v1/admin/users".to_string(), None),
        (
            Method::POST,
            "/api/v1/admin/users".into(),
            Some(json!({ "username": "mallory" })),
        ),
        (
            Method::PATCH,
            format!("/api/v1/admin/users/{user}"),
            Some(json!({ "role": "member" })),
        ),
        (
            Method::DELETE,
            format!("/api/v1/admin/users/{user}"),
            Some(json!({})),
        ),
        (Method::GET, "/api/v1/admin/status".into(), None),
        (Method::GET, "/api/v1/admin/config".into(), None),
        (
            Method::PATCH,
            "/api/v1/admin/config".into(),
            Some(json!({ "changes": { "jobs.workers": 2 } })),
        ),
        (Method::GET, "/api/v1/admin/backups".into(), None),
        (
            Method::POST,
            "/api/v1/admin/backups".into(),
            Some(json!({})),
        ),
        (Method::GET, "/api/v1/admin/mirror".into(), None),
        (
            Method::PUT,
            "/api/v1/admin/mirror".into(),
            Some(json!({ "path": "/tmp" })),
        ),
        (
            Method::DELETE,
            "/api/v1/admin/mirror".into(),
            Some(json!({})),
        ),
        (Method::GET, "/api/v1/admin/jobs".into(), None),
        (
            Method::POST,
            "/api/v1/admin/jobs/retry".into(),
            Some(json!({})),
        ),
        (Method::GET, "/api/v1/admin/doctor".into(), None),
        (
            Method::POST,
            "/api/v1/admin/restart".into(),
            Some(json!({})),
        ),
        (Method::GET, "/api/v1/admin/update".into(), None),
        (
            Method::POST,
            "/api/v1/admin/update/check".into(),
            Some(json!({})),
        ),
        (
            Method::POST,
            "/api/v1/admin/update/install".into(),
            Some(json!({})),
        ),
    ]
}

struct World {
    api: Api,
    lucas: String,
    anna: String,
    lucas_asset: String,
    lucas_upload: String,
    lucas_device: String,
    lucas_user: String,
    lucas_hash: String,
}

async fn world() -> World {
    let api = Api::start().await;
    let lucas_user = api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let lucas = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna"),
        )
        .await;
    let data = random_bytes(5_000);
    let lucas_asset = Uuid::new_v4().to_string();
    api.upload(&lucas, &lucas_asset, &data, "image/heic", json!({}))
        .await;
    let created = api
        .post(
            "/api/v1/uploads",
            Some(&lucas),
            json!({ "assetId": Uuid::new_v4(), "size": 10, "sha256": "11".repeat(32), "mimeType": "image/jpeg" }),
        )
        .await;
    let me = api.get("/api/v1/me", &lucas).await;
    World {
        lucas_upload: created.body["uploadId"].as_str().unwrap().to_string(),
        lucas_device: me.body["device"]["id"].as_str().unwrap().to_string(),
        lucas_user: lucas_user.id,
        lucas_hash: sha_hex(&data),
        api,
        lucas,
        anna,
        lucas_asset,
    }
}

impl World {
    fn routes(&self) -> Vec<(Method, String, Option<Value>)> {
        routes(
            &self.lucas_asset,
            &self.lucas_upload,
            &self.lucas_device,
            &self.lucas_user,
            &self.lucas_hash,
        )
    }

    async fn call_raw(
        &self,
        method: Method,
        path: &str,
        auth: Option<&str>,
        body: Option<Value>,
    ) -> u16 {
        let mut request = self.api.http.request(method, self.api.url(path));
        if let Some(auth) = auth {
            request = request.header("authorization", auth);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        request.send().await.unwrap().status().as_u16()
    }
}

#[tokio::test]
async fn every_route_wants_a_valid_token() {
    let world = world().await;
    let forged = format!("Bearer {}", "A".repeat(43));
    for (method, path, body) in world.routes() {
        for auth in [
            None,
            Some("Bearer nonsense"),
            Some(forged.as_str()),
            Some("Basic bHVjYXM6eA=="),
        ] {
            let status = world
                .call_raw(method.clone(), &path, auth, body.clone())
                .await;
            assert_eq!(status, 401, "{method} {path} with {auth:?}");
        }
    }
    // A signed-out device's token stops working everywhere.
    let gone = world
        .api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's Mac", "install-anna-mac"),
        )
        .await;
    world
        .api
        .post("/api/v1/auth/logout", Some(&gone), json!({}))
        .await;
    for (method, path, body) in world.routes() {
        let status = world
            .call_raw(method.clone(), &path, Some(&format!("Bearer {gone}")), body)
            .await;
        assert_eq!(status, 401, "{method} {path} after signing out");
    }
    world.api.stop().await;
}

#[tokio::test]
async fn members_cant_use_owner_routes() {
    let world = world().await;
    for (method, path, body) in admin_routes(&world.lucas_user) {
        let status = world
            .call_raw(
                method.clone(),
                &path,
                Some(&format!("Bearer {}", world.anna)),
                body,
            )
            .await;
        assert_eq!(status, 403, "{method} {path} as a member");
    }
    // Lucas is still an owner, and nothing was changed.
    let me = world.api.get("/api/v1/me", &world.lucas).await;
    assert_eq!(me.body["user"]["role"], "owner");
    world.api.stop().await;
}

#[tokio::test]
async fn one_account_cant_reach_another_ones_photos() {
    let world = world().await;
    let api = &world.api;
    let anna = &world.anna;
    let asset = &world.lucas_asset;
    for path in [
        format!("/api/v1/assets/{asset}"),
        format!("/api/v1/assets/{asset}/files/original"),
        format!("/api/v1/assets/{asset}/location-suggestion"),
        format!("/api/v1/files/{}", world.lucas_hash),
        format!("/api/v1/uploads/{}", world.lucas_upload),
    ] {
        assert_eq!(api.get(&path, anna).await.status, 404, "{path}");
    }
    let patched = api
        .call(
            Method::PATCH,
            &format!("/api/v1/assets/{asset}"),
            Some(anna),
            Some(json!({ "title": "mine now" })),
        )
        .await;
    assert_eq!(patched.status, 404);
    let thumbnail = gradient_jpeg();
    assert_eq!(
        api.put_derived(anna, asset, "thumbnail", &thumbnail)
            .await
            .status,
        404
    );
    // Bulk routes simply don't see the other account's photos.
    for route in [
        "/api/v1/assets/trash",
        "/api/v1/assets/delete",
        "/api/v1/assets/location",
    ] {
        api.post(
            route,
            Some(anna),
            json!({ "ids": [asset], "latitude": 1.0, "longitude": 2.0 }),
        )
        .await;
    }
    let bulk = api
        .http
        .post(api.url("/api/v1/thumbnails"))
        .bearer_auth(anna)
        .json(&json!({ "ids": [asset] }))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    assert!(
        bulk.len() < 30,
        "no thumbnail of another account: {} bytes",
        bulk.len()
    );
    // A hash check doesn't reveal that someone else has the photo.
    let checked = api
        .post(
            "/api/v1/assets/check",
            Some(anna),
            json!({ "items": [{ "assetId": Uuid::new_v4(), "sha256": world.lucas_hash }] }),
        )
        .await;
    assert_eq!(
        checked.body["results"][0]["status"], "missing",
        "{}",
        checked.body
    );
    let sync = api.get("/api/v1/sync", anna).await;
    assert_eq!(sync.body["assets"], json!([]));
    // Lucas's photo is untouched.
    let mine = api
        .get(&format!("/api/v1/assets/{asset}"), &world.lucas)
        .await;
    assert!(mine.body["trashedAt"].is_null(), "{}", mine.body);
    assert!(mine.body["title"].is_null());
    assert!(mine.body["location"].is_null(), "{}", mine.body);
    // Nor his upload or device.
    let cancel = api
        .call(
            Method::DELETE,
            &format!("/api/v1/uploads/{}", world.lucas_upload),
            Some(anna),
            None,
        )
        .await;
    assert_eq!(cancel.status, 404);
    let revoke = api
        .call(
            Method::DELETE,
            &format!("/api/v1/devices/{}", world.lucas_device),
            Some(anna),
            None,
        )
        .await;
    assert!(matches!(revoke.status, 403 | 404), "{}", revoke.status);
    assert_eq!(api.get("/api/v1/me", &world.lucas).await.status, 200);
    world.api.stop().await;
}

#[tokio::test]
async fn paths_never_climb_out() {
    let world = world().await;
    let api = &world.api;
    let asset = &world.lucas_asset;
    for path in [
        format!("/api/v1/assets/{asset}/files/..%2F..%2F..%2Fetc%2Fpasswd"),
        format!("/api/v1/assets/{asset}/files/%2Fetc%2Fpasswd"),
        format!("/api/v1/assets/{asset}/files/original%00"),
        "/api/v1/assets/..%2F..%2Fdata%2Fhalden.db/files/original".to_string(),
        "/api/v1/files/..%2F..%2Fdata%2Fhalden.db".to_string(),
        "/api/v1/files/%2E%2E%2F%2E%2E%2Fhalden.db".to_string(),
        format!("/api/v1/files/{}", "zz".repeat(32)),
        format!("/api/v1/files/{}", "a".repeat(63)),
        "/api/v1/uploads/..%2F..%2Fhalden.db".to_string(),
        "/api/v1/assets/not-a-uuid".to_string(),
        "/api/v1/../../etc/passwd".to_string(),
    ] {
        let reply = api.get(&path, &world.lucas).await;
        assert!(
            (400..500).contains(&reply.status),
            "{path} answered {}: {}",
            reply.status,
            reply.body
        );
    }
    // Uploads never take a name or folder from the client: an id with slashes is refused.
    let created = api
        .post(
            "/api/v1/uploads",
            Some(&world.lucas),
            json!({ "assetId": "../../etc/passwd", "size": 1, "sha256": "00".repeat(32), "mimeType": "image/jpeg" }),
        )
        .await;
    assert_eq!(created.status, 422, "{}", created.body);
    world.api.stop().await;
}

#[tokio::test]
async fn a_forged_client_address_is_ignored() {
    let world = world().await;
    let response = world
        .api
        .http
        .post(world.api.url("/api/v1/auth/login"))
        .header("x-forwarded-for", "8.8.8.8")
        .header("x-real-ip", "8.8.8.8")
        .header("forwarded", "for=8.8.8.8")
        .json(&json!({ "username": "lucas", "password": "wrong password", "device": iphone() }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 401);
    let log = world.api.get("/api/v1/security-log", &world.lucas).await;
    let failed = log.body["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["event"] == "login_failed")
        .cloned()
        .unwrap();
    assert_eq!(failed["ip"], "127.0.0.1", "{failed}");
    world.api.stop().await;
}

#[tokio::test]
async fn oversized_requests_are_refused_before_they_cost_anything() {
    let world = world().await;
    let api = &world.api;
    // JSON over 256 KiB.
    let big = json!({ "ids": vec!["x".repeat(100); 4000] });
    let reply = api
        .post("/api/v1/assets/trash", Some(&world.lucas), big)
        .await;
    assert_eq!(reply.status, 413, "{}", reply.body);
    assert_eq!(reply.error(), "too_large");
    // A thumbnail over 8 MiB.
    let huge = random_bytes(9 * 1024 * 1024);
    let reply = api
        .put_derived(&world.lucas, &world.lucas_asset, "thumbnail", &huge)
        .await;
    assert_eq!(reply.status, 413, "{}", reply.body);
    // Headers of 200 KiB: refused or the stream reset, never served.
    let response = api
        .http
        .get(api.url("/api/v1/me"))
        .bearer_auth(&world.lucas)
        .header("x-padding", "p".repeat(200 * 1024))
        .send()
        .await;
    if let Ok(response) = response {
        assert!(response.status().as_u16() >= 400, "{}", response.status());
    }
    // The server is fine afterwards.
    assert_eq!(api.get("/api/v1/me", &world.lucas).await.status, 200);
    world.api.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn idle_connections_dont_block_and_are_dropped() {
    let world = world().await;
    let addr = world.api.server.addr;
    // Hundreds of connections that never say anything.
    let mut idle = Vec::new();
    for _ in 0..300 {
        idle.push(TcpStream::connect(addr).unwrap());
    }
    let started = Instant::now();
    assert_eq!(world.api.get("/api/v1/me", &world.lucas).await.status, 200);
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );
    // They are closed after the TLS handshake timeout (10 s).
    let mut first = idle.remove(0);
    first
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let started = Instant::now();
    let mut buffer = [0u8; 16];
    let read = first.read(&mut buffer);
    assert!(
        matches!(read, Ok(0)) || read.is_err() && started.elapsed() < Duration::from_secs(19),
        "{read:?} after {:?}",
        started.elapsed()
    );
    assert!(
        started.elapsed() >= Duration::from_secs(5),
        "closed too early"
    );
    drop(idle);
    world.api.stop().await;
}

/// HTTP/1.1 headers sent one byte a second: the connection is closed after 15 s instead of
/// being held for ever.
#[tokio::test]
async fn slow_headers_are_cut_off() {
    let world = world().await;
    let addr = world.api.server.addr;
    let pin = *world.api.server.fingerprint.as_bytes();
    let closed_after = tokio::task::spawn_blocking(move || {
        let mut tls = common::pinned_tls(pin, &[&rustls::version::TLS13]);
        tls.alpn_protocols = vec![b"http/1.1".to_vec()];
        let name = rustls::pki_types::ServerName::try_from("halden.local").unwrap();
        let connection = rustls::ClientConnection::new(Arc::new(tls), name).unwrap();
        let socket = TcpStream::connect(addr).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let mut stream = rustls::StreamOwned::new(connection, socket);
        let started = Instant::now();
        let request = b"GET /api/v1/health HTTP/1.1\r\nHost: x\r\nX-Slow: ";
        stream.write_all(request).unwrap();
        loop {
            if started.elapsed() > Duration::from_secs(40) {
                return None;
            }
            if stream
                .write_all(b"a")
                .and_then(|()| stream.flush())
                .is_err()
            {
                return Some(started.elapsed());
            }
            let mut buffer = [0u8; 256];
            match stream.read(&mut buffer) {
                Ok(0) => return Some(started.elapsed()),
                Ok(_) => return Some(started.elapsed()),
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        || error.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => return Some(started.elapsed()),
            }
        }
    })
    .await
    .unwrap();
    let after = closed_after.expect("the slow connection was never closed");
    assert!(after < Duration::from_secs(25), "{after:?}");
    world.api.stop().await;
}
