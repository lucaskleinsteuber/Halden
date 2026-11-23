//! What the last update check or installation found, in `<data>/update-status`. The server
//! writes it after its daily check, `halden update` (root) while installing; the apps read it.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{config::Config, fsutil};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdateState {
    /// Not checked yet.
    #[default]
    Unknown,
    UpToDate,
    Available,
    Installing,
    Installed,
    /// The check or the installation failed; nothing was changed.
    Failed,
    /// The new version didn't start; the old one and its database are back.
    RolledBack,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UpdateStatus {
    pub state: UpdateState,
    /// The version that was installed when this was written.
    pub installed: String,
    /// The newest version found.
    pub latest: Option<String>,
    pub prerelease: bool,
    /// The release's page with its notes.
    pub notes_url: Option<String>,
    /// Unix milliseconds.
    pub checked_at: Option<i64>,
    /// What went wrong, or what happened.
    pub message: Option<String>,
}

pub fn path(config: &Config) -> PathBuf {
    config.storage.data_dir.join("update-status")
}

/// Asks root's updater to install the newest version.
pub fn install_request(config: &Config) -> PathBuf {
    config.storage.data_dir.join("update-requested")
}

pub fn read(config: &Config) -> UpdateStatus {
    read_from(&path(config))
}

pub fn read_from(path: &Path) -> UpdateStatus {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// Writes the status so the server (another user than root) can read it.
pub fn write(config: &Config, status: &UpdateStatus) -> anyhow::Result<()> {
    let json = serde_json::to_vec_pretty(status)?;
    fsutil::write_atomic(&path(config), &json, 0o644)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_unknown_when_missing() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.storage.data_dir = dir.path().to_path_buf();
        assert_eq!(read(&config).state, UpdateState::Unknown);
        let status = UpdateStatus {
            state: UpdateState::Available,
            installed: "0.1.0".into(),
            latest: Some("0.2.0".into()),
            ..Default::default()
        };
        write(&config, &status).unwrap();
        assert_eq!(read(&config), status);
        let text = std::fs::read_to_string(path(&config)).unwrap();
        assert!(text.contains("\"state\": \"available\""), "{text}");
    }
}
