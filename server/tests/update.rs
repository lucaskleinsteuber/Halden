//! Updates against a stand-in for GitHub, with releases signed by a test key: finding a newer
//! version, refusing everything that isn't exactly what the owner signed, installing, and asking
//! for an update from the app. The real `halden` program does the work; it installs into a test
//! folder (`HALDEN_UPDATE_BINARY`, honoured only by debug builds), never over itself.
//! Restarting under systemd and going back after a failed start are tested on Linux in CI.

mod common;

use std::{
    collections::HashMap,
    net::TcpListener,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    Router,
    extract::{Path as UrlPath, State},
    http::StatusCode,
    response::IntoResponse,
    routing::get,
};
use common::{LUCAS_PASSWORD, client, iphone};
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

/// GitHub's release list and the files of the releases, changeable by the test.
#[derive(Clone, Default)]
struct FakeGithub {
    releases: Arc<Mutex<Value>>,
    files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
}

async fn releases(State(github): State<FakeGithub>) -> impl IntoResponse {
    axum::Json(github.releases.lock().unwrap().clone())
}

async fn file(
    State(github): State<FakeGithub>,
    UrlPath(name): UrlPath<String>,
) -> impl IntoResponse {
    match github.files.lock().unwrap().get(&name) {
        Some(bytes) => (StatusCode::OK, bytes.clone()).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn serve_github(github: FakeGithub) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let app = Router::new()
        .route("/releases", get(releases))
        .route("/files/{name}", get(file))
        .with_state(github);
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    base
}

/// A stand-in `halden` program: says its version and passes (or fails) the database check.
/// A version newer than this program, whatever it is now: one step up in the middle number,
/// `patch` at the end (`ahead(1)` is 0.2.1 while the program is 0.1.0).
fn ahead(patch: u64) -> String {
    let now = semver::Version::parse(halden::VERSION).unwrap();
    format!("{}.{}.{patch}", now.major, now.minor + 1)
}

/// A test version newer than every [`ahead`] one.
fn ahead_test() -> String {
    let now = semver::Version::parse(halden::VERSION).unwrap();
    format!("{}.{}.0-rc.1", now.major, now.minor + 2)
}

fn fake_program(says: &str) -> String {
    format!(
        "#!/bin/sh\ncase \"$1\" in --version) echo \"halden {says}\"; exit 0;; esac\n\
         for a in \"$@\"; do [ \"$a\" = check-upgrade ] && exit 0; done\nexit 1\n"
    )
}

/// A package `halden-<version>-<arch>-linux.tar.gz` holding `program` (and `extra` files at
/// paths relative to the work folder, to test packages with foreign files).
fn package(work: &Path, version: &str, program: &str, extra: &[&str]) -> (String, Vec<u8>) {
    let arch = std::env::consts::ARCH;
    let folder = format!("halden-{version}-{arch}-linux");
    let staging = work.join(format!("staging-{version}-{}", rand::random::<u32>()));
    std::fs::create_dir_all(staging.join(&folder).join("systemd")).unwrap();
    let binary = staging.join(&folder).join("halden");
    std::fs::write(&binary, program).unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(staging.join(&folder).join("install.sh"), "#!/bin/sh\n").unwrap();
    let mut entries = vec![folder.clone()];
    for path in extra {
        std::fs::write(staging.join(path), b"x").unwrap();
        entries.push(path.to_string());
    }
    let name = format!("{folder}.tar.gz");
    let archive = work.join(&name);
    let status = Command::new("tar")
        .env("COPYFILE_DISABLE", "1")
        .arg("-czf")
        .arg(&archive)
        .arg("-C")
        .arg(&staging)
        .args(&entries)
        .status()
        .unwrap();
    assert!(status.success());
    (name, std::fs::read(archive).unwrap())
}

struct Signer {
    keys: minisign::KeyPair,
}

impl Signer {
    fn new() -> Self {
        Self {
            keys: minisign::KeyPair::generate_unencrypted_keypair().unwrap(),
        }
    }

    fn public(&self) -> String {
        self.keys.pk.to_base64()
    }

    fn sign(&self, data: &[u8]) -> String {
        minisign::sign(
            Some(&self.keys.pk),
            &self.keys.sk,
            std::io::Cursor::new(data),
            None,
            None,
        )
        .unwrap()
        .to_string()
    }
}

/// Publishes a release on the fake GitHub: the package, its checksum list and the signature.
fn publish(
    github: &FakeGithub,
    base: &str,
    signer: &Signer,
    version: &str,
    (name, bytes): (String, Vec<u8>),
    prerelease: bool,
) {
    let sums = format!("{}  {name}\n", hex::encode(Sha256::digest(&bytes)));
    let sums_name = format!("{version}-SHA256SUMS");
    let signature_name = format!("{version}-SHA256SUMS.minisig");
    let mut files = github.files.lock().unwrap();
    files.insert(name.clone(), bytes);
    files.insert(
        signature_name.clone(),
        signer.sign(sums.as_bytes()).into_bytes(),
    );
    files.insert(sums_name.clone(), sums.into_bytes());
    let release = json!({
        "tag_name": format!("server-v{version}"),
        "draft": false,
        "prerelease": prerelease,
        "html_url": format!("{base}/notes/{version}"),
        "assets": [
            { "name": name, "browser_download_url": format!("{base}/files/{name}") },
            { "name": "SHA256SUMS", "browser_download_url": format!("{base}/files/{sums_name}") },
            { "name": "SHA256SUMS.minisig", "browser_download_url": format!("{base}/files/{signature_name}") },
        ],
    });
    let mut list = github.releases.lock().unwrap();
    let mut all = list.as_array().cloned().unwrap_or_default();
    all.insert(0, release);
    *list = Value::Array(all);
}

struct Setup {
    _dir: tempfile::TempDir,
    config_path: PathBuf,
    config: Config,
    /// Where the "installed" program lives for these tests.
    installed: PathBuf,
}

async fn set_up() -> Setup {
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
    let config = Config::load(&config_path).unwrap();
    let installed = dir.path().join("bin/halden");
    std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
    std::fs::write(&installed, "the old program").unwrap();
    Setup {
        _dir: dir,
        config_path,
        config,
        installed,
    }
}

fn halden(setup: &Setup, base: &str, key: Option<&str>, args: &[&str]) -> (bool, String) {
    let mut command = Command::new(env!("CARGO_BIN_EXE_halden"));
    command
        .arg("--config")
        .arg(&setup.config_path)
        .args(args)
        .env("HALDEN_UPDATE_API", format!("{base}/releases"))
        .env("HALDEN_UPDATE_BINARY", &setup.installed)
        .env_remove("HALDEN_UPDATE_KEY")
        .stdin(Stdio::null());
    if let Some(key) = key {
        command.env("HALDEN_UPDATE_KEY", key);
    }
    let output = command.output().unwrap();
    (
        output.status.success(),
        format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ),
    )
}

