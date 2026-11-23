//! Every setting by name (`section.key`), with its type, who may change it, and a short
//! explanation for `halden config list` and the apps.

use serde::Serialize;
use serde_json::Value;

use super::Config;

/// Who may change a setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Access {
    /// The owner, in the terminal or in the app.
    Owner,
    /// The owner, and in the app only with the password again: it changes who can get in, or
    /// can delete data.
    Password,
    /// Only in the terminal: a wrong value would lock the apps out (folders, port, certificate).
    Terminal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Text,
    Number,
    Bool,
    /// An absolute path.
    Path,
    /// An absolute path, or nothing.
    OptionalPath,
    /// An IP address.
    Ip,
    /// A list of networks like `192.0.2.0/24`.
    Networks,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Key {
    pub name: &'static str,
    pub kind: Kind,
    pub access: Access,
    pub about: &'static str,
}

impl Key {
    pub fn section(&self) -> &'static str {
        self.name.split_once('.').map_or(self.name, |(s, _)| s)
    }

    pub fn field(&self) -> &'static str {
        self.name.split_once('.').map_or(self.name, |(_, f)| f)
    }

    /// This setting's value in `config`, as JSON (`null` when not set).
    pub fn value_in(&self, config: &Config) -> Value {
        serde_json::to_value(config)
            .ok()
            .and_then(|all| all.get(self.section())?.get(self.field()).cloned())
            .unwrap_or(Value::Null)
    }
}

const fn key(name: &'static str, kind: Kind, access: Access, about: &'static str) -> Key {
    Key {
        name,
        kind,
        access,
        about,
    }
}

use Access::{Owner, Password, Terminal};
use Kind::{Bool, Ip, Networks, Number, OptionalPath, Path, Text};

pub const KEYS: &[Key] = &[
    key(
        "server.name",
        Text,
        Owner,
        "Name the apps show for this server.",
    ),
    key(
        "server.bind",
        Ip,
        Terminal,
        "Address to listen on; :: means every address.",
    ),
    key("server.port", Number, Terminal, "Port for HTTPS."),
    key(
        "storage.data_dir",
        Path,
        Terminal,
        "Database, keys and thumbnails, best on the fast system disk.",
    ),
    key(
        "storage.library_dir",
        Path,
        Terminal,
        "Original photos and videos in readable folders, usually the big data disk.",
    ),
    key(
        "storage.path_template",
        Text,
        Owner,
        "Where a new original goes in the library: {user}, {year}, {month}, {day}, {date}, \
         {time}, {hour}, {minute}, {second}.",
    ),
    key(
        "storage.min_free_gb",
        Number,
        Owner,
        "Refuse uploads that would leave less free space than this on the library disk (GB).",
    ),
    key(
        "storage.upload_expiry_days",
        Number,
        Owner,
        "Unfinished uploads are thrown away after this many days without progress.",
    ),
    key(
        "network.allow_public",
        Bool,
        Password,
        "Accept connections from the internet. Off: home network and Tailscale only.",
    ),
    key(
        "network.allowed_networks",
        Networks,
        Password,
        "Extra networks allowed even when the internet is not, e.g. 203.0.113.0/24.",
    ),
    key(
        "network.bonjour",
        Bool,
        Password,
        "Announce the server in the home network, so the apps find it by themselves.",
    ),
    key(
        "tls.cert_file",
        OptionalPath,
        Terminal,
        "Your own certificate (PEM). Empty: the one Halden made.",
    ),
    key(
        "tls.key_file",
        OptionalPath,
        Terminal,
        "The private key of your own certificate (PEM).",
    ),
    key(
        "auth.password_login",
        Bool,
        Password,
        "Allow signing in with username and password. Off: new devices only by pairing.",
    ),
    key(
        "auth.device_inactive_days",
        Number,
        Password,
        "Sign out devices unused for this many days. 0: never.",
    ),
    key(
        "security.log_retention_days",
        Number,
        Password,
        "Keep security log entries this many days. 0: forever.",
    ),
    key(
        "library.location_suggest_minutes",
        Number,
        Owner,
        "Suggest a location from the nearest photo with one, at most this many minutes away.",
    ),
    key(
        "library.trash_days",
        Number,
        Password,
        "Photos stay in the trash this many days, then they are deleted for good.",
    ),
    key(
        "library.tombstone_days",
        Number,
        Owner,
        "Devices learn about deletions for this many days; a device that syncs later starts over.",
    ),
    key(
        "jobs.workers",
        Number,
        Owner,
        "Background jobs (thumbnails, conversions, mirror copies) at the same time.",
    ),
    key(
        "jobs.thumbnail_delay_minutes",
        Number,
        Owner,
        "The server makes thumbnails only if the phone hasn't sent them after this long.",
    ),
    key(
        "jobs.external_timeout_minutes",
        Number,
        Owner,
        "ffmpeg and libheif are stopped after this many minutes.",
    ),
    key(
        "backup.keep",
        Number,
        Owner,
        "Daily database backups to keep.",
    ),
    key(
        "mirror.path",
        OptionalPath,
        Password,
        "A second copy of everything on another disk. Empty: no mirror.",
    ),
    key(
        "update.check_daily",
        Bool,
        Password,
        "Look for a new version once a day. Installing always waits for the owner.",
    ),
    key(
        "update.beta",
        Bool,
        Password,
        "Also offer test versions (pre-releases).",
    ),
];

/// The setting called `name`, if there is one.
pub fn find(name: &str) -> Option<&'static Key> {
    KEYS.iter().find(|key| key.name == name)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every field of the config has exactly one entry here, and every entry is a real field,
    /// so a new setting can't be forgotten in `halden config` and the apps.
    #[test]
    fn every_setting_is_listed() {
        let mut config = Config::default();
        // Optional settings only show up when set.
        config.tls.cert_file = Some("/c.pem".into());
        config.tls.key_file = Some("/k.pem".into());
        config.mirror.path = Some("/mirror".into());
        let all = serde_json::to_value(&config).unwrap();
        let mut fields = Vec::new();
        for (section, table) in all.as_object().unwrap() {
            for field in table.as_object().unwrap().keys() {
                fields.push(format!("{section}.{field}"));
            }
        }
        fields.sort();
        let mut listed: Vec<String> = KEYS.iter().map(|k| k.name.to_string()).collect();
        listed.sort();
        assert_eq!(fields, listed);
        assert_eq!(find("library.trash_days").unwrap().access, Access::Password);
        assert_eq!(find("server.port").unwrap().access, Access::Terminal);
        assert!(find("nope.nothing").is_none());
        assert_eq!(find("backup.keep").unwrap().value_in(&config), 14);
        assert_eq!(
            find("mirror.path").unwrap().value_in(&Config::default()),
            Value::Null
        );
    }
}
