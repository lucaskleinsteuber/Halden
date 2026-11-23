//! The `halden` commands, run as the real program the way the owner types them in the terminal:
//! accounts, pairing, devices, the security log, backups, the mirror and status.

mod common;

use std::{
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

use common::{Api, LUCAS_PASSWORD, iphone, random_bytes};
use halden::accounts::Role;
use serde_json::json;
use uuid::Uuid;

/// Runs `halden --config <path> <args>`, writing `input` to its standard input.
fn halden(config_path: &Path, args: &[&str], input: &str) -> (bool, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_halden"))
        .arg("--config")
        .arg(config_path)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    (
        output.status.success(),
        format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ),
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn accounts_in_the_terminal() {
    let api = Api::start().await;
    let path = api.config_path.clone();
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;

    let (ok, out) = halden(
        &path,
        &["user", "add", "anna", "--display-name", "Anna K"],
        "anna's first password\n",
    );
    assert!(ok, "{out}");
    let (ok, out) = halden(&path, &["user", "add", "anna"], "another password 1\n");
    assert!(!ok && out.contains("taken"), "{out}");
    let (ok, out) = halden(&path, &["user", "add", "x"], "short\n");
    assert!(!ok, "a too short password or name is refused: {out}");
    let (ok, out) = halden(&path, &["user", "add", "kid", "--no-password"], "");
    assert!(ok, "{out}");
    let (ok, out) = halden(&path, &["user", "list"], "");
    assert!(
        ok && out.contains("anna") && out.contains("Anna K") && out.contains("kid"),
        "{out}"
    );

    // Anna signs in with the password set in the terminal.
    let anna = api
        .token(
            "anna",
            "anna's first password",
            common::device("Anna's iPhone", "install-anna"),
        )
        .await;
    let (ok, out) = halden(
        &path,
        &["user", "passwd", "anna", "--sign-out"],
        "anna's second password\n",
    );
    assert!(ok, "{out}");
    assert_eq!(api.get("/api/v1/me", &anna).await.status, 401, "signed out");
    api.token(
        "anna",
        "anna's second password",
        common::device("Anna's iPhone", "install-anna"),
    )
    .await;

    let (ok, out) = halden(&path, &["user", "role", "anna", "owner"], "");
    assert!(ok, "{out}");
    let (ok, out) = halden(&path, &["user", "role", "lucas", "member"], "");
    assert!(ok, "{out}");
    // The last owner can't go.
    let (ok, out) = halden(&path, &["user", "role", "anna", "member"], "");
    assert!(!ok && out.contains("owner"), "{out}");
    // Without a terminal to ask in, deleting needs --yes.
    let (ok, out) = halden(&path, &["user", "remove", "kid"], "kid\n");
    assert!(!ok && out.contains("--yes"), "{out}");
    let (ok, out) = halden(&path, &["user", "remove", "kid", "--yes"], "");
    assert!(ok, "{out}");
    let (ok, out) = halden(&path, &["user", "list"], "");
    assert!(ok && !out.contains("kid"), "{out}");

    // The security log saw all of it.
    let (ok, out) = halden(&path, &["log", "--limit", "100"], "");
    assert!(ok, "{out}");
    for event in [
        "user created",
        "password reset",
        "role changed",
        "user deleted",
    ] {
        assert!(out.contains(event), "{event} missing in\n{out}");
    }
    let (ok, out) = halden(&path, &["log", "--user", "anna"], "");
    assert!(ok && !out.contains("kid"), "{out}");
    api.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pairing_and_devices_in_the_terminal() {
    let api = Api::start().await;
    let path = api.config_path.clone();
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;

    // `halden pair` shows the code and waits until a device uses it.
    let mut pairing = Command::new(env!("CARGO_BIN_EXE_halden"))
        .arg("--config")
        .arg(&path)
        .arg("pair")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = pairing.stdout.take().unwrap();
    let code = tokio::task::spawn_blocking(move || {
        use std::io::BufRead;
        let mut lines = std::io::BufReader::new(stdout).lines();
        let code = lines
            .by_ref()
            .map_while(Result::ok)
            .find_map(|line| {
                line.trim()
                    .strip_prefix("Code")
                    .map(|c| c.trim().to_string())
            })
            .expect("a code is shown");
        // Keep reading so the program never blocks on a full pipe.
        std::thread::spawn(move || lines.for_each(drop));
        code
    })
    .await
    .unwrap();
    let paired = api
        .post(
            "/api/v1/auth/pair",
            None,
            json!({ "code": code, "device": common::mac() }),
        )
        .await;
    assert_eq!(paired.status, 200, "{}", paired.body);
    let finished = tokio::task::spawn_blocking(move || pairing.wait().unwrap())
        .await
        .unwrap();
    assert!(finished.success(), "halden pair ends once the device is in");

    let (ok, out) = halden(&path, &["devices"], "");
    assert!(
        ok && out.contains("Lucas' iPhone") && out.contains("Lucas' Mac"),
        "{out}"
    );
    let me = api.get("/api/v1/me", &token).await;
    let id = me.body["device"]["id"].as_str().unwrap();
    let (ok, out) = halden(&path, &["devices", "revoke", &id[..8]], "");
    assert!(ok, "{out}");
    assert_eq!(api.get("/api/v1/me", &token).await.status, 401);
    let (ok, out) = halden(&path, &["pair", "--user", "nobody"], "");
    assert!(out.contains("nobody"), "{out}");
    assert!(!ok, "{out}");
    api.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn backups_mirror_and_status_in_the_terminal() {
    let api = Api::start().await;
    let path = api.config_path.clone();
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    api.upload(
        &token,
        &Uuid::new_v4().to_string(),
        &random_bytes(2000),
        "image/heic",
        json!({}),
    )
    .await;

    let (ok, out) = halden(&path, &["status"], "");
    assert!(ok, "{out}");
    assert!(
        out.contains("1 photos") && out.contains("Fingerprint"),
        "{out}"
    );
    let (ok, out) = halden(&path, &["backup", "now"], "");
    assert!(ok, "{out}");
    let (ok, out) = halden(&path, &["backup", "list"], "");
    assert!(ok && out.contains("halden-"), "{out}");
    let name = out
        .split_whitespace()
        .find(|word| word.starts_with("halden-") && word.ends_with(".db"))
        .unwrap()
        .to_string();
    // A restore needs the server stopped.
    let (ok, out) = halden(&path, &["backup", "restore", &name, "--yes"], "");
    assert!(!ok && out.contains("running"), "{out}");

    let disk = tempfile::tempdir().unwrap();
    let mirror = disk.path().to_str().unwrap();
    let (ok, out) = halden(&path, &["mirror", "set", mirror], "");
    assert!(ok, "{out}");
    assert!(disk.path().join(".halden-mirror").is_file());
    let (ok, out) = halden(&path, &["mirror", "status"], "");
    assert!(ok && out.contains("Mirror"), "{out}");
    let (ok, out) = halden(
        &path,
        &[
            "mirror",
            "set",
            api.config.storage.library_dir.to_str().unwrap(),
        ],
        "",
    );
    assert!(!ok, "the library can't be its own mirror: {out}");
    let (ok, out) = halden(&path, &["mirror", "off"], "");
    assert!(ok, "{out}");

    let _folders = api.stop_keeping_files().await;
    let (ok, out) = halden(&path, &["backup", "restore", &name, "--yes"], "");
    assert!(ok, "{out}");
    let (ok, out) = halden(&path, &["status"], "");
    assert!(ok && out.contains("not running"), "{out}");
}
