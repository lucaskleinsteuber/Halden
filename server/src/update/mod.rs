//! Updates, the way Aurelia does them.
//!
//! - The server looks for a new version once a day (`[update] check_daily`), asking only
//!   GitHub's release list, and remembers what it found in `<data>/update-status`. The apps and
//!   `halden status` show it. Installing always waits for the owner.
//! - `sudo halden update` installs the newest version. From the app, the server leaves a request
//!   file (`<data>/update-requested`); the systemd unit `halden-update-request.path` notices it
//!   and runs `halden update --from-app` as root. The server itself never gets root, and the
//!   request says nothing but "install the newest version".
//! - A release lists its packages with their SHA-256 in `SHA256SUMS`, which carries the owner's
//!   minisign signature. The secret key never goes to GitHub; the public key is built into the
//!   program ([`RELEASE_KEY`]). Nothing unsigned is ever installed, and never an older version.
//! - Before swapping, the database is backed up and the new program tests itself on a copy of
//!   the database. If it doesn't answer after the restart, the old program and the backed-up
//!   database come back.

pub mod install;
pub mod release;
pub mod status;
pub mod verify;

use std::{sync::Arc, time::Duration};

use anyhow::{Context, Result};

pub use self::{
    release::{Checked, Found, Release},
    status::{UpdateState, UpdateStatus},
};
use crate::VERSION;

pub const REPOSITORY: &str = "lucaskleinsteuber/Halden";

/// The owner's minisign public key: the second line of `halden.pub` (it starts with `RW`).
/// While it is empty, this build installs no update at all and says so (see
/// `docs/UPDATE_SIGNING.md`).
pub const RELEASE_KEY: &str = "RWTs0qnx3DCwBdiw9Jmq5FYharADL9IMQE026EHwOd0aftNjjIDxoIoo";

/// Biggest package the updater downloads.
pub const MAX_PACKAGE_BYTES: u64 = 300 * 1024 * 1024;

/// Where releases come from and which key signs them.
#[derive(Debug, Clone)]
pub struct Source {
    /// GitHub's release list (JSON).
    pub releases_url: String,
    /// The minisign public key, if this build has one.
    pub key: Option<String>,
}

impl Source {
    /// GitHub and the built-in key. Debug builds (tests) can point elsewhere with
    /// `HALDEN_UPDATE_API` and `HALDEN_UPDATE_KEY`; release builds can't.
    pub fn official() -> Self {
        #[allow(unused_mut)]
        let mut source = Self {
            releases_url: format!(
                "https://api.github.com/repos/{REPOSITORY}/releases?per_page=100"
            ),
            key: (!RELEASE_KEY.is_empty()).then(|| RELEASE_KEY.to_string()),
        };
        #[cfg(debug_assertions)]
        if let Ok(url) = std::env::var("HALDEN_UPDATE_API") {
            source.releases_url = url;
            source.key = std::env::var("HALDEN_UPDATE_KEY").ok();
        }
        source
    }
}

/// The version of this program.
pub fn current() -> semver::Version {
    semver::Version::parse(VERSION).unwrap_or_else(|_| semver::Version::new(0, 0, 0))
}

/// The processor name used in package names: `x86_64` or `aarch64`.
pub fn arch() -> &'static str {
    std::env::consts::ARCH
}

/// An HTTP client for GitHub: certificates checked against Mozilla's roots (no system files
/// needed), and nothing about this server or its owner in the request but the program's version.
pub fn client() -> Result<reqwest::Client> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let roots = rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    };
    let mut tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    reqwest::Client::builder()
        .tls_backend_preconfigured(tls)
        .user_agent(format!("halden/{VERSION}"))
        .connect_timeout(Duration::from_secs(20))
        .read_timeout(Duration::from_secs(60))
        .build()
        .context("could not set up the HTTP client")
}

/// Looks for a newer version (`found` is `None` when this one is the newest), and with test
/// versions off for a newer test version.
pub async fn check(source: &Source, beta: bool) -> Result<Checked> {
    let client = client()?;
    let response = client
        .get(&source.releases_url)
        .header("accept", "application/vnd.github+json")
        .send()
        .await
        .context("could not reach GitHub")?;
    let status = response.status();
    if !status.is_success() {
        anyhow::bail!("GitHub answered {status}");
    }
    let body = response
        .bytes()
        .await
        .context("GitHub's answer broke off")?;
    let releases = release::parse(&body)?;
    Ok(release::look(&releases, &current(), beta, arch()))
}

#[cfg(test)]
mod tests {
    /// `get-halden.sh` checks releases with openssl before anything of Halden runs; it must
    /// carry the same key as the program.
    #[test]
    fn the_install_script_has_the_same_key() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../packaging/linux/get-halden.sh"
        );
        let script = match std::fs::read_to_string(path) {
            Ok(script) => script,
            // cargo-mutants copies only `server/` (run it with HALDEN_MUTANTS=1); everywhere
            // else the script must be there.
            Err(_) if std::env::var_os("HALDEN_MUTANTS").is_some() => return,
            Err(error) => panic!("{path}: {error}"),
        };
        let line = script
            .lines()
            .find(|line| line.starts_with("signing_public_key="))
            .expect("the script names its key");
        assert_eq!(
            line,
            format!("signing_public_key=\"{}\"", super::RELEASE_KEY)
        );
    }
}
