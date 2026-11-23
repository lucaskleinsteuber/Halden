//! Measures the server the way the app uses it: over pinned TLS 1.3 and HTTP/2, against the
//! release build running as its own process, with a library of 100,000 photos.
//!
//! ```sh
//! cargo build --release
//! cargo run --release --example loadtest -- ../Local/benchmarks/result.md
//! ```

use std::{
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use halden::{
    accounts::{self, NewUser, Role},
    auth::password,
    config::Config,
    db::Db,
    setup::{self, SetupOptions},
    tls,
};
use reqwest::Method;
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::CryptoProvider,
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const PASSWORD: &str = "benchmark password";
const LIBRARY_SIZE: i64 = 100_000;
const MIB: usize = 1024 * 1024;

#[derive(Debug)]
struct Pinned {
    expected: [u8; 32],
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for Pinned {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if Sha256::digest(end_entity.as_ref()).as_slice() == self.expected {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("fingerprint mismatch".into()))
        }
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn client(pin: [u8; 32]) -> reqwest::Client {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Pinned {
            expected: pin,
            provider,
        }))
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"h2".to_vec()];
    reqwest::Client::builder()
        .tls_backend_preconfigured(tls)
        .http2_adaptive_window(true)
        .build()
        .unwrap()
}

struct Server(Child);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl Server {
    /// Resident memory of the server process, in MB.
    fn rss_mb(&self) -> f64 {
        rss_mb(self.0.id())
    }
}

/// What the process really occupies (dirty memory; on macOS `footprint`), without file pages the
/// system can drop at any time (the memory-mapped database).
fn footprint_mb(pid: u32) -> Option<f64> {
    // Linux: anonymous resident memory (heap, stacks), without file pages.
    if let Ok(status) = std::fs::read_to_string(format!("/proc/{pid}/status")) {
        let line = status.lines().find(|l| l.starts_with("RssAnon:"))?;
        let kib: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
        return Some(kib / 1024.0);
    }
    let out = Command::new("footprint")
        .arg(pid.to_string())
        .output()
        .ok()?;
    let text = String::from_utf8(out.stdout).ok()?;
    let line = text.lines().find(|l| l.contains("phys_footprint:"))?;
    let value = line.split(':').nth(1)?.trim();
    let (number, unit) = value.split_once(' ')?;
    let number: f64 = number.parse().ok()?;
    Some(match unit.trim() {
        "KB" => number / 1024.0,
        "GB" => number * 1024.0,
        _ => number,
    })
}

fn rss_mb(pid: u32) -> f64 {
    Command::new("ps")
        .args(["-o", "rss=", "-p", &pid.to_string()])
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .and_then(|text| text.trim().parse::<f64>().ok())
        .map_or(0.0, |kib| kib / 1024.0)
}

/// Samples a process's memory every 20 ms until stopped; returns the peak in MB.
struct PeakMemory {
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: std::thread::JoinHandle<f64>,
}

impl PeakMemory {
    fn watch(pid: u32) -> Self {
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stop.clone();
        let thread = std::thread::spawn(move || {
            let mut peak: f64 = 0.0;
            while !flag.load(std::sync::atomic::Ordering::Relaxed) {
                peak = peak.max(rss_mb(pid));
                std::thread::sleep(Duration::from_millis(20));
            }
            peak
        });
        Self { stop, thread }
    }

    fn peak(self) -> f64 {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        self.thread.join().unwrap_or(0.0)
    }
}

struct Report {
    lines: Vec<String>,
}

impl Report {
    fn row(&mut self, what: &str, result: String, goal: &str) {
        println!("{what:<45} {result:<30} goal: {goal}");
        self.lines.push(format!("| {what} | {result} | {goal} |"));
    }
}

fn percentile(samples: &mut [Duration], p: f64) -> Duration {
    samples.sort_unstable();
    let index = ((samples.len() as f64 - 1.0) * p).round() as usize;
    samples[index]
}

fn ms(d: Duration) -> String {
    format!("{:.2} ms", d.as_secs_f64() * 1000.0)
}

