//! The real `halden serve` program is killed with `kill -9` in the middle of an upload, started
//! again, and the upload continues. At the end the file is complete with the right hash, and no
//! half file ever appears in the library.

mod common;

use std::{
    net::TcpListener,
    path::Path,
    process::{Child, Command, Stdio},
    time::Duration,
};

use bytes::Bytes;
use common::{LUCAS_PASSWORD, client, iphone};
use futures_util::StreamExt;
use halden::{
    accounts::{self, NewUser, Role},
    auth::password,
    config::Config,
    db::Db,
    setup::{self, SetupOptions},
    tls,
};
use reqwest::Method;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const MIB: usize = 1024 * 1024;
const SIZE: usize = 200 * MIB;
const HALF: usize = SIZE / 2;

/// Stops the server when the test ends, however it ends.
struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        common::stop_process(&mut self.0);
    }
}

fn start(config_path: &Path) -> Server {
    Server(
        Command::new(env!("CARGO_BIN_EXE_halden"))
            .arg("--config")
            .arg(config_path)
            .arg("serve")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("the halden program starts"),
    )
}

async fn wait_until_up(http: &reqwest::Client, base: &str) {
    for _ in 0..200 {
        if http
            .get(format!("{base}/api/v1/health"))
            .send()
            .await
            .is_ok_and(|r| r.status() == 200)
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the server did not come up");
}

async fn json(response: reqwest::Response) -> Value {
    response.json().await.unwrap()
}

// Two threads: the client must be able to answer the server's goodbye while the test waits for
// the server to stop at the end.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn kill_dash_nine_in_the_middle_of_an_upload_loses_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.toml");
    setup::run(
        &config_path,
        SetupOptions {
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

    let pin = *tls::identity_fingerprint(&config).unwrap().as_bytes();
    let http = client(pin, &[&rustls::version::TLS13]);
    let base = format!("https://127.0.0.1:{port}");
    let mut server = start(&config_path);
    wait_until_up(&http, &base).await;

    let token = json(
        http.post(format!("{base}/api/v1/auth/login"))
            .json(&json!({ "username": "lucas", "password": LUCAS_PASSWORD, "device": iphone() }))
            .send()
            .await
            .unwrap(),
    )
    .await["token"]
        .as_str()
        .unwrap()
        .to_string();

    let mut data = vec![0u8; SIZE];
    rand::fill(data.as_mut_slice());
    let data = Bytes::from(data);
    let created = json(
        http.post(format!("{base}/api/v1/uploads"))
            .bearer_auth(&token)
            .json(&json!({
                "assetId": Uuid::new_v4(),
                "size": SIZE,
                "sha256": hex::encode(Sha256::digest(&data)),
                "mimeType": "video/quicktime",
            }))
            .send()
            .await
            .unwrap(),
    )
    .await;
    let upload = format!(
        "{base}/api/v1/uploads/{}",
        created["uploadId"].as_str().unwrap()
    );

    // The first half arrives normally.
    let first = json(
        http.request(Method::PATCH, &upload)
            .bearer_auth(&token)
            .header("upload-offset", "0")
            .body(data.slice(..HALF))
            .send()
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(first["offset"], HALF);

    // The second half starts, then stalls, and the server is killed while it waits.
    let stalled = futures_util::stream::iter(vec![Ok::<_, std::io::Error>(
        data.slice(HALF..HALF + 8 * MIB),
    )])
    .chain(futures_util::stream::pending());
    let sending = tokio::spawn(
        http.request(Method::PATCH, &upload)
            .bearer_auth(&token)
            .header("upload-offset", HALF.to_string())
            .body(reqwest::Body::wrap_stream(stalled))
            .send(),
    );
    let part = config
        .incoming_dir()
        .join(format!("{}.part", created["uploadId"].as_str().unwrap()));
    for _ in 0..200 {
        if std::fs::metadata(&part).map_or(0, |m| m.len()) > HALF as u64 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    server.0.kill().unwrap();
    server.0.wait().unwrap();
    assert!(
        sending.await.unwrap().is_err(),
        "the stalled request dies with the server"
    );
    let library_files = |root: &Path| -> usize {
        walk(root)
            .into_iter()
            .filter(|p| !p.to_string_lossy().contains("/.halden/"))
            .count()
    };
    assert_eq!(library_files(&config.storage.library_dir), 0);

    // After the restart the server knows exactly how much it has, and the upload goes on.
    let _server = start(&config_path);
    wait_until_up(&http, &base).await;
    let head = http.head(&upload).bearer_auth(&token).send().await.unwrap();
    let offset: usize = head.headers()["upload-offset"]
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!(offset >= HALF, "offset {offset}");
    let done = json(
        http.request(Method::PATCH, &upload)
            .bearer_auth(&token)
            .header("upload-offset", offset.to_string())
            .body(data.slice(offset..))
            .send()
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(done["state"], "completed", "{done}");

    let stored: Vec<_> = walk(&config.storage.library_dir)
        .into_iter()
        .filter(|p| !p.to_string_lossy().contains("/.halden/"))
        .collect();
    assert_eq!(stored.len(), 1, "{stored:?}");
    let on_disk = std::fs::read(&stored[0]).unwrap();
    assert_eq!(on_disk.len(), SIZE);
    assert_eq!(Sha256::digest(&on_disk), Sha256::digest(&data));
    assert_eq!(std::fs::read_dir(config.incoming_dir()).unwrap().count(), 0);
}

fn walk(root: &Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    let mut folders = vec![root.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(folder).unwrap().flatten() {
            if entry.file_type().unwrap().is_dir() {
                folders.push(entry.path());
            } else {
                files.push(entry.path());
            }
        }
    }
    files
}
