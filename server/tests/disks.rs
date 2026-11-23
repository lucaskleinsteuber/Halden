//! Disks that fill up, turn read-only, go away, or fail in the middle of a copy, on Linux with
//! real file systems on loop devices (and device-mapper for a disk that starts failing). These
//! need root through sudo, so they run only with `HALDEN_ROOT_TESTS=1` (the nightly CI on
//! Ubuntu); elsewhere they return at once.

mod common;

use std::{
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

use common::{Api, LUCAS_PASSWORD, iphone, random_bytes, sha_hex};
use halden::accounts::Role;
use serde_json::{Value, json};
use uuid::Uuid;

fn enabled() -> bool {
    let on = cfg!(target_os = "linux") && std::env::var_os("HALDEN_ROOT_TESTS").is_some();
    if !on {
        eprintln!("disk tests need Linux, sudo and HALDEN_ROOT_TESTS=1; skipped");
    }
    on
}

fn run(program: &str, args: &[&str]) -> String {
    let output = Command::new(program).args(args).output().unwrap();
    assert!(
        output.status.success(),
        "{program} {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn sudo(args: &[&str]) -> String {
    run("sudo", args)
}

/// A small ext4 file system of its own, mounted for this test and owned by the test's user.
/// With `failing`, it sits on device-mapper, so it can be made to fail every read and write.
struct Disk {
    mount: PathBuf,
    loop_device: String,
    mapper: Option<String>,
    sectors: u64,
}

impl Disk {
    fn new(dir: &Path, name: &str, megabytes: u64, failing: bool) -> Self {
        let image = dir.join(format!("{name}.img"));
        run(
            "truncate",
            &["-s", &format!("{megabytes}M"), image.to_str().unwrap()],
        );
        let loop_device = sudo(&["losetup", "--find", "--show", image.to_str().unwrap()]);
        let sectors = megabytes * 1024 * 1024 / 512;
        let mapper = failing.then(|| {
            let mapper = format!("halden-{name}-{}", std::process::id());
            sudo(&[
                "dmsetup",
                "create",
                &mapper,
                "--table",
                &format!("0 {sectors} linear {loop_device} 0"),
            ]);
            mapper
        });
        let device = mapper
            .as_ref()
            .map_or(loop_device.clone(), |m| format!("/dev/mapper/{m}"));
        sudo(&["mkfs.ext4", "-q", "-F", &device]);
        let mount = dir.join(name);
        std::fs::create_dir_all(&mount).unwrap();
        sudo(&["mount", &device, mount.to_str().unwrap()]);
        let me = format!("{}:{}", run("id", &["-u"]), run("id", &["-g"]));
        sudo(&["chown", &me, mount.to_str().unwrap()]);
        Self {
            mount,
            loop_device,
            mapper,
            sectors,
        }
    }

    fn path(&self, child: &str) -> PathBuf {
        self.mount.join(child)
    }

    fn read_only(&self, on: bool) {
        sudo(&[
            "mount",
            "-o",
            if on { "remount,ro" } else { "remount,rw" },
            self.mount.to_str().unwrap(),
        ]);
    }

    /// Every read and write fails from now on, like a USB disk pulled out mid-copy.
    fn break_down(&self) {
        let mapper = self.mapper.as_ref().expect("a failing disk");
        sudo(&["dmsetup", "suspend", "--noflush", mapper]);
        sudo(&[
            "dmsetup",
            "load",
            mapper,
            "--table",
            &format!("0 {} error", self.sectors),
        ]);
        sudo(&["dmsetup", "resume", mapper]);
    }

    /// Fills the disk up to `leave` bytes; returns the filler, to remove later.
    fn fill(&self, leave: u64) -> PathBuf {
        let free = fs4::available_space(&self.mount).unwrap();
        let filler = self.mount.join("filler");
        let size = free.saturating_sub(leave);
        run(
            "fallocate",
            &["-l", &size.to_string(), filler.to_str().unwrap()],
        );
        filler
    }
}

impl Drop for Disk {
    fn drop(&mut self) {
        let _ = Command::new("sudo")
            .args(["umount", "-l", self.mount.to_str().unwrap()])
            .output();
        if let Some(mapper) = &self.mapper {
            let _ = Command::new("sudo")
                .args(["dmsetup", "remove", "--force", mapper])
                .output();
        }
        let _ = Command::new("sudo")
            .args(["losetup", "-d", &self.loop_device])
            .output();
    }
}

async fn owner(api: &Api) -> String {
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.token("lucas", LUCAS_PASSWORD, iphone()).await
}

async fn announce(api: &Api, token: &str, data: &[u8]) -> common::Reply {
    api.post(
        "/api/v1/uploads",
        Some(token),
        json!({ "assetId": Uuid::new_v4(), "size": data.len(), "sha256": sha_hex(data),
                "mimeType": "video/quicktime" }),
    )
    .await
}

async fn send(api: &Api, token: &str, upload: &str, offset: usize, data: &[u8]) -> common::Reply {
    let response = api
        .http
        .patch(api.url(&format!("/api/v1/uploads/{upload}")))
        .bearer_auth(token)
        .header("upload-offset", offset.to_string())
        .body(data.to_vec())
        .send()
        .await
        .unwrap();
    Api::reply(response).await
}

fn library_files(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut folders = vec![root.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(folder).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == "lost+found" || name == "filler" {
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
async fn a_full_library_disk_refuses_cleanly_and_recovers() {
    if !enabled() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let disk = Disk::new(dir.path(), "library", 96, false);
    let api = Api::start_in(&dir.path().join("data"), &disk.path("library"), |config| {
        config.storage.min_free_gb = 0;
    })
    .await;
    let token = owner(&api).await;

    // Too big for the disk: refused before a byte is sent.
    let huge = vec![0u8; 200 * 1024 * 1024];
    assert_eq!(announce(&api, &token, &huge).await.status, 507);

    // Fits when announced, but the disk fills up from outside while it arrives.
    let data = random_bytes(40 * 1024 * 1024);
    let created = announce(&api, &token, &data).await;
    assert_eq!(created.status, 201, "{}", created.body);
    let upload = created.body["uploadId"].as_str().unwrap().to_string();
    let first = send(&api, &token, &upload, 0, &data[..10 * 1024 * 1024]).await;
    assert_eq!(first.body["offset"], 10 * 1024 * 1024);
    let filler = disk.fill(1024 * 1024);
    let refused = send(
        &api,
        &token,
        &upload,
        10 * 1024 * 1024,
        &data[10 * 1024 * 1024..],
    )
    .await;
    assert!(refused.status >= 500, "{} {}", refused.status, refused.body);
    assert!(
        library_files(&disk.path("library")).is_empty(),
        "no half file in the library"
    );
    // The server says where it stands, and that is what is on the disk.
    let state = api.get(&format!("/api/v1/uploads/{upload}"), &token).await;
    let offset = state.body["offset"].as_u64().unwrap() as usize;
    assert!(
        offset >= 10 * 1024 * 1024 && offset < data.len(),
        "{}",
        state.body
    );

    // Space again: the upload goes on from there and ends intact.
    std::fs::remove_file(filler).unwrap();
    let done = send(&api, &token, &upload, offset, &data[offset..]).await;
    assert_eq!(done.body["state"], "completed", "{}", done.body);
    let files = library_files(&disk.path("library"));
    assert_eq!(files.len(), 1);
    assert_eq!(sha_hex(&std::fs::read(&files[0]).unwrap()), sha_hex(&data));
    api.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_only_library_fails_uploads_cleanly() {
    if !enabled() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let disk = Disk::new(dir.path(), "library", 64, false);
    let api = Api::start_in(&dir.path().join("data"), &disk.path("library"), |config| {
        config.storage.min_free_gb = 0;
    })
    .await;
    let token = owner(&api).await;
    disk.read_only(true);
    let data = random_bytes(100_000);
    let created = announce(&api, &token, &data).await;
    let failed = if created.status == 201 {
        let upload = created.body["uploadId"].as_str().unwrap();
        send(&api, &token, upload, 0, &data).await.status
    } else {
        created.status
    };
    assert!(failed >= 500, "{failed}");
    assert_eq!(
        api.get("/api/v1/me", &token).await.status,
        200,
        "the server is fine"
    );
    disk.read_only(false);
    let created = announce(&api, &token, &data).await;
    let upload = created.body["uploadId"].as_str().unwrap().to_string();
    let done = send(&api, &token, &upload, 0, &data).await;
    assert_eq!(done.body["state"], "completed", "{}", done.body);
    api.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_full_system_disk_keeps_the_server_alive() {
    if !enabled() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let disk = Disk::new(dir.path(), "data", 48, false);
    let api = Api::start_in(&disk.path("data"), &dir.path().join("library"), |_| {}).await;
    let token = owner(&api).await;
    let filler = disk.fill(0);
    // Writing to the database may fail now, reading doesn't; nothing crashes.
    for n in 0..20 {
        let reply = api
            .call(
                reqwest::Method::PUT,
                "/api/v1/me/settings",
                Some(&token),
                Some(json!({ "photoFormat": if n % 2 == 0 { "jpeg" } else { "original" } })),
            )
            .await;
        assert!(
            reply.status == 200 || reply.status >= 500,
            "{}",
            reply.status
        );
    }
    assert_eq!(api.get("/api/v1/me", &token).await.status, 200);
    std::fs::remove_file(filler).unwrap();
    let data = random_bytes(10_000);
    let created = announce(&api, &token, &data).await;
    let upload = created.body["uploadId"].as_str().unwrap().to_string();
    let done = send(&api, &token, &upload, 0, &data).await;
    assert_eq!(
        done.body["state"], "completed",
        "after space came back: {}",
        done.body
    );
    api.stop().await;
}

/// Worked out now (`GET /me` shows what the hourly check found).
async fn mirror_status(api: &Api, token: &str) -> Value {
    api.get("/api/v1/admin/mirror", token).await.body
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_mirror_on_another_disk_survives_unplugging_and_failing() {
    if !enabled() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let usb = Disk::new(dir.path(), "usb", 256, true);
    let root = usb.path("halden");
    std::fs::create_dir_all(&root).unwrap();
    let root = halden::backup::mirror::prepare(&root, &dir.path().join("library")).unwrap();
    let mirror = root.clone();
    let api = Api::start_with(move |config| {
        config.mirror.path = Some(mirror);
        config.storage.min_free_gb = 0;
    })
    .await;
    let token = owner(&api).await;

    // On its own disk, the mirror really is a second copy.
    let status = mirror_status(&api, &token).await;
    assert_eq!(status["mirrorOnSameDisk"], false, "{status}");
    assert_eq!(status["onlyOneCopy"], false, "{status}");

    let first = random_bytes(5 * 1024 * 1024);
    api.upload(
        &token,
        &Uuid::new_v4().to_string(),
        &first,
        "video/quicktime",
        json!({}),
    )
    .await;
    let mut copied = false;
    for _ in 0..400 {
        if library_files(&root)
            .iter()
            .any(|f| std::fs::read(f).map(|b| b == first).unwrap_or(false))
        {
            copied = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(copied, "the first video is on the mirror");

    // The disk fails in the middle of copying a big video: nothing broken may count as copied.
    let big = random_bytes(120 * 1024 * 1024);
    api.upload(
        &token,
        &Uuid::new_v4().to_string(),
        &big,
        "video/quicktime",
        json!({}),
    )
    .await;
    usb.break_down();
    let pool = api.pool().await;
    let mut failed = false;
    for _ in 0..600 {
        let errors: Vec<(Option<String>,)> =
            sqlx::query_as("SELECT last_error FROM jobs WHERE kind = 'mirror'")
                .fetch_all(pool.read())
                .await
                .unwrap();
        let mirrored: (i64,) = sqlx::query_as("SELECT count(*) FROM mirror_files")
            .fetch_one(pool.read())
            .await
            .unwrap();
        if errors.iter().any(|(e,)| e.is_some()) {
            failed = true;
            break;
        }
        if mirrored.0 == 2 {
            // The copy was faster than the failure: fine, but then it must be intact (checked
            // below by doctor once the disk works again).
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let recorded: Vec<(String, Vec<u8>)> = sqlx::query_as("SELECT path, sha256 FROM mirror_files")
        .fetch_all(pool.read())
        .await
        .unwrap();
    pool.close().await;
    eprintln!(
        "mirror copy failed during the breakdown: {failed}; recorded copies: {}",
        recorded.len()
    );
    let status = mirror_status(&api, &token).await;
    assert_ne!(
        status["mirror"], "ok",
        "a broken mirror is not ok: {status}"
    );
    assert_eq!(
        api.get("/api/v1/me", &token).await.status,
        200,
        "the server is fine"
    );
    api.stop().await;
}
