//! Shared by the integration tests: a client that trusts only the pinned certificate (like the
//! iPhone app), and a real server in a temporary folder.
#![allow(dead_code)]

use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use halden::{
    accounts::{self, NewUser, Role, User},
    auth::password,
    config::{
        Config,
        edit::{self, Change},
        keys,
    },
    db,
    server::{self, RunningServer, Supervisor},
    setup::{self, SetupOptions},
    tls::Fingerprint,
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

/// Trusts exactly one certificate, identified by its SHA-256, like the iPhone app does.
#[derive(Debug)]
struct PinnedCertificate {
    expected: [u8; 32],
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinnedCertificate {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if Sha256::digest(end_entity.as_ref()).as_slice() == self.expected {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "certificate fingerprint mismatch".into(),
            ))
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

pub fn client(
    pin: [u8; 32],
    versions: &[&'static rustls::SupportedProtocolVersion],
) -> reqwest::Client {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(versions)
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedCertificate {
            expected: pin,
            provider,
        }))
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    reqwest::Client::builder()
        .tls_backend_preconfigured(tls)
        .build()
        .unwrap()
}

/// Sets up a server in a temporary folder and starts it on a free local port.
pub async fn start_server(dir: &Path) -> (RunningServer, Config) {
    start_server_with(dir, |_| {}).await
}

/// Like [`start_server`], with a chance to change the config first.
pub async fn start_server_with(
    dir: &Path,
    change: impl FnOnce(&mut Config),
) -> (RunningServer, Config) {
    let config_path = dir.join("config.toml");
    setup::run(
        &config_path,
        SetupOptions {
            name: Some("testbox".into()),
            data_dir: Some(dir.join("data")),
            library_dir: Some(dir.join("library")),
            ..SetupOptions::default()
        },
    )
    .await
    .unwrap();
    let mut config = Config::load(&config_path).unwrap();
    config.server.bind = "127.0.0.1".parse().unwrap();
    config.server.port = 0;
    change(&mut config);
    let running = server::start(&config).await.unwrap();
    (running, config)
}

pub fn url(server: &RunningServer, path: &str) -> String {
    format!("https://127.0.0.1:{}{path}", server.addr.port())
}

pub const LUCAS_PASSWORD: &str = "correct horse battery";
pub const ANNA_PASSWORD: &str = "anna's long password";

/// A real server in a temporary folder, plus a client that talks to it like the app.
pub struct Api {
    pub http: reqwest::Client,
    pub server: TestServer,
    pub config: Config,
    pub config_path: PathBuf,
    pub dir: tempfile::TempDir,
}

/// The server under test: started directly, or like `halden serve` (from its config file,
/// restarting when it changes).
pub struct TestServer {
    pub addr: SocketAddr,
    pub fingerprint: Fingerprint,
    running: Running,
}

enum Running {
    Plain(RunningServer),
    Supervised(Supervisor),
}

impl TestServer {
    async fn shutdown(self) {
        match self.running {
            Running::Plain(server) => server.shutdown().await.unwrap(),
            Running::Supervised(supervisor) => supervisor.stop().await.unwrap(),
        }
    }

    pub fn supervisor(&mut self) -> &mut Supervisor {
        match &mut self.running {
            Running::Supervised(supervisor) => supervisor,
            Running::Plain(_) => panic!("started without a supervisor"),
        }
    }
}

pub struct Reply {
    pub status: u16,
    pub body: Value,
    pub retry_after: Option<String>,
    pub headers: reqwest::header::HeaderMap,
}

impl Reply {
    pub fn error(&self) -> &str {
        self.body["error"].as_str().unwrap_or_default()
    }
}

impl Api {
    pub async fn start() -> Self {
        Self::start_with(|_| {}).await
    }

    pub async fn start_with(change: impl FnOnce(&mut Config)) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let (server, config) = start_server_with(dir.path(), change).await;
        let http = client(*server.fingerprint.as_bytes(), &[&rustls::version::TLS13]);
        Self {
            http,
            server: TestServer {
                addr: server.addr,
                fingerprint: server.fingerprint,
                running: Running::Plain(server),
            },
            config,
            config_path: dir.path().join("config.toml"),
            dir,
        }
    }

    /// Like `halden serve`: from the config file, which is checked for changes every 100 ms.
    pub async fn start_supervised() -> Self {
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
        set_setting(&config_path, "server.bind", "127.0.0.1");
        set_setting(&config_path, "server.port", "0");
        let supervisor = Supervisor::start_polling(&config_path, Duration::from_millis(100))
            .await
            .unwrap();
        let current = supervisor.current();
        let http = client(*current.fingerprint.as_bytes(), &[&rustls::version::TLS13]);
        Self {
            http,
            server: TestServer {
                addr: current.addr,
                fingerprint: current.fingerprint,
                running: Running::Supervised(supervisor),
            },
            config: Config::load(&config_path).unwrap(),
            config_path,
            dir,
        }
    }

    /// Waits until the supervised server restarted after `generation`; returns the new one.
    pub async fn restarted_after(&mut self, generation: u64) -> u64 {
        let supervisor = self.server.supervisor();
        tokio::time::timeout(
            Duration::from_secs(20),
            supervisor.restarted_after(generation),
        )
        .await
        .expect("the server did not restart")
        .number
    }

    pub fn generation(&mut self) -> u64 {
        self.server.supervisor().current().number
    }

    pub async fn call(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> Reply {
        let mut request = self.http.request(method, self.url(path));
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        Self::reply(request.send().await.unwrap()).await
    }

    /// Reads a response the way [`Api::call`] does.
    pub async fn reply(response: reqwest::Response) -> Reply {
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let retry_after = response
            .headers()
            .get("retry-after")
            .map(|value| value.to_str().unwrap().to_string());
        let text = response.text().await.unwrap();
        let body = if text.is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).unwrap_or_else(|_| panic!("not JSON: {text}"))
        };
        Reply {
            status,
            body,
            retry_after,
            headers,
        }
    }

    pub async fn get(&self, path: &str, token: &str) -> Reply {
        self.call(Method::GET, path, Some(token), None).await
    }

    pub async fn post(&self, path: &str, token: Option<&str>, body: Value) -> Reply {
        self.call(Method::POST, path, token, Some(body)).await
    }

    pub async fn login(&self, username: &str, password: &str, device: Value) -> Reply {
        self.post(
            "/api/v1/auth/login",
            None,
            json!({ "username": username, "password": password, "device": device }),
        )
        .await
    }

    /// Signs in and returns the token.
    pub async fn token(&self, username: &str, password: &str, device: Value) -> String {
        let reply = self.login(username, password, device).await;
        assert_eq!(reply.status, 200, "{}", reply.body);
        reply.body["token"].as_str().unwrap().to_string()
    }

    pub async fn pool(&self) -> db::Db {
        db::Db::open(&self.config.db_path()).await.unwrap()
    }

    /// Creates an account directly in the database, like `halden user add` does.
    pub async fn add_user(&self, username: &str, password: &str, role: Role) -> User {
        let pool = self.pool().await;
        let user = accounts::create_user(
            &pool,
            NewUser {
                username,
                display_name: None,
                role,
                password_hash: Some(password::hash(password.into()).await.unwrap()),
            },
        )
        .await
        .unwrap();
        pool.close().await;
        user
    }

    pub fn url(&self, path: &str) -> String {
        format!("https://127.0.0.1:{}{path}", self.server.addr.port())
    }

    /// Stops the server but keeps its folders (returned; they go when it is dropped).
    pub async fn stop_keeping_files(self) -> tempfile::TempDir {
        self.server.shutdown().await;
        self.dir
    }

    pub async fn stop(self) {
        self.server.shutdown().await;
    }
}

