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
        format!("{:.0} MB", server.rss_mb()),
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
        format!("{peak:.0} MB (before: {before:.0} MB)"),
        "< 100 MB",
    );

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
