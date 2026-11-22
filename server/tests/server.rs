//! Starts the real server on a free port and talks to it the way the apps will: over TLS 1.3,
//! trusting only the pinned certificate fingerprint.

use std::{path::Path, sync::Arc};

use halden::{
    config::Config,
    server::{self, RunningServer},
    setup::{self, SetupOptions},
};
use rustls::{
    DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::CryptoProvider,
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use serde_json::Value;
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

fn client(
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
async fn start_server(dir: &Path) -> (RunningServer, Config) {
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
    let running = server::start(&config).await.unwrap();
    (running, config)
}

fn url(server: &RunningServer, path: &str) -> String {
    format!("https://127.0.0.1:{}{path}", server.addr.port())
}

#[tokio::test]
async fn health_and_server_info_over_pinned_tls13() {
    let dir = tempfile::tempdir().unwrap();
    let (server, config) = start_server(dir.path()).await;
    let pin = *server.fingerprint.as_bytes();
    let http = client(pin, &[&rustls::version::TLS13]);

    let health = http
        .get(url(&server, "/api/v1/health"))
        .send()
        .await
        .unwrap();
    assert_eq!(health.status(), 200);
    assert_eq!(
        health.version(),
        reqwest::Version::HTTP_2,
        "HTTP/2 must be negotiated"
    );
    let body: Value = health.json().await.unwrap();
    assert_eq!(body["status"], "ok");

    let info: Value = http
        .get(url(&server, "/api/v1/server"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(info["name"], "testbox");
    assert_eq!(info["apiVersion"], 1);
    assert_eq!(info["fingerprint"], server.fingerprint.hex());
    assert_eq!(
        info["fingerprint"],
        halden::tls::identity_fingerprint(&config).unwrap().hex()
    );
    assert!(info["serverId"].as_str().unwrap().len() == 36);

    let missing = http.get(url(&server, "/nope")).send().await.unwrap();
    assert_eq!(missing.status(), 404);

    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn wrong_fingerprint_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (server, _) = start_server(dir.path()).await;
    let http = client([0; 32], &[&rustls::version::TLS13]);
    assert!(
        http.get(url(&server, "/api/v1/health"))
            .send()
            .await
            .is_err()
    );
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn tls12_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (server, _) = start_server(dir.path()).await;
    let http = client(*server.fingerprint.as_bytes(), &[&rustls::version::TLS12]);
    assert!(
        http.get(url(&server, "/api/v1/health"))
            .send()
            .await
            .is_err()
    );
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn setup_twice_keeps_identity() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.toml");
    let options = SetupOptions {
        data_dir: Some(dir.path().join("data")),
        library_dir: Some(dir.path().join("library")),
        ..SetupOptions::default()
    };
    let first = setup::run(&config_path, options.clone()).await.unwrap();
    assert!(first.config_created && first.identity_created);

    let second = setup::run(&config_path, SetupOptions::default())
        .await
        .unwrap();
    assert!(!second.config_created && !second.identity_created);
    assert_eq!(first.server_id, second.server_id);
    assert_eq!(first.fingerprint, second.fingerprint);

    // Changing settings through setup on an existing config is refused, not silently ignored.
    assert!(setup::run(&config_path, options).await.is_err());

    for folder in [
        "library/.halden/incoming",
        "library/.halden/backups",
        "data/tls",
    ] {
        assert!(dir.path().join(folder).is_dir(), "{folder} missing");
    }
}

#[tokio::test]
async fn port_in_use_is_reported() {
    let dir = tempfile::tempdir().unwrap();
    let (server, mut config) = start_server(dir.path()).await;
    config.server.port = server.addr.port();
    let error = server::start(&config)
        .await
        .err()
        .expect("second start must fail");
    assert!(format!("{error:#}").contains("already in use"), "{error:#}");
    server.shutdown().await.unwrap();
}
