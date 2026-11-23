//! The server's configuration file (`/etc/halden/config.toml` by default).
//!
//! Every setting has a sensible default, so an empty file is a valid configuration. Unknown keys
//! are rejected, so a typo never silently does nothing.

use std::{
    net::{IpAddr, Ipv6Addr},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::{fsutil, net::Cidr};

pub const DEFAULT_CONFIG_PATH: &str = "/etc/halden/config.toml";
pub const DEFAULT_PORT: u16 = 47130;
pub const DEFAULT_DATA_DIR: &str = "/var/lib/halden";
pub const DEFAULT_LIBRARY_DIR: &str = "/srv/halden/library";

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub server: ServerConfig,
    pub storage: StorageConfig,
    pub network: NetworkConfig,
    pub tls: TlsConfig,
    pub auth: AuthConfig,
    pub security: SecurityConfig,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ServerConfig {
    /// Name the apps show for this server.
    pub name: String,
    /// Address to listen on. `::` listens on every IPv4 and IPv6 address.
    pub bind: IpAddr,
    /// Port for HTTPS. 0 lets the system pick a free port (used by tests).
    pub port: u16,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            name: default_server_name(),
            bind: IpAddr::V6(Ipv6Addr::UNSPECIFIED),
            port: DEFAULT_PORT,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct StorageConfig {
    /// Database, keys and caches. Best on the fast system disk.
    pub data_dir: PathBuf,
    /// Original photos and videos, in readable folders. Usually the big data disk.
    pub library_dir: PathBuf,
    /// Where an original goes inside the library, without the extension. Placeholders:
    /// `{user}`, `{year}`, `{month}`, `{day}`, `{date}` (2026-11-23), `{time}` (15-22-10),
    /// `{hour}`, `{minute}`, `{second}`, all in the local time where the photo was taken.
    pub path_template: String,
    /// Refuse uploads that would leave less than this much free space on the library disk.
    pub min_free_gb: u64,
    /// Unfinished uploads are thrown away after this many days without progress.
    pub upload_expiry_days: u32,
}

impl Default for StorageConfig {
    fn default() -> Self {
        Self {
            data_dir: DEFAULT_DATA_DIR.into(),
            library_dir: DEFAULT_LIBRARY_DIR.into(),
            path_template: crate::library::paths::DEFAULT_TEMPLATE.into(),
            min_free_gb: 5,
            upload_expiry_days: 7,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct NetworkConfig {
    /// Accept connections from public internet addresses. Off: only the home network,
    /// link-local addresses and Tailscale can connect.
    pub allow_public: bool,
    /// Extra networks allowed even when `allow_public` is off, e.g. `"203.0.113.0/24"`.
    pub allowed_networks: Vec<Cidr>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct TlsConfig {
    /// Your own certificate (PEM, full chain), e.g. from Tailscale or Let's Encrypt.
    /// Leave empty to use the certificate Halden creates during setup.
    pub cert_file: Option<PathBuf>,
    /// The private key belonging to `cert_file` (PEM).
    pub key_file: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct AuthConfig {
    /// Allow signing in with username and password. Off: new devices can only be added by
    /// pairing (QR code from a signed-in device or `halden pair`).
    pub password_login: bool,
    /// Sign out devices that haven't been used for this many days. 0: never.
    pub device_inactive_days: u32,
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            password_login: true,
            device_inactive_days: 365,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SecurityConfig {
    /// Keep security log entries (sign-ins, new devices, account changes) this many days.
    /// 0: keep them forever.
    pub log_retention_days: u32,
}

impl Default for SecurityConfig {
    fn default() -> Self {
        Self {
            log_retention_days: 90,
        }
    }
}

/// The computer's host name without a domain, or "Halden" when the host name is empty or a
/// machine-made id (some containers and VMs are named like `946e80f9-0794-…`).
pub fn default_server_name() -> String {
    friendly_name(&gethostname::gethostname().to_string_lossy())
}

fn friendly_name(host: &str) -> String {
    host.split('.')
        .next()
        .map(str::trim)
        .filter(|name| !name.is_empty() && name.len() <= 32 && uuid::Uuid::parse_str(name).is_err())
        .unwrap_or("Halden")
        .to_string()
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path).with_context(|| {
            format!(
                "could not read the config file {} (run `halden setup` first)",
                path.display()
            )
        })?;
        let config: Config = toml::from_str(&text)
            .with_context(|| format!("the config file {} is not valid", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        if self.server.name.trim().is_empty() {
            bail!("server.name must not be empty");
        }
        for (key, dir) in [
            ("storage.data_dir", &self.storage.data_dir),
            ("storage.library_dir", &self.storage.library_dir),
        ] {
            if !dir.is_absolute() {
                bail!("{key} must be an absolute path, not {}", dir.display());
            }
        }
        if self.storage.data_dir == self.storage.library_dir {
            bail!("storage.data_dir and storage.library_dir must be different folders");
        }
        crate::library::paths::PathTemplate::parse(&self.storage.path_template)
            .map_err(|problem| anyhow::anyhow!("storage.path_template: {problem}"))?;
        if self.tls.cert_file.is_some() != self.tls.key_file.is_some() {
            bail!("tls.cert_file and tls.key_file must be set together");
        }
        Ok(())
    }

    pub fn to_toml(&self) -> Result<String> {
        let body = toml::to_string_pretty(self).context("could not write the config")?;
        Ok(format!(
            "# Halden server configuration.\n\
             # Every key is optional; see docs or `halden --help`.\n\
             # Restart the server after changes: sudo systemctl restart halden\n\n{body}"
        ))
    }

    /// Writes the config atomically, readable by its owner and group only.
    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        fsutil::write_atomic(path, self.to_toml()?.as_bytes(), 0o640)
    }

    pub fn db_path(&self) -> PathBuf {
        self.storage.data_dir.join("halden.db")
    }

    pub fn tls_dir(&self) -> PathBuf {
        self.storage.data_dir.join("tls")
    }

    /// True when the server uses the certificate Halden created (and apps pin it).
    pub fn uses_generated_certificate(&self) -> bool {
        self.tls.cert_file.is_none()
    }

    pub fn cert_path(&self) -> PathBuf {
        self.tls
            .cert_file
            .clone()
            .unwrap_or_else(|| self.tls_dir().join("cert.pem"))
    }

    pub fn key_path(&self) -> PathBuf {
        self.tls
            .key_file
            .clone()
            .unwrap_or_else(|| self.tls_dir().join("key.pem"))
    }

    /// Halden's own folder inside the library: uploads in progress and database backups.
    /// Kept on the library disk so a dead system disk loses nothing that can't be restored.
    pub fn library_meta_dir(&self) -> PathBuf {
        self.storage.library_dir.join(".halden")
    }

    /// Thumbnails and previews, named by their hash, on the fast disk.
    pub fn derived_dir(&self) -> PathBuf {
        self.storage.data_dir.join("derived")
    }

    pub fn incoming_dir(&self) -> PathBuf {
        self.library_meta_dir().join("incoming")
    }

    pub fn backup_dir(&self) -> PathBuf {
        self.library_meta_dir().join("backups")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_round_trips() {
        let config = Config::default();
        let text = config.to_toml().unwrap();
        let parsed: Config = toml::from_str(&text).unwrap();
        assert_eq!(parsed, config);
    }

    #[test]
    fn empty_file_is_valid() {
        let parsed: Config = toml::from_str("").unwrap();
        parsed.validate().unwrap();
        assert_eq!(parsed.server.port, DEFAULT_PORT);
        assert!(!parsed.network.allow_public);
        assert!(parsed.auth.password_login);
        assert_eq!(parsed.auth.device_inactive_days, 365);
        assert_eq!(parsed.security.log_retention_days, 90);
    }

    #[test]
    fn unknown_keys_are_rejected() {
        assert!(toml::from_str::<Config>("[server]\nprot = 1\n").is_err());
    }

    #[test]
    fn relative_paths_and_half_tls_are_rejected() {
        let mut config = Config::default();
        config.storage.library_dir = "photos".into();
        assert!(config.validate().is_err());

        let mut config = Config::default();
        config.tls.cert_file = Some("/etc/ssl/halden.pem".into());
        assert!(config.validate().is_err());
    }

    #[test]
    fn host_names_become_friendly_server_names() {
        assert_eq!(friendly_name("homeserver.fritz.box"), "homeserver");
        assert_eq!(
            friendly_name("946e80f9-0794-4ce8-bb93-9d43726ddff6"),
            "Halden"
        );
        assert_eq!(friendly_name(""), "Halden");
    }

    #[test]
    fn networks_parse_from_strings() {
        let parsed: Config =
            toml::from_str("[network]\nallowed_networks = [\"203.0.113.0/24\"]\n").unwrap();
        assert_eq!(parsed.network.allowed_networks.len(), 1);
    }
}
