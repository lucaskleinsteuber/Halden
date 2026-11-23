//! HTTPS: the server's own certificate, its fingerprint, and the TLS settings.
//!
//! During setup Halden creates a P-256 key and a self-signed certificate. Apps don't trust it
//! through a certificate authority; instead they pin its **fingerprint** (SHA-256 of the
//! certificate), which they get from the pairing QR code or which the person compares with
//! `halden status`. Only TLS 1.3 is offered.

use std::{
    fmt,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    path::Path,
    sync::Arc,
};

use anyhow::{Context, Result, bail, ensure};
use chrono::Datelike;
use rcgen::{
    CertificateParams, DistinguishedName, DnType, KeyPair, PKCS_ECDSA_P256_SHA256, SanType,
    date_time_ymd,
};
use rustls::{
    ServerConfig,
    pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject},
};
use sha2::{Digest, Sha256};

use crate::{config::Config, fsutil};

/// SHA-256 of a certificate (DER). Shown grouped for people, sent as plain hex to apps.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Fingerprint([u8; 32]);

impl Fingerprint {
    pub fn of(cert: &CertificateDer<'_>) -> Self {
        Self(Sha256::digest(cert.as_ref()).into())
    }

    /// Lowercase hex without separators, for the API and QR codes.
    pub fn hex(&self) -> String {
        hex::encode(self.0)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Display for Fingerprint {
    /// Groups of four uppercase hex digits: `3FA9 0C1D …`, easy to compare by eye.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let hex = hex::encode_upper(self.0);
        let groups: Vec<&str> = hex
            .as_bytes()
            .chunks(4)
            .map(|chunk| std::str::from_utf8(chunk).unwrap_or_default())
            .collect();
        f.write_str(&groups.join(" "))
    }
}

impl fmt::Debug for Fingerprint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Fingerprint({})", self.hex())
    }
}

/// A new key and self-signed certificate, both PEM.
pub struct GeneratedIdentity {
    pub cert_pem: String,
    pub key_pem: String,
}

pub fn generate(server_name: &str) -> Result<GeneratedIdentity> {
    let key = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256).context("could not create a key")?;

    let mut params = CertificateParams::default();
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, format!("Halden server {server_name}"));
    name.push(DnType::OrganizationName, "Halden");
    params.distinguished_name = name;

    let mut sans = vec![
        SanType::DnsName("localhost".try_into()?),
        SanType::IpAddress(IpAddr::V4(Ipv4Addr::LOCALHOST)),
        SanType::IpAddress(IpAddr::V6(Ipv6Addr::LOCALHOST)),
    ];
    let label = server_name.to_ascii_lowercase();
    if is_dns_label(&label) {
        sans.push(SanType::DnsName(label.clone().try_into()?));
        sans.push(SanType::DnsName(format!("{label}.local").try_into()?));
    }
    params.subject_alt_names = sans;

    // Apps pin this exact certificate, so it must not expire during the server's lifetime.
    let year = chrono::Utc::now().year();
    params.not_before = date_time_ymd(year - 1, 1, 1);
    params.not_after = date_time_ymd(year + 30, 1, 1);

    let cert = params
        .self_signed(&key)
        .context("could not create the certificate")?;
    Ok(GeneratedIdentity {
        cert_pem: cert.pem(),
        key_pem: key.serialize_pem(),
    })
}