/// Changes a setting in a config file, like `halden config set`.
pub fn set_setting(config_path: &Path, name: &str, value: &str) {
    let key = keys::find(name).unwrap();
    edit::change(config_path, &[(key, edit::from_text(key, value).unwrap())]).unwrap();
}

pub fn reset_setting(config_path: &Path, name: &str) {
    let key = keys::find(name).unwrap();
    edit::change(config_path, &[(key, Change::Reset)]).unwrap();
}

pub fn device(name: &str, installation: &str) -> Value {
    json!({ "name": name, "platform": "ios", "installationId": installation })
}

pub fn iphone() -> Value {
    device("Lucas' iPhone", "install-lucas-iphone")
}

pub fn mac() -> Value {
    json!({ "name": "Lucas' Mac", "platform": "macos", "installationId": "install-lucas-mac" })
}

pub fn sha_hex(data: &[u8]) -> String {
    hex::encode(<sha2::Sha256 as sha2::Digest>::digest(data))
}

pub fn random_bytes(len: usize) -> Vec<u8> {
    let mut data = vec![0u8; len];
    rand::fill(data.as_mut_slice());
    data
}

impl Api {
    /// Announces a file and sends it in one piece; returns the finished asset.
    pub async fn upload(
        &self,
        token: &str,
        asset_id: &str,
        data: &[u8],
        mime: &str,
        metadata: Value,
    ) -> Value {
        let created = self
            .post(
                "/api/v1/uploads",
                Some(token),
                json!({ "assetId": asset_id, "size": data.len(), "sha256": sha_hex(data),
                        "mimeType": mime, "metadata": metadata }),
            )
            .await;
        assert_eq!(created.status, 201, "{}", created.body);
        let id = created.body["uploadId"].as_str().unwrap();
        let response = self
            .http
            .patch(self.url(&format!("/api/v1/uploads/{id}")))
            .bearer_auth(token)
            .header("upload-offset", "0")
            .body(data.to_vec())
            .send()
            .await
            .unwrap();
        let done = Self::reply(response).await;
        assert_eq!(done.body["state"], "completed", "{}", done.body);
        done.body["asset"].clone()
    }