fn status(setup: &Setup) -> Value {
    serde_json::from_slice(
        &std::fs::read(setup.config.storage.data_dir.join("update-status")).unwrap(),
    )
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_what_the_owner_signed_is_installed() {
    let github = FakeGithub::default();
    let base = serve_github(github.clone()).await;
    let signer = Signer::new();
    let key = signer.public();
    let setup = set_up().await;
    let work = tempfile::tempdir().unwrap();
    let new = ahead(1);
    let good = package(work.path(), &new, &fake_program(&new), &[]);
    publish(&github, &base, &signer, &new, good.clone(), false);
    // A test version is only offered with beta on; with it off, it is pointed at.
    let test = ahead_test();
    let beta = package(work.path(), &test, &fake_program(&test), &[]);
    publish(&github, &base, &signer, &test, beta, true);

    let (ok, out) = halden(&setup, &base, Some(&key), &["update", "--check"]);
    assert!(ok, "{out}");
    assert!(out.contains(&format!("Newest:    {new}\n")), "{out}");
    assert!(
        out.contains(&format!("Test version {test} is available too"))
            && out.contains("sudo halden update --beta on"),
        "{out}"
    );
    assert_eq!(status(&setup)["state"], "available");
    assert_eq!(status(&setup)["latest"], new.as_str());
    assert_eq!(status(&setup)["testVersion"], test.as_str());

    // No key in this build: nothing is installed.
    let (ok, out) = halden(&setup, &base, None, &["update", "--yes"]);
    assert!(!ok && out.contains("no release key"), "{out}");

    // Signed with somebody else's key.
    let stranger = Signer::new();
    let (ok, out) = halden(
        &setup,
        &base,
        Some(&stranger.public()),
        &["update", "--yes"],
    );
    assert!(!ok && out.contains("not signed with Halden's key"), "{out}");

    // A package changed after signing.
    github
        .files
        .lock()
        .unwrap()
        .insert(good.0.clone(), b"something else".to_vec());
    let (ok, out) = halden(&setup, &base, Some(&key), &["update", "--yes"]);
    assert!(
        !ok && out.contains("doesn't match the signed checksum"),
        "{out}"
    );
    assert_eq!(std::fs::read(&setup.installed).unwrap(), b"the old program");
    assert_eq!(status(&setup)["state"], "failed");
    github
        .files
        .lock()
        .unwrap()
        .insert(good.0.clone(), good.1.clone());

    // The real thing: checked, self-tested, the database backed up, swapped in.
    let backups_before = halden::backup::database::list(&setup.config).len();
    let (ok, out) = halden(&setup, &base, Some(&key), &["update", "--yes"]);
    assert!(ok, "{out}");
    assert!(out.contains(&format!("Halden {new} is installed")), "{out}");
    assert_eq!(
        std::fs::read_to_string(&setup.installed).unwrap(),
        fake_program(&new)
    );
    let mut previous = setup.installed.clone().into_os_string();
    previous.push(".previous");
    assert_eq!(std::fs::read(previous).unwrap(), b"the old program");
    assert_eq!(
        halden::backup::database::list(&setup.config).len(),
        backups_before + 1
    );
    assert_eq!(status(&setup)["state"], "installed");
    assert_eq!(status(&setup)["installed"], new.as_str());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_release_that_fails_its_self_test_or_carries_foreign_files_is_refused() {
    let github = FakeGithub::default();
    let base = serve_github(github.clone()).await;
    let signer = Signer::new();
    let key = signer.public();
    let setup = set_up().await;
    let work = tempfile::tempdir().unwrap();

    // Says it is another version than the release.
    let liar = package(work.path(), &ahead(2), &fake_program("9.9.9"), &[]);
    publish(&github, &base, &signer, &ahead(2), liar, false);
    let (ok, out) = halden(&setup, &base, Some(&key), &["update", "--yes"]);
    assert!(!ok && out.contains("says it is"), "{out}");
    assert_eq!(std::fs::read(&setup.installed).unwrap(), b"the old program");

    // Can't use the database.
    let broken = package(
        work.path(),
        &ahead(3),
        &format!(
            "#!/bin/sh\n[ \"$1\" = --version ] && echo halden {} && exit 0\necho no >&2\nexit 1\n",
            ahead(3)
        ),
        &[],
    );
    publish(&github, &base, &signer, &ahead(3), broken, false);
    let (ok, out) = halden(&setup, &base, Some(&key), &["update", "--yes"]);
    assert!(!ok && out.contains("can't use this database"), "{out}");

    // Signed, but with a file outside its own folder.
    let foreign = package(
        work.path(),
        &ahead(4),
        &fake_program(&ahead(4)),
        &["evil.sh"],
    );
    publish(&github, &base, &signer, &ahead(4), foreign, false);
    let (ok, out) = halden(&setup, &base, Some(&key), &["update", "--yes"]);
    assert!(!ok && out.contains("not a Halden server package"), "{out}");
    assert_eq!(std::fs::read(&setup.installed).unwrap(), b"the old program");
}

/// The app looks for an update, the owner confirms with the password, the server leaves a
/// request, and root's updater (here run by hand, as systemd's path unit would) installs it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_asked_for_in_the_app() {
    let github = FakeGithub::default();
    let base = serve_github(github.clone()).await;
    let signer = Signer::new();
    let key = signer.public();
    let setup = set_up().await;
    let work = tempfile::tempdir().unwrap();
    let new = ahead(1);
    let release = package(work.path(), &new, &fake_program(&new), &[]);
    publish(&github, &base, &signer, &new, release, false);

    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let mut config = setup.config.clone();
    config.server.bind = "127.0.0.1".parse().unwrap();
    config.server.port = port;
    config.network.bonjour = false;
    config.save(&setup.config_path).unwrap();
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

    let mut server = Command::new(env!("CARGO_BIN_EXE_halden"))
        .arg("--config")
        .arg(&setup.config_path)
        .arg("serve")
        .env("HALDEN_UPDATE_API", format!("{base}/releases"))
        .env("HALDEN_UPDATE_KEY", &key)
        .env("HALDEN_UPDATER_INSTALLED", "1")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let http = client(
        *tls::identity_fingerprint(&config).unwrap().as_bytes(),
        &[&rustls::version::TLS13],
    );
    let api = format!("https://127.0.0.1:{port}/api/v1");
    let mut up = false;
    for _ in 0..200 {
        if http.get(format!("{api}/health")).send().await.is_ok() {
            up = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(up, "the server did not come up");
    let token: Value = http
        .post(format!("{api}/auth/login"))
        .json(&json!({ "username": "lucas", "password": LUCAS_PASSWORD, "device": iphone() }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let token = token["token"].as_str().unwrap().to_string();

    let info: Value = http
        .get(format!("{api}/admin/update"))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(info["running"], halden::VERSION);
    assert_eq!(info["canInstall"], true, "{info}");
    assert_eq!(info["state"], "unknown");

    // Nothing to install before looking.
    let early = http
        .post(format!("{api}/admin/update/install"))
        .bearer_auth(&token)
        .json(&json!({ "currentPassword": LUCAS_PASSWORD }))
        .send()
        .await
        .unwrap();
    assert_eq!(early.status(), 409);

    let checked: Value = http
        .post(format!("{api}/admin/update/check"))
        .bearer_auth(&token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(checked["state"], "available", "{checked}");
    assert_eq!(checked["latest"], new.as_str());
    assert_eq!(checked["beta"], false);
    assert!(checked["testVersion"].is_null(), "{checked}");

    let unconfirmed = http
        .post(format!("{api}/admin/update/install"))
        .bearer_auth(&token)
        .json(&json!({}))
        .send()
        .await
        .unwrap();
    assert_eq!(unconfirmed.status(), 403);
    let request = setup.config.storage.data_dir.join("update-requested");
    assert!(!request.exists());

    let asked = http
        .post(format!("{api}/admin/update/install"))
        .bearer_auth(&token)
        .json(&json!({ "currentPassword": LUCAS_PASSWORD }))
        .send()
        .await
        .unwrap();
    assert_eq!(asked.status(), 202);
    assert!(request.exists());
    common::stop_process(&mut server);

    // What halden-update-request.service runs when the request appears.
    let (ok, out) = halden(&setup, &base, Some(&key), &["update", "--from-app"]);
    assert!(ok, "{out}");
    assert!(!request.exists(), "the request is used up");
    assert_eq!(
        std::fs::read_to_string(&setup.installed).unwrap(),
        fake_program(&new)
    );
    // Without a request, nothing happens.
    std::fs::write(&setup.installed, "the old program").unwrap();
    let (ok, _) = halden(&setup, &base, Some(&key), &["update", "--from-app"]);
    assert!(ok);
    assert_eq!(std::fs::read(&setup.installed).unwrap(), b"the old program");
}
