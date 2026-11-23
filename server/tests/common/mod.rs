//! Shared by the integration tests: a client that trusts only the pinned certificate (like the
//! iPhone app), and a real server in a temporary folder.
#![allow(dead_code)]

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
