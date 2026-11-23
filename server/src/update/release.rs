//! Reading GitHub's release list and picking the version to install.

use anyhow::{Context, Result};
use serde::Deserialize;

/// Server releases are tagged `server-v<version>`.
pub const TAG_PREFIX: &str = "server-v";
pub const SUMS: &str = "SHA256SUMS";
pub const SIGNATURE: &str = "SHA256SUMS.minisig";

#[derive(Debug, Clone, Deserialize)]
pub struct Asset {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Release {
    pub tag_name: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub prerelease: bool,
    #[serde(default)]
    pub html_url: String,
    #[serde(default)]
    pub assets: Vec<Asset>,
}

impl Release {
    pub fn version(&self) -> Option<semver::Version> {
        semver::Version::parse(self.tag_name.strip_prefix(TAG_PREFIX)?).ok()
    }

    fn asset(&self, name: &str) -> Option<&Asset> {
        self.assets.iter().find(|asset| asset.name == name)
    }
}

/// The package for this computer: `halden-<version>-<arch>-linux.tar.gz`.
pub fn package_name(version: &semver::Version, arch: &str) -> String {
    format!("halden-{version}-{arch}-linux.tar.gz")
}

/// A newer release with everything needed to install it.
#[derive(Debug, Clone)]
pub struct Found {
    pub version: semver::Version,
    pub prerelease: bool,
    pub notes_url: String,
    pub package: Asset,
    pub sums: Asset,
    pub signature: Asset,
}

pub fn parse(json: &[u8]) -> Result<Vec<Release>> {
    serde_json::from_slice(json).context("GitHub's release list could not be read")
}

/// The newest release that is newer than `current`, has a package for `arch`, a checksum list
/// and its signature. Drafts never; test versions only with `beta`.
pub fn choose(
    releases: &[Release],
    current: &semver::Version,
    beta: bool,
    arch: &str,
) -> Option<Found> {
    releases
        .iter()
        .filter(|release| !release.draft && (beta || !release.prerelease))
        .filter_map(|release| {
            let version = release.version()?;
            // A test version (1.2.0-rc.1) only with beta on, whatever GitHub calls it.
            if !beta && !version.pre.is_empty() {
                return None;
            }
            if &version <= current {
                return None;
            }
            Some(Found {
                package: release.asset(&package_name(&version, arch))?.clone(),
                sums: release.asset(SUMS)?.clone(),
                signature: release.asset(SIGNATURE)?.clone(),
                prerelease: release.prerelease || !version.pre.is_empty(),
                notes_url: release.html_url.clone(),
                version,
            })
        })
        .max_by(|a, b| a.version.cmp(&b.version))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(tag: &str, prerelease: bool, draft: bool, with_package: bool) -> serde_json::Value {
        let version = tag.trim_start_matches(TAG_PREFIX);
        let mut assets = vec![
            serde_json::json!({ "name": SUMS, "browser_download_url": format!("https://x/{tag}/sums") }),
            serde_json::json!({ "name": SIGNATURE, "browser_download_url": format!("https://x/{tag}/sig") }),
        ];
        if with_package {
            assets.push(serde_json::json!({
                "name": format!("halden-{version}-x86_64-linux.tar.gz"),
                "browser_download_url": format!("https://x/{tag}/pkg"), "size": 10
            }));
        }
        serde_json::json!({ "tag_name": tag, "prerelease": prerelease, "draft": draft,
                            "html_url": format!("https://x/{tag}"), "assets": assets })
    }

    #[test]
    fn picks_the_newest_newer_signed_release() {
        let list = serde_json::json!([
            release("server-v0.3.0-rc.1", true, false, true),
            release("server-v0.2.1", false, false, true),
            release("server-v0.2.0", false, false, true),
            release("server-v0.4.0", false, true, true),
            release("server-v0.5.0", false, false, false),
            release("mac-v9.0.0", false, false, true),
        ]);
        let releases = parse(list.to_string().as_bytes()).unwrap();
        let current = semver::Version::new(0, 1, 0);
        let found = choose(&releases, &current, false, "x86_64").unwrap();
        assert_eq!(
            found.version.to_string(),
            "0.2.1",
            "no drafts, no package, no other product"
        );
        assert!(
            found
                .package
                .browser_download_url
                .ends_with("server-v0.2.1/pkg")
        );
        let found = choose(&releases, &current, true, "x86_64").unwrap();
        assert_eq!(found.version.to_string(), "0.3.0-rc.1");
        assert!(found.prerelease);
        // Never older or the same.
        assert!(choose(&releases, &semver::Version::new(0, 2, 1), false, "x86_64").is_none());
        assert!(choose(&releases, &semver::Version::new(1, 0, 0), true, "x86_64").is_none());
        // No package for this processor.
        assert!(choose(&releases, &current, false, "aarch64").is_none());
    }
}
