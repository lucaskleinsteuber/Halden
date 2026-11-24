//! The real server dies on purpose (`HALDEN_FAILPOINT`, debug builds only) at exactly the
//! moments where a file and its record could get out of step: right before and right after an
//! upload is moved into the library, right after it is recorded, after a conversion is placed,
//! and after a photo deleted for good is recorded as gone but before its files are removed.
//! After every restart, `halden doctor --files` must find every file intact, nothing missing and
//! nothing the library doesn't know, and the upload must be finishable.

mod common;

use std::{
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::Duration,
};

use common::{LUCAS_PASSWORD, client, gradient_jpeg, iphone};
use halden::{
    accounts::{self, NewUser, Role},
    auth::password,
    config::Config,
    db::Db,
    setup::{self, SetupOptions},
    tls,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        common::stop_process(&mut self.0);
    }
}

struct Box_ {
    _dir: tempfile::TempDir,
    config_path: PathBuf,
    config: Config,
    http: reqwest::Client,
    api: String,
}

async fn set_up() -> Box_ {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.toml");
    setup::run(
        &config_path,
        SetupOptions {
            name: Some("testbox".into()),
            data_dir: Some(dir.path().join("data")),
            library_dir: Some(dir.path().join("library")),
            ..SetupOptions::default()
        },
    )
    .await
    .unwrap();
    let mut config = Config::load(&config_path).unwrap();
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    config.server.bind = "127.0.0.1".parse().unwrap();
    config.server.port = port;
    config.network.bonjour = false;
    config.save(&config_path).unwrap();
    let db = Db::open(&config.db_path()).await.unwrap();
    accounts::create_user(
        &db,
        NewUser {
            username: "lucas",
            display_name: None,
            role: Role::Owner,
            password_hash: Some(password::hash(LUCAS_PASSWORD.into()).await.unwrap()),
        },
    )
    .await
    .unwrap();
    db.close().await;
    let http = client(
        *tls::identity_fingerprint(&config).unwrap().as_bytes(),
        &[&rustls::version::TLS13],
    );
    Box_ {
        _dir: dir,
        api: format!("https://127.0.0.1:{port}/api/v1"),
        config_path,
        config,
        http,
    }
}

