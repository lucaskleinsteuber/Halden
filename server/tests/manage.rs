//! Looking after the server: settings picked up without stopping the process, the admin routes
//! the apps use, and `doctor`.

mod common;

use std::time::Duration;

use futures_util::StreamExt;

use common::{
    ANNA_PASSWORD, Api, LUCAS_PASSWORD, device, iphone, random_bytes, set_setting, sha_hex,
};
use halden::{accounts::Role, config::Config};
use reqwest::Method;
use serde_json::json;
use uuid::Uuid;

async fn owner_and_member(api: &Api) -> (String, String) {
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    (
        api.token("lucas", LUCAS_PASSWORD, iphone()).await,
        api.token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna"),
        )
        .await,
    )
}

#[tokio::test]
async fn a_changed_config_file_is_picked_up_on_the_same_port() {
    let mut api = Api::start_supervised().await;
    let (owner, _) = owner_and_member(&api).await;
    let port = api.server.addr.port();
    let before = std::fs::read_to_string(&api.config_path).unwrap();

    // `halden config set` while the server runs.
    set_setting(&api.config_path, "library.trash_days", "45");
    let generation = api.restarted_after(0).await;
    assert_eq!(generation, 1);
    let settings = api.get("/api/v1/admin/config", &owner).await;
    let trash = settings.body["settings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == "library.trash_days")
        .unwrap()
        .clone();
    if trash["value"] != 45 {
        let status = api.get("/api/v1/admin/status", &owner).await;
        panic!("the new settings were not used: {}", status.body["configProblem"]);
    }
    assert_eq!(trash["default"], 30);
    assert_eq!(trash["access"], "password");
    // Same port, the device's token still works, the file kept its other contents.
    assert_eq!(api.server.addr.port(), port);
    assert_eq!(api.get("/api/v1/me", &owner).await.status, 200);
    let after = std::fs::read_to_string(&api.config_path).unwrap();
    assert!(after.contains("trash_days = 45"));
    assert!(after.starts_with(before.lines().next().unwrap()));

    // A broken file is not used: the server keeps running with its settings and says why.
    std::fs::write(
        &api.config_path,
        format!("{after}\n[library]\nnonsense = 1\n"),
    )
    .unwrap();
    let mut problem = None;
    for _ in 0..100 {
        let status = api.get("/api/v1/admin/status", &owner).await;
        if let Some(text) = status.body["configProblem"].as_str() {
            problem = Some(text.to_string());
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(problem.is_some(), "the problem is reported");
    assert_eq!(api.generation(), 1, "no restart with a broken file");
    let doctor = api.get("/api/v1/admin/doctor", &owner).await;
    assert_eq!(doctor.body["level"], "problem");

    // Fixed again: picked up.
    std::fs::write(&api.config_path, &after).unwrap();
    set_setting(&api.config_path, "library.trash_days", "50");
    api.restarted_after(1).await;
    let status = api.get("/api/v1/admin/status", &owner).await;
    assert!(status.body["configProblem"].is_null(), "{}", status.body);
    api.stop().await;
}

#[tokio::test]
async fn the_owner_changes_settings_from_the_app() {
    let mut api = Api::start_supervised().await;
    let (owner, member) = owner_and_member(&api).await;

    // Members can't.
    let refused = api
        .call(
            Method::PATCH,
            "/api/v1/admin/config",
            Some(&member),
            Some(json!({ "changes": { "jobs.workers": 2 } })),
        )
        .await;
    assert_eq!(refused.status, 403);
    assert_eq!(api.get("/api/v1/admin/status", &member).await.status, 403);

    // Folders and the port only in the terminal.
    let terminal = api
        .call(
            Method::PATCH,
            "/api/v1/admin/config",
            Some(&owner),
            Some(json!({ "changes": { "server.port": 1234 } })),
        )
        .await;
    assert_eq!(terminal.status, 403);
    assert!(
        terminal.body["message"]
            .as_str()
            .unwrap()
            .contains("terminal")
    );

    // Unknown settings and wrong types.
    for changes in [
        json!({ "library.nope": 1 }),
        json!({ "jobs.workers": "two" }),
    ] {
        let wrong = api
            .call(
                Method::PATCH,
                "/api/v1/admin/config",
                Some(&owner),
                Some(json!({ "changes": changes })),
            )
            .await;
        assert_eq!(wrong.status, 422, "{}", wrong.body);
    }

    // Opening the server up needs the password again.
    let unconfirmed = api
        .call(
            Method::PATCH,
            "/api/v1/admin/config",
            Some(&owner),
            Some(json!({ "changes": { "auth.password_login": false, "jobs.workers": 2 } })),
        )
        .await;
    assert_eq!(unconfirmed.status, 403);
    assert_eq!(unconfirmed.error(), "password_required");
    assert_eq!(api.generation(), 0, "nothing was changed");

    let changed = api
        .call(
            Method::PATCH,
            "/api/v1/admin/config",
            Some(&owner),
            Some(json!({
                "changes": { "auth.password_login": false, "jobs.workers": 2 },
                "currentPassword": LUCAS_PASSWORD,
            })),
        )
        .await;
    assert_eq!(changed.status, 200, "{}", changed.body);
    assert_eq!(changed.body["restarting"], true);
    api.restarted_after(0).await;
    let config = Config::load(&api.config_path).unwrap();
    assert!(!config.auth.password_login);
    assert_eq!(config.jobs.workers, 2);
    // The new setting is in force: password sign-in is now refused.
    let login = api
        .login(
            "anna",
            ANNA_PASSWORD,
            device("Anna's Mac", "install-anna-mac"),
        )
        .await;
    assert_eq!(login.error(), "password_login_disabled");
    // And it is in the security log.
    let log = api.get("/api/v1/security-log", &owner).await;
    assert!(
        log.body["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["event"] == "settings_changed"),
        "{}",
        log.body
    );

    // Back to the default with null.
    let reset = api
        .call(
            Method::PATCH,
            "/api/v1/admin/config",
            Some(&owner),
            Some(json!({ "changes": { "jobs.workers": null } })),
        )
        .await;
    assert_eq!(reset.status, 200, "{}", reset.body);
    api.restarted_after(1).await;
    assert_eq!(Config::load(&api.config_path).unwrap().jobs.workers, 1);
    api.stop().await;
}

#[tokio::test]
async fn an_upload_cut_off_by_a_restart_continues() {
    let mut api = Api::start_supervised().await;
    let (owner, _) = owner_and_member(&api).await;
    let data = random_bytes(3_000_000);
    let id = Uuid::new_v4().to_string();
    let created = api
        .post(
            "/api/v1/uploads",
            Some(&owner),
            json!({ "assetId": id, "size": data.len(), "sha256": sha_hex(&data),
                    "mimeType": "image/heic", "metadata": {} }),
        )
        .await;
    let upload = created.body["uploadId"].as_str().unwrap().to_string();
    // A slow phone: 100 KB every 150 ms, still sending when the server restarts (running
    // requests get 2 s to finish, this one needs 4.5 s).
    let chunks: Vec<Result<Vec<u8>, std::io::Error>> =
        data.chunks(100_000).map(|c| Ok(c.to_vec())).collect();
    let slow = futures_util::stream::iter(chunks).then(|chunk| async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        chunk
    });
    let sending = tokio::spawn(
        api.http
            .patch(api.url(&format!("/api/v1/uploads/{upload}")))
            .bearer_auth(&owner)
            .header("upload-offset", "0")
            .body(reqwest::Body::wrap_stream(slow))
            .send(),
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    let restart = api
        .post("/api/v1/admin/restart", Some(&owner), json!({}))
        .await;
    assert_eq!(restart.status, 202);
    api.restarted_after(0).await;
    // The phone's request ended somehow (cut off, or answered with what arrived).
    let _ = sending.await.unwrap();

    let state = api.get(&format!("/api/v1/uploads/{upload}"), &owner).await;
    let offset = state.body["offset"]
        .as_u64()
        .unwrap_or_else(|| panic!("{} {}", state.status, state.body));
    assert!(offset > 0 && offset < data.len() as u64, "{}", state.body);
    let rest = api
        .http
        .patch(api.url(&format!("/api/v1/uploads/{upload}")))
        .bearer_auth(&owner)
        .header("upload-offset", offset.to_string())
        .body(data[offset as usize..].to_vec())
        .send()
        .await
        .unwrap();
    let done = Api::reply(rest).await;
    assert_eq!(done.body["state"], "completed", "{}", done.body);
    api.stop().await;
}

#[tokio::test]
async fn status_backups_jobs_mirror_and_doctor() {
    let mut api = Api::start_supervised().await;
    let (owner, _) = owner_and_member(&api).await;
    let data = random_bytes(10_000);
    api.upload(
        &owner,
        &Uuid::new_v4().to_string(),
        &data,
        "image/heic",
        json!({}),
    )
    .await;

    let status = api.get("/api/v1/admin/status", &owner).await;
    assert_eq!(status.status, 200, "{}", status.body);
    assert_eq!(status.body["name"], "testbox");
    assert!(status.body["libraryDisk"]["freeBytes"].as_u64().unwrap() > 0);
    let lucas = status.body["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["username"] == "lucas")
        .unwrap()
        .clone();
    assert_eq!(lucas["photos"], 1);
    assert_eq!(status.body["backup"]["onlyOneCopy"], true);

    // Backups: one from the start, one more on request.
    let made = api
        .post("/api/v1/admin/backups", Some(&owner), json!({}))
        .await;
    assert_eq!(made.status, 201, "{}", made.body);
    let list = api.get("/api/v1/admin/backups", &owner).await;
    assert!(!list.body["backups"].as_array().unwrap().is_empty());

    // A failed job can be tried again.
    let pool = api.pool().await;
    sqlx::query(
        "INSERT INTO jobs (kind, asset_id, user_id, state, attempts, run_after, last_error, \
         created_at, updated_at) SELECT 'thumbnail', id, user_id, 'failed', 6, 0, 'ffmpeg broke', 0, 0 \
         FROM assets LIMIT 1 ON CONFLICT (kind, asset_id) DO UPDATE SET state = 'failed', \
         last_error = 'ffmpeg broke'",
    )
    .execute(pool.write())
    .await
    .unwrap();
    let failed = api.get("/api/v1/admin/jobs", &owner).await;
    assert_eq!(
        failed.body["jobs"].as_array().unwrap().len(),
        1,
        "{}",
        failed.body
    );
    assert_eq!(failed.body["jobs"][0]["lastError"], "ffmpeg broke");
    let retried = api
        .post("/api/v1/admin/jobs/retry", Some(&owner), json!({}))
        .await;
    assert_eq!(retried.body["retried"], 1);
    pool.close().await;

    // The mirror, from the app, with the password.
    let disk = tempfile::tempdir().unwrap();
    let without = api
        .call(
            Method::PUT,
            "/api/v1/admin/mirror",
            Some(&owner),
            Some(json!({ "path": disk.path() })),
        )
        .await;
    assert_eq!(without.error(), "password_required");
    let inside = api
        .call(
            Method::PUT,
            "/api/v1/admin/mirror",
            Some(&owner),
            Some(json!({ "path": api.config.storage.library_dir.join("lucas"), "currentPassword": LUCAS_PASSWORD })),
        )
        .await;
    assert_eq!(inside.status, 422, "a mirror inside the library is refused");
    std::fs::create_dir_all(api.config.storage.library_dir.join("lucas")).ok();
    let set = api
        .call(
            Method::PUT,
            "/api/v1/admin/mirror",
            Some(&owner),
            Some(json!({ "path": disk.path(), "currentPassword": LUCAS_PASSWORD })),
        )
        .await;
    assert_eq!(set.status, 200, "{}", set.body);
    assert_eq!(set.body["mirrorOnSameDisk"], true);
    assert!(disk.path().join(".halden-mirror").is_file());
    api.restarted_after(0).await;
    let mirror = api.get("/api/v1/admin/mirror", &owner).await;
    assert!(mirror.body["path"].is_string(), "{}", mirror.body);
    // The original arrives on the mirror.
    let mut copied = false;
    for _ in 0..200 {
        let found = walk(disk.path())
            .into_iter()
            .any(|f| std::fs::read(&f).map(|b| b == data).unwrap_or(false));
        if found {
            copied = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(copied, "the photo was copied to the new mirror");

    let off = api
        .call(
            Method::DELETE,
            "/api/v1/admin/mirror",
            Some(&owner),
            Some(json!({ "currentPassword": LUCAS_PASSWORD })),
        )
        .await;
    assert_eq!(off.status, 200, "{}", off.body);
    api.restarted_after(1).await;
    assert!(
        Config::load(&api.config_path)
            .unwrap()
            .mirror
            .path
            .is_none()
    );

    let doctor = api.get("/api/v1/admin/doctor", &owner).await;
    assert_eq!(doctor.status, 200);
    let checks = doctor.body["checks"].as_array().unwrap();
    assert!(
        checks
            .iter()
            .any(|c| c["id"] == "database" && c["level"] == "ok")
    );
    assert!(
        checks
            .iter()
            .any(|c| c["id"] == "settings_file" && c["level"] == "ok")
    );
    api.stop().await;
}

fn walk(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    let mut folders = vec![dir.to_path_buf()];
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

#[tokio::test]
async fn a_server_not_started_from_a_file_cant_change_settings() {
    let api = Api::start().await;
    let (owner, _) = owner_and_member(&api).await;
    let refused = api
        .call(
            Method::PATCH,
            "/api/v1/admin/config",
            Some(&owner),
            Some(json!({ "changes": { "jobs.workers": 2 } })),
        )
        .await;
    assert_eq!(refused.status, 409);
    let settings = api.get("/api/v1/admin/config", &owner).await;
    assert_eq!(settings.body["canChange"], false);
    api.stop().await;
}

fn halden(config_path: &std::path::Path, args: &[&str]) -> (bool, String) {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_halden"))
        .arg("--config")
        .arg(config_path)
        .args(args)
        .output()
        .unwrap();
    (
        output.status.success(),
        format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ),
    )
}

#[tokio::test]
async fn config_and_doctor_in_the_terminal() {
    let api = Api::start().await;
    let (owner, _) = owner_and_member(&api).await;
    let path = api.config_path.clone();
    let comment = "# my own note\n";
    let text = std::fs::read_to_string(&path).unwrap();
    std::fs::write(&path, format!("{comment}{text}")).unwrap();

    let (ok, out) = halden(&path, &["config", "set", "library.trash_days", "60"]);
    assert!(ok, "{out}");
    assert!(out.contains("library.trash_days is now 60"), "{out}");
    let (ok, out) = halden(&path, &["config", "get", "library.trash_days"]);
    assert!(ok && out.trim() == "60", "{out}");
    let (ok, out) = halden(&path, &["config", "list"]);
    assert!(
        ok && out.contains("library.trash_days") && out.contains("60 *"),
        "{out}"
    );
    let (ok, out) = halden(&path, &["config", "set", "library.trash_days", "soon"]);
    assert!(!ok && out.contains("whole number"), "{out}");
    let (ok, out) = halden(&path, &["config", "set", "library.nothing", "1"]);
    assert!(!ok && out.contains("no setting"), "{out}");
    let (ok, _) = halden(&path, &["config", "reset", "library.trash_days"]);
    assert!(ok);
    assert!(std::fs::read_to_string(&path).unwrap().starts_with(comment));
    assert_eq!(Config::load(&path).unwrap().library.trash_days, 30);

    // A fresh server has warnings (no mirror) but no problems.
    let (ok, out) = halden(&path, &["doctor"]);
    assert!(ok, "{out}");
    assert!(
        out.contains("✓ Database") && out.contains("! Mirror"),
        "{out}"
    );

    // Every file is read back; a damaged one is found.
    let data = random_bytes(50_000);
    let asset = api
        .upload(
            &owner,
            &Uuid::new_v4().to_string(),
            &data,
            "image/heic",
            json!({}),
        )
        .await;
    assert!(asset["files"].is_array());
    let (ok, out) = halden(&path, &["doctor", "--files", "--json"]);
    assert!(ok, "{out}");
    let report: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(report["files"]["checked"], 1);
    let original = walk(&api.config.storage.library_dir)
        .into_iter()
        .find(|f| f.extension().is_some_and(|e| e == "heic"))
        .unwrap();
    let mut damaged = data.clone();
    damaged[1000] ^= 0xff;
    std::fs::write(&original, damaged).unwrap();
    std::fs::write(api.config.storage.library_dir.join("lucas/stray.jpg"), b"?").unwrap();
    let (ok, out) = halden(&path, &["doctor", "--files"]);
    assert!(!ok, "a damaged original is a problem: {out}");
    assert!(
        out.contains("1 damaged") && out.contains("unknown: lucas/stray.jpg"),
        "{out}"
    );
    api.stop().await;
}