#[tokio::main]
async fn main() -> Result<()> {
    let out = std::env::args().nth(1).map(PathBuf::from);
    let binary = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/release/halden");
    if !binary.exists() {
        bail!("build the server first: cargo build --release");
    }

    let dir = tempfile::tempdir()?;
    let config_path = dir.path().join("config.toml");
    setup::run(
        &config_path,
        SetupOptions {
            data_dir: Some(dir.path().join("data")),
            library_dir: Some(dir.path().join("library")),
            ..SetupOptions::default()
        },
    )
    .await?;
    let mut config = Config::load(&config_path)?;
    let port = TcpListener::bind("127.0.0.1:0")?.local_addr()?.port();
    config.server.bind = "127.0.0.1".parse()?;
    config.server.port = port;
    config.network.bonjour = false;
    config.save(&config_path)?;

    let db = Db::open(&config.db_path()).await?;
    let user = accounts::create_user(
        &db,
        NewUser {
            username: "bench",
            display_name: None,
            role: Role::Owner,
            password_hash: Some(password::hash(PASSWORD.into()).await?),
        },
    )
    .await?;
    seed(&db, &user.id).await?;

    let server = Server(
        Command::new(&binary)
            .arg("--config")
            .arg(&config_path)
            .arg("serve")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("could not start the server")?,
    );
    let pin = *tls::identity_fingerprint(&config)?.as_bytes();
    let http = client(pin);
    let base = format!("https://127.0.0.1:{port}");
    for _ in 0..200 {
        if http
            .get(format!("{base}/api/v1/health"))
            .send()
            .await
            .is_ok()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let login: Value = http
        .post(format!("{base}/api/v1/auth/login"))
        .json(&json!({ "username": "bench", "password": PASSWORD,
                        "device": { "name": "bench", "platform": "cli" } }))
        .send()
        .await?
        .json()
        .await?;
    let token = login["token"].as_str().context("no token")?.to_string();

    let mut report = Report { lines: Vec::new() };
    report.row("Library", format!("{LIBRARY_SIZE} photos"), "");
    report.row(
        "Server memory at rest",
        format!(
            "{:.0} MB resident, {:.0} MB own",
            server.rss_mb(),
            footprint_mb(server.0.id()).unwrap_or(0.0)
        ),
        "",
    );

    // The sign-in path: every request checks its token.
    let mut samples = Vec::new();
    for _ in 0..2000 {
        let start = Instant::now();
        let response = http
            .get(format!("{base}/api/v1/me"))
            .bearer_auth(&token)
            .send()
            .await?;
        response.bytes().await?;
        samples.push(start.elapsed());
    }
    let p50 = percentile(&mut samples, 0.5);
    let p99 = percentile(&mut samples, 0.99);
    report.row(
        "/me, one at a time",
        format!("p50 {} · p99 {}", ms(p50), ms(p99)),
        "p99 < 1 ms",
    );

    let started = Instant::now();
    let requests = 20_000;
    let mut tasks = tokio::task::JoinSet::new();
    for worker in 0..64 {
        let (http, base, token) = (http.clone(), base.clone(), token.clone());
        tasks.spawn(async move {
            for _ in (worker..requests).step_by(64) {
                let response = http
                    .get(format!("{base}/api/v1/me"))
                    .bearer_auth(&token)
                    .send()
                    .await
                    .unwrap();
                response.bytes().await.unwrap();
            }
        });
    }
    while tasks.join_next().await.is_some() {}
    let rate = f64::from(requests) / started.elapsed().as_secs_f64();
    report.row("/me, 64 at once", format!("{rate:.0} requests/s"), "");

    // Checking what is backed up: 1000 hashes against 100,000 photos.
    let items: Vec<Value> = (1..=1000)
        .map(|i| json!({ "assetId": seed_id(i * 97), "sha256": format!("{:064x}", i * 97) }))
        .collect();
    let body = json!({ "items": items });
    let mut samples = Vec::new();
    for _ in 0..50 {
        let start = Instant::now();
        let response: Value = http
            .post(format!("{base}/api/v1/assets/check"))
            .bearer_auth(&token)
            .json(&body)
            .send()
            .await?
            .json()
            .await?;
        samples.push(start.elapsed());
        if response["results"][0]["status"] != "backedUp" {
            bail!("unexpected check result: {}", response["results"][0]);
        }
    }
    report.row(
        "Check 1000 hashes",
        format!("p50 {}", ms(percentile(&mut samples, 0.5))),
        "< 20 ms",
    );

    // Sync: a device that starts from zero, in pages of 1000.
    let mut samples = Vec::new();
    let mut since = 0;
    let started = Instant::now();
    let mut synced = 0;
    loop {
        let start = Instant::now();
        let page: Value = http
            .get(format!("{base}/api/v1/sync?since={since}&limit=1000"))
            .bearer_auth(&token)
            .send()
            .await?
            .json()
            .await?;
        samples.push(start.elapsed());
        synced += page["assets"].as_array().map_or(0, Vec::len);
        since = page["nextSince"].as_i64().unwrap_or(since);
        if page["hasMore"] != true {
            break;
        }
    }
    let whole = started.elapsed();
    report.row(
        "Sync page of 1000 (of 100,000)",
        format!(
            "p50 {} · p99 {}",
            ms(percentile(&mut samples, 0.5)),
            ms(percentile(&mut samples, 0.99))
        ),
        "< 20 ms",
    );
    report.row(
        "Whole library from zero",
        format!("{synced} assets in {:.2} s", whole.as_secs_f64()),
        "",
    );
    let plain = http
        .get(format!("{base}/api/v1/sync?since=0&limit=1000"))
        .bearer_auth(&token)
        .send()
        .await?
        .bytes()
        .await?
        .len();
    let compressed = http
        .get(format!("{base}/api/v1/sync?since=0&limit=1000"))
        .bearer_auth(&token)
        .header("accept-encoding", "br")
        .send()
        .await?
        .bytes()
        .await?
        .len();
    report.row(
        "Sync page size, plain → brotli",
        format!("{} KB → {} KB", plain / 1000, compressed / 1000),
        "",
    );

    // Thumbnails: one by one, many at once, and in bulk.
    let thumbnails = seed_thumbnails(&db, &config, &user.id, 1000).await?;
    let mut samples = Vec::new();
    for sha in thumbnails.iter().cycle().take(2000) {
        let start = Instant::now();
        http.get(format!("{base}/api/v1/files/{sha}"))
            .bearer_auth(&token)
            .send()
            .await?
            .bytes()
            .await?;
        samples.push(start.elapsed());
    }
    report.row(
        "One thumbnail (30 KB)",
        format!(
            "p50 {} · p99 {}",
            ms(percentile(&mut samples, 0.5)),
            ms(percentile(&mut samples, 0.99))
        ),
        "p99 < 2 ms",
    );
    let started = Instant::now();
    let mut tasks = tokio::task::JoinSet::new();
    let shared = Arc::new(thumbnails.clone());
    for worker in 0..64 {
        let (http, base, token, shared) =
            (http.clone(), base.clone(), token.clone(), shared.clone());
        tasks.spawn(async move {
            for sha in shared.iter().skip(worker).step_by(64) {
                http.get(format!("{base}/api/v1/files/{sha}"))
                    .bearer_auth(&token)
                    .send()
                    .await
                    .unwrap()
                    .bytes()
                    .await
                    .unwrap();
            }
        });
    }
    while tasks.join_next().await.is_some() {}
    let rate = thumbnails.len() as f64 / started.elapsed().as_secs_f64();
    report.row(
        "Thumbnails, 64 at once",
        format!("{rate:.0} per second"),
        "",
    );

    let ids: Vec<String> = (1..=200).map(seed_id).collect();
    let mut samples = Vec::new();
    let mut bytes = 0;
    for _ in 0..50 {
        let start = Instant::now();
        bytes = http
            .post(format!("{base}/api/v1/thumbnails"))
            .bearer_auth(&token)
            .json(&json!({ "ids": ids }))
            .send()
            .await?
            .bytes()
            .await?
            .len();
        samples.push(start.elapsed());
    }
    report.row(
        "200 thumbnails in one request",
        format!(
            "p50 {} ({} MB)",
            ms(percentile(&mut samples, 0.5)),
            bytes / 1_000_000
        ),
        "< 20 ms",
    );

    // Small photos, one after the other: announce + one PATCH each.
    let photo = random(3 * MIB);
    let started = Instant::now();
    for _ in 0..50 {
        let mut copy = photo.to_vec();
        copy[..16].copy_from_slice(Uuid::new_v4().as_bytes());
        upload(&http, &base, &token, Bytes::from(copy), "image/heic").await?;
    }
    let each = started.elapsed() / 50;
    report.row("3 MB photo, announce to completed", ms(each), "");

    // A big video: throughput and the server's memory while it arrives.
    let gib = 1024 * MIB;
    let chunk = random(64 * MIB);
    let mut hasher = Sha256::new();
    for _ in 0..gib / chunk.len() {
        hasher.update(&chunk);
    }
    let sha = hex::encode(hasher.finalize());
    let created: Value = http
        .post(format!("{base}/api/v1/uploads"))
        .bearer_auth(&token)
        .json(&json!({ "assetId": Uuid::new_v4(), "size": gib, "sha256": sha, "mimeType": "video/quicktime" }))
        .send()
        .await?
        .json()
        .await?;
    let upload_url = format!(
        "{base}/api/v1/uploads/{}",
        created["uploadId"].as_str().context("no upload id")?
    );
    let before = server.rss_mb();
    let memory = PeakMemory::watch(server.0.id());
    let started = Instant::now();
    let pieces = gib / chunk.len();
    let mut last = Value::Null;
    for piece in 0..pieces {
        last = http
            .request(Method::PATCH, &upload_url)
            .bearer_auth(&token)
            .header("upload-offset", (piece * chunk.len()).to_string())
            .body(chunk.clone())
            .send()
            .await?
            .json()
            .await?;
    }
    let elapsed = started.elapsed();
    let peak = memory.peak();
    let own_after = footprint_mb(server.0.id()).unwrap_or(0.0);
    if last["state"] != "completed" {
        bail!("the big upload did not complete: {last}");
    }
    report.row(
        "1 GiB upload in 64 MiB pieces",
        format!("{:.0} MB/s", gib as f64 / 1e6 / elapsed.as_secs_f64()),
        ">= 400 MB/s",
    );
    report.row(
        "Server memory during that upload (peak)",
        format!("{peak:.0} MB resident (before: {before:.0} MB), {own_after:.0} MB own after"),
        "< 100 MB",
    );

    // More rounds of the heaviest reads: if memory keeps growing, something leaks.
    let rounds: usize = std::env::var("ROUNDS")
        .ok()
        .and_then(|r| r.parse().ok())
        .unwrap_or(3);
    let only = std::env::var("ONLY").unwrap_or_default();
    for _ in 0..rounds {
        let mut since = 0;
        #[allow(clippy::while_immutable_condition)] // ends with `break`
        while only != "bulk" {
            // The compressed answer is only fetched (the client here can't unpack brotli).
            http.get(format!("{base}/api/v1/sync?since={since}&limit=1000"))
                .bearer_auth(&token)
                .header("accept-encoding", "br")
                .send()
                .await?
                .bytes()
                .await?;
            let plain: Value = http
                .get(format!("{base}/api/v1/sync?since={since}&limit=1000"))
                .bearer_auth(&token)
                .send()
                .await?
                .json()
                .await?;
            let next = plain["nextSince"].as_i64().unwrap_or(since);
            if plain["hasMore"] != true || next == since {
                break;
            }
            since = next;
        }
        for _ in 0..if only == "sync" { 0 } else { 20 } {
            http.post(format!("{base}/api/v1/thumbnails"))
                .bearer_auth(&token)
                .json(&json!({ "ids": ids }))
                .send()
                .await?
                .bytes()
                .await?;
        }
        report.row(
            "Own memory after another full round",
            format!("{:.0} MB", footprint_mb(server.0.id()).unwrap_or(0.0)),
            "stays flat",
        );
    }

    if let Some(out) = out {
        let text = format!(
            "# Halden benchmark\n\nRelease build, server as its own process, localhost, pinned TLS 1.3, HTTP/2.\n\n| Measurement | Result | Goal |\n|---|---|---|\n{}\n",
            report.lines.join("\n")
        );
        std::fs::write(&out, text)?;
        println!("\nwritten to {}", out.display());
    }
    drop(server);
    Ok(())
}

fn random(len: usize) -> Bytes {
    let mut data = vec![0u8; len];
    rand::fill(data.as_mut_slice());
    Bytes::from(data)
}

async fn upload(
    http: &reqwest::Client,
    base: &str,
    token: &str,
    data: Bytes,
    mime: &str,
) -> Result<()> {
    let created: Value = http
        .post(format!("{base}/api/v1/uploads"))
        .bearer_auth(token)
        .json(&json!({
            "assetId": Uuid::new_v4(), "size": data.len(),
            "sha256": hex::encode(Sha256::digest(&data)), "mimeType": mime,
            "metadata": { "takenAt": 1_795_443_720_000_i64, "timeZoneOffsetMinutes": 60 }
        }))
        .send()
        .await?
        .json()
        .await?;
    let id = created["uploadId"].as_str().context("no upload id")?;
    let done: Value = http
        .request(Method::PATCH, format!("{base}/api/v1/uploads/{id}"))
        .bearer_auth(token)
        .header("upload-offset", "0")
        .body(data)
        .send()
        .await?
        .json()
        .await?;
    if done["state"] != "completed" {
        bail!("upload did not complete: {done}");
    }
    Ok(())
}

fn seed_id(i: i64) -> String {
    format!("{i:08x}-0000-4000-8000-{i:012x}")
}

/// Thumbnails of 30 KB for the first `count` seeded photos, as files plus database rows.
async fn seed_thumbnails(
    db: &Db,
    config: &Config,
    user_id: &str,
    count: i64,
) -> Result<Vec<String>> {
    let mut hashes = Vec::new();
    let mut tx = db.begin().await?;
    for i in 1..=count {
        let data = random(30_000);
        let sha = hex::encode(Sha256::digest(&data));
        let relative = format!("{}/{}/{sha}.jpg", &sha[..2], &sha[2..4]);
        let path = config.derived_dir().join(&relative);
        std::fs::create_dir_all(path.parent().context("no parent")?)?;
        std::fs::write(&path, &data)?;
        sqlx::query(
            "INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, path, \
                 width, height, created_at) \
             VALUES (?, 'thumbnail', ?, unhex(?), 30000, 'image/jpeg', 'derived', ?, 512, 384, 0)",
        )
        .bind(seed_id(i))
        .bind(user_id)
        .bind(&sha)
        .bind(&relative)
        .execute(&mut *tx)
        .await?;
        hashes.push(sha);
    }
    tx.commit().await?;
    Ok(hashes)
}

/// 100,000 photos straight into the database, spread over five years, most with a location.
async fn seed(db: &Db, user_id: &str) -> Result<()> {
    let mut tx = db.begin().await?;
    sqlx::query(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?2) \
         INSERT INTO assets (id, user_id, kind, taken_at, tz_offset_min, taken_at_source, width, \
             height, latitude, longitude, location_accuracy_m, location_source, created_at, \
             updated_at, seq) \
         SELECT printf('%08x-0000-4000-8000-%012x', i, i), ?1, \
             CASE WHEN i % 10 = 0 THEN 'video' ELSE 'photo' END, \
             1640995200000 + i * 1577000, 60, 'client', 4032, 3024, \
             CASE WHEN i % 7 = 0 THEN NULL ELSE 50.0 + (i % 1000) / 1000.0 END, \
             CASE WHEN i % 7 = 0 THEN NULL ELSE 9.0 + (i % 977) / 1000.0 END, \
             CASE WHEN i % 7 = 0 THEN NULL ELSE 5.0 END, \
             CASE WHEN i % 7 = 0 THEN NULL ELSE 'client' END, \
             1795000000000, 1795000000000, i \
         FROM n",
    )
    .bind(user_id)
    .bind(LIBRARY_SIZE)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, path, \
             width, height, created_at) \
         SELECT id, 'original', user_id, unhex(printf('%064x', seq)), 3000000, 'image/heic', \
             'library', 'seed/' || seq || '.heic', 4032, 3024, 1795000000000 \
         FROM assets WHERE user_id = ?1",
    )
    .bind(user_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE counters SET value = ? WHERE name = 'asset_seq'")
        .bind(LIBRARY_SIZE)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    db.optimize().await?;
    Ok(())
}