    /// Sends a thumbnail or preview.
    pub async fn put_derived(&self, token: &str, asset_id: &str, role: &str, data: &[u8]) -> Reply {
        let response = self
            .http
            .put(self.url(&format!("/api/v1/assets/{asset_id}/files/{role}")))
            .bearer_auth(token)
            .header("content-type", "image/jpeg")
            .header("halden-sha256", sha_hex(data))
            .body(data.to_vec())
            .send()
            .await
            .unwrap();
        Self::reply(response).await
    }
}

/// A real JPEG: a 1600×1200 colour gradient.
pub fn gradient_jpeg() -> Vec<u8> {
    let image = image::RgbImage::from_fn(1600, 1200, |x, y| {
        image::Rgb([(x % 256) as u8, (y % 256) as u8, ((x + y) % 256) as u8])
    });
    let mut out = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(image)
        .write_to(&mut out, image::ImageFormat::Jpeg)
        .unwrap();
    out.into_inner()
}

/// Is an external tool installed? With `HALDEN_REQUIRE_TOOLS` set (in CI), a missing tool fails
/// the test instead of skipping that part.
pub fn tool(name: &str) -> bool {
    let found = std::process::Command::new(name)
        .arg("-version")
        .output()
        .is_ok();
    if !found && std::env::var_os("HALDEN_REQUIRE_TOOLS").is_some() {
        panic!("{name} is required for this test (HALDEN_REQUIRE_TOOLS is set)");
    }
    found
}

/// Waits until the server has files in all these roles for an asset (made in the background).
pub async fn wait_for_files(api: &Api, token: &str, id: &str, roles: &[&str]) -> Value {
    for _ in 0..300 {
        let asset = api.get(&format!("/api/v1/assets/{id}"), token).await.body;
        let files = asset["files"].as_array().unwrap();
        if roles
            .iter()
            .all(|role| files.iter().any(|f| f["role"] == *role))
        {
            return asset;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("the server did not make {roles:?} for {id}");
}