fn is_dns_label(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 63
        && !text.starts_with('-')
        && !text.ends_with('-')
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Creates the server's key and certificate if they don't exist yet. Returns true if it did.
/// Never overwrites an existing key: replacing it would cut off every paired device.
pub fn ensure_identity(config: &Config) -> Result<bool> {
    let cert_path = config.cert_path();
    let key_path = config.key_path();
    if !config.uses_generated_certificate() {
        ensure!(
            cert_path.is_file() && key_path.is_file(),
            "tls.cert_file or tls.key_file does not exist ({}, {})",
            cert_path.display(),
            key_path.display()
        );
        return Ok(false);
    }
    match (cert_path.exists(), key_path.exists()) {
        (true, true) => Ok(false),
        (false, false) => {
            fsutil::create_dir(&config.tls_dir(), 0o700)?;
            let identity = generate(&config.server.name)?;
            fsutil::write_atomic(&key_path, identity.key_pem.as_bytes(), 0o600)?;
            fsutil::write_atomic(&cert_path, identity.cert_pem.as_bytes(), 0o644)?;
            Ok(true)
        }
        _ => bail!(
            "only one of {} and {} exists; Halden won't replace a key on its own. \
             Restore the missing file, or move the other one away to create a new identity \
             (all devices then have to be paired again)",
            cert_path.display(),
            key_path.display()
        ),
    }
}

pub fn load_certificates(path: &Path) -> Result<Vec<CertificateDer<'static>>> {
    let certs = CertificateDer::pem_file_iter(path)
        .and_then(|iter| iter.collect::<Result<Vec<_>, _>>())
        .with_context(|| format!("could not read the certificate {}", path.display()))?;
    ensure!(
        !certs.is_empty(),
        "{} contains no certificate",
        path.display()
    );
    Ok(certs)
}

pub fn load_key(path: &Path) -> Result<PrivateKeyDer<'static>> {
    PrivateKeyDer::from_pem_file(path)
        .with_context(|| format!("could not read the private key {}", path.display()))
}

/// Fingerprint of the certificate the server presents.
pub fn identity_fingerprint(config: &Config) -> Result<Fingerprint> {
    let certs = load_certificates(&config.cert_path())?;
    Ok(Fingerprint::of(&certs[0]))
}

/// TLS 1.3 only, HTTP/2 preferred, using the server's certificate and key.
pub fn server_config(config: &Config) -> Result<(Arc<ServerConfig>, Fingerprint)> {
    let certs = load_certificates(&config.cert_path())?;
    let fingerprint = Fingerprint::of(&certs[0]);
    let key = load_key(&config.key_path())?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut server = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .context("TLS 1.3 is not available")?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .context("the certificate and key don't belong together")?;
    server.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok((Arc::new(server), fingerprint))
}

/// A client that trusts exactly one certificate, by its fingerprint, like the apps do. Used to
/// ask the local server whether it is up (after an update).
pub fn pinned_client(fingerprint: Fingerprint) -> Result<reqwest::Client> {
    #[derive(Debug)]
    struct Pinned {
        expected: [u8; 32],
        provider: Arc<rustls::crypto::CryptoProvider>,
    }
    use rustls::{
        DigitallySignedStruct, SignatureScheme,
        client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
        pki_types::{ServerName, UnixTime},
    };
    impl ServerCertVerifier for Pinned {
        fn verify_server_cert(
            &self,
            end_entity: &CertificateDer<'_>,
            _intermediates: &[CertificateDer<'_>],
            _server_name: &ServerName<'_>,
            _ocsp_response: &[u8],
            _now: UnixTime,
        ) -> Result<ServerCertVerified, rustls::Error> {
            if Fingerprint::of(end_entity).0 == self.expected {
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
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Pinned {
            expected: fingerprint.0,
            provider,
        }))
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    reqwest::Client::builder()
        .tls_backend_preconfigured(tls)
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .context("could not set up the HTTP client")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_identity_loads_and_has_stable_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.server.name = "testbox".into();
        config.storage.data_dir = dir.path().join("data");
        config.storage.library_dir = dir.path().join("library");

        assert!(ensure_identity(&config).unwrap());
        assert!(
            !ensure_identity(&config).unwrap(),
            "second run must keep the key"
        );

        let first = identity_fingerprint(&config).unwrap();
        let (_, second) = server_config(&config).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.hex().len(), 64);
        assert_eq!(first.to_string().split(' ').count(), 16);
    }

    #[test]
    fn missing_half_of_identity_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.storage.data_dir = dir.path().join("data");
        config.storage.library_dir = dir.path().join("library");
        ensure_identity(&config).unwrap();
        std::fs::remove_file(config.cert_path()).unwrap();
        assert!(ensure_identity(&config).is_err());
    }

    #[test]
    fn dns_labels() {
        assert!(is_dns_label("halden-server"));
        assert!(!is_dns_label("lucas server"));
        assert!(!is_dns_label("-bad"));
        assert!(!is_dns_label(""));
    }
}