impl Box_ {
    async fn start(&self, failpoint: Option<&str>) -> Server {
        let mut command = Command::new(env!("CARGO_BIN_EXE_halden"));
        command
            .arg("--config")
            .arg(&self.config_path)
            .arg("serve")
            .env_remove("HALDEN_FAILPOINT")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(point) = failpoint {
            command.env("HALDEN_FAILPOINT", point);
        }
        let server = Server(command.spawn().unwrap());
        for _ in 0..200 {
            if self
                .http
                .get(format!("{}/health", self.api))
                .send()
                .await
                .is_ok()
            {
                return server;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("the server did not come up");
    }

    async fn token(&self) -> String {
        let reply: Value = self
            .http
            .post(format!("{}/auth/login", self.api))
            .json(&json!({ "username": "lucas", "password": LUCAS_PASSWORD, "device": iphone() }))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        reply["token"].as_str().unwrap().to_string()
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        token: &str,
        body: Option<Value>,
    ) -> Value {
        let mut request = self
            .http
            .request(method, format!("{}{path}", self.api))
            .bearer_auth(token);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.unwrap();
        let text = response.text().await.unwrap();
        serde_json::from_str(&text).unwrap_or(Value::Null)
    }

    /// Announces an upload and sends all of it. Returns the upload's id and the PATCH's result
    /// (an error when the server died while finishing).
    async fn upload(
        &self,
        token: &str,
        asset: &str,
        data: &[u8],
        mime: &str,
    ) -> (String, Result<Value, reqwest::Error>) {
        let created = self
            .call(
                reqwest::Method::POST,
                "/uploads",
                token,
                Some(json!({ "assetId": asset, "size": data.len(),
                             "sha256": hex::encode(Sha256::digest(data)), "mimeType": mime })),
            )
            .await;
        let id = created["uploadId"].as_str().unwrap().to_string();
        let result = match self
            .http
            .patch(format!("{}/uploads/{id}", self.api))
            .bearer_auth(token)
            .header("upload-offset", "0")
            .body(data.to_vec())
            .send()
            .await
        {
            Ok(response) => response.json::<Value>().await,
            Err(error) => Err(error),
        };
        (id, result)
    }

    /// `halden doctor --files`: every file intact, nothing missing, nothing unknown.
    fn assert_files_in_order(&self) {
        let output = Command::new(env!("CARGO_BIN_EXE_halden"))
            .arg("--config")
            .arg(&self.config_path)
            .args(["doctor", "--files", "--json"])
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&output.stdout);
        let report: Value = serde_json::from_str(&text).unwrap_or_else(|_| panic!("{text}"));
        let files = &report["files"];
        for list in [
            "missing",
            "damaged",
            "unknown",
            "mirrorMissing",
            "mirrorDamaged",
        ] {
            assert_eq!(files[list], json!([]), "{list}: {files}");
        }
    }
}

/// Waits until a server that should die at its failpoint has died.
fn wait_dead(server: &mut Server) {
    for _ in 0..1200 {
        if server.0.try_wait().unwrap().is_some() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("the server did not stop at its failpoint");
}

fn library_files(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut folders = vec![root.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(folder).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                folders.push(entry.path());
            } else {
                found.push(entry.path());
            }
        }
    }
    found
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_upload_survives_a_crash_at_every_step_of_finishing() {
    for point in ["upload-before-place", "upload-placed", "upload-recorded"] {
        let setup = set_up().await;
        let mut server = setup.start(Some(point)).await;
        let token = setup.token().await;
        let data = common::random_bytes(300_000);
        let asset = Uuid::new_v4().to_string();
        let (upload, first) = setup.upload(&token, &asset, &data, "image/heic").await;
        assert!(
            first.is_err(),
            "{point}: the server should have died: {first:?}"
        );
        wait_dead(&mut server);
        drop(server);

        let _server = setup.start(None).await;
        let state = setup
            .call(
                reqwest::Method::GET,
                &format!("/uploads/{upload}"),
                &token,
                None,
            )
            .await;
        if point == "upload-recorded" {
            assert_eq!(state["state"], "completed", "{point}: {state}");
        } else {
            // The file is back in its partial file, complete; finishing it is one call.
            assert_eq!(state["offset"], data.len(), "{point}: {state}");
            let done = setup
                .call(
                    reqwest::Method::POST,
                    &format!("/uploads/{upload}/complete"),
                    &token,
                    Some(json!({})),
                )
                .await;
            assert_eq!(done["state"], "completed", "{point}: {done}");
        }
        let files = library_files(&setup.config.storage.library_dir);
        assert_eq!(files.len(), 1, "{point}: exactly one copy: {files:?}");
        assert_eq!(std::fs::read(&files[0]).unwrap(), data, "{point}");
        setup.assert_files_in_order();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_conversion_placed_but_not_recorded_is_made_again_without_leftovers() {
    let setup = set_up().await;
    let mut server = setup.start(Some("convert-placed")).await;
    let token = setup.token().await;
    setup
        .call(
            reqwest::Method::PUT,
            "/me/settings",
            &token,
            Some(json!({ "photoFormat": "png" })),
        )
        .await;
    let asset = Uuid::new_v4().to_string();
    let (_, done) = setup
        .upload(&token, &asset, &gradient_jpeg(), "image/jpeg")
        .await;
    assert_eq!(done.unwrap()["state"], "completed");
    // The worker converts in the background and dies right after placing the copy.
    wait_dead(&mut server);
    drop(server);
    assert_eq!(
        library_files(&setup.config.storage.library_dir).len(),
        2,
        "the unrecorded copy is there after the crash"
    );

    let _server = setup.start(None).await;
    let mut converted = false;
    for _ in 0..1200 {
        let detail = setup
            .call(
                reqwest::Method::GET,
                &format!("/assets/{asset}"),
                &token,
                None,
            )
            .await;
        if detail["files"]
            .as_array()
            .is_some_and(|files| files.iter().any(|f| f["role"] == "converted"))
        {
            converted = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(converted, "the conversion was made again");
    let files = library_files(&setup.config.storage.library_dir);
    assert_eq!(
        files.len(),
        2,
        "original and one copy, no leftover: {files:?}"
    );
    setup.assert_files_in_order();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_photo_deleted_for_good_leaves_nothing_behind_after_a_crash() {
    let setup = set_up().await;
    let mut server = setup.start(Some("purge-recorded")).await;
    let token = setup.token().await;
    let asset = Uuid::new_v4().to_string();
    let data = common::random_bytes(100_000);
    let (_, done) = setup.upload(&token, &asset, &data, "image/heic").await;
    assert_eq!(done.unwrap()["state"], "completed");
    // A thumbnail too, on the other disk.
    let thumbnail = gradient_jpeg();
    setup
        .http
        .put(format!("{}/assets/{asset}/files/thumbnail", setup.api))
        .bearer_auth(&token)
        .header("content-type", "image/jpeg")
        .header("halden-sha256", hex::encode(Sha256::digest(&thumbnail)))
        .body(thumbnail)
        .send()
        .await
        .unwrap();
    setup
        .call(
            reqwest::Method::POST,
            "/assets/trash",
            &token,
            Some(json!({ "ids": [asset] })),
        )
        .await;
    let deleted = setup
        .http
        .post(format!("{}/assets/delete", setup.api))
        .bearer_auth(&token)
        .json(&json!({ "ids": [asset] }))
        .send()
        .await;
    assert!(deleted.is_err(), "the server died while deleting");
    wait_dead(&mut server);
    drop(server);
    assert_eq!(
        library_files(&setup.config.storage.library_dir).len(),
        1,
        "the file is still there right after the crash"
    );

    let _server = setup.start(None).await;
    assert!(
        library_files(&setup.config.storage.library_dir).is_empty(),
        "the start removed the deleted photo"
    );
    assert!(
        library_files(&setup.config.derived_dir()).is_empty(),
        "and its thumbnail"
    );
    let detail = setup
        .call(
            reqwest::Method::GET,
            &format!("/assets/{asset}"),
            &token,
            None,
        )
        .await;
    assert!(
        detail["deletedAt"].is_i64() || detail["error"] == "not_found",
        "{detail}"
    );
    setup.assert_files_in_order();
}
