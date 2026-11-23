//! Changing the config file in place. Only the changed keys are touched: comments, order and
//! everything else in the file stay as they were. A change is checked in full (the whole new
//! file must be a valid config) before anything is written, and the file is replaced
//! atomically, keeping its owner and permissions.

use std::{net::IpAddr, path::Path};

use anyhow::{Context, Result, bail};
use toml_edit::{Array, DocumentMut, Item, Table, Value as TomlValue};

use super::{
    Config,
    keys::{Key, Kind},
};
use crate::{fsutil, net::Cidr};

#[derive(Debug, Clone)]
pub enum Change {
    Set(TomlValue),
    /// Back to the default: the key is removed from the file.
    Reset,
}

/// A value typed in the terminal (`halden config set <key> <value>`).
pub fn from_text(key: &Key, text: &str) -> Result<Change> {
    let text = text.trim();
    Ok(match key.kind {
        Kind::Text => Change::Set(text.into()),
        Kind::Number => Change::Set(number(key, text.parse::<u64>().ok())?),
        Kind::Bool => Change::Set(
            match text.to_ascii_lowercase().as_str() {
                "true" | "on" | "yes" | "1" => true,
                "false" | "off" | "no" | "0" => false,
                _ => bail!("{} must be true or false", key.name),
            }
            .into(),
        ),
        Kind::Path => Change::Set(absolute(key, text)?.into()),
        Kind::OptionalPath => match text {
            "" | "none" | "off" => Change::Reset,
            path => Change::Set(absolute(key, path)?.into()),
        },
        Kind::Ip => Change::Set(ip(key, text)?.into()),
        Kind::Networks => Change::Set(networks(
            key,
            text.split(',').map(str::trim).filter(|n| !n.is_empty()),
        )?),
    })
}

/// A value sent by an app. `null` puts the setting back to its default.
pub fn from_json(key: &Key, value: &serde_json::Value) -> Result<Change> {
    use serde_json::Value as J;
    if value.is_null() {
        return Ok(Change::Reset);
    }
    let wrong = || anyhow::anyhow!("{} has the wrong type", key.name);
    Ok(match key.kind {
        Kind::Text => Change::Set(value.as_str().ok_or_else(wrong)?.into()),
        Kind::Number => Change::Set(number(key, value.as_u64())?),
        Kind::Bool => Change::Set(value.as_bool().ok_or_else(wrong)?.into()),
        Kind::Path => Change::Set(absolute(key, value.as_str().ok_or_else(wrong)?)?.into()),
        Kind::OptionalPath => match value.as_str().ok_or_else(wrong)? {
            "" => Change::Reset,
            path => Change::Set(absolute(key, path)?.into()),
        },
        Kind::Ip => Change::Set(ip(key, value.as_str().ok_or_else(wrong)?)?.into()),
        Kind::Networks => {
            let J::Array(items) = value else {
                return Err(wrong());
            };
            let texts: Option<Vec<&str>> = items.iter().map(J::as_str).collect();
            Change::Set(networks(key, texts.ok_or_else(wrong)?.into_iter())?)
        }
    })
}

fn number(key: &Key, value: Option<u64>) -> Result<TomlValue> {
    let value = value
        .and_then(|n| i64::try_from(n).ok())
        .with_context(|| format!("{} must be a whole number of 0 or more", key.name))?;
    Ok(value.into())
}

fn absolute<'a>(key: &Key, path: &'a str) -> Result<&'a str> {
    if !Path::new(path).is_absolute() {
        bail!("{} must be an absolute path like /mnt/photos", key.name);
    }
    Ok(path)
}

fn ip(key: &Key, text: &str) -> Result<String> {
    text.parse::<IpAddr>()
        .map(|ip| ip.to_string())
        .map_err(|_| anyhow::anyhow!("{} must be an IP address", key.name))
}

fn networks<'a>(key: &Key, texts: impl Iterator<Item = &'a str>) -> Result<TomlValue> {
    let mut array = Array::new();
    for text in texts {
        let cidr: Cidr = text
            .parse()
            .map_err(|problem: String| anyhow::anyhow!("{}: {problem}", key.name))?;
        array.push(cidr.to_string());
    }
    Ok(TomlValue::Array(array))
}

/// Applies `changes` to the text of a config file. Returns the new text and the config it
/// describes, which has been fully checked.
pub fn apply(text: &str, changes: &[(&Key, Change)]) -> Result<(String, Config)> {
    let mut document: DocumentMut = text.parse().context("the config file is not valid TOML")?;
    for (key, change) in changes {
        match change {
            Change::Set(value) => {
                let section = document
                    .entry(key.section())
                    .or_insert_with(|| Item::Table(Table::new()));
                let Some(table) = section.as_table_like_mut() else {
                    bail!("[{}] in the config file is not a section", key.section());
                };
                match table.get_mut(key.field()) {
                    // Replacing only the value keeps the comment above the key.
                    Some(Item::Value(old)) => {
                        let decor = old.decor().clone();
                        *old = value.clone();
                        *old.decor_mut() = decor;
                    }
                    _ => {
                        table.insert(key.field(), Item::Value(value.clone()));
                    }
                }
            }
            Change::Reset => {
                if let Some(table) = document
                    .get_mut(key.section())
                    .and_then(Item::as_table_like_mut)
                {
                    table.remove(key.field());
                }
            }
        }
    }
    let text = document.to_string();
    let config: Config =
        toml::from_str(&text).context("with this change the config would not be valid")?;
    config.validate()?;
    Ok((text, config))
}

/// Changes the config file at `path`. Returns the new config.
pub fn change(path: &Path, changes: &[(&Key, Change)]) -> Result<Config> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("could not read the config file {}", path.display()))?;
    let (new_text, config) = apply(&text, changes)?;
    if new_text != text {
        fsutil::replace_file(path, new_text.as_bytes()).with_context(|| {
            format!(
                "could not save the config file {} (may the server's user write to its \
                 folder? `sudo halden setup` sets that up)",
                path.display()
            )
        })?;
    }
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::keys::find;

    const FILE: &str = "# My server\n\n[server]\n# Shown in the app\nname = \"box\"\n\n\
                        [library]\ntrash_days = 30 # a month\n";

    #[test]
    fn changes_keep_comments_and_layout() {
        let changes = [
            (
                find("library.trash_days").unwrap(),
                from_text(find("library.trash_days").unwrap(), "60").unwrap(),
            ),
            (
                find("auth.password_login").unwrap(),
                from_text(find("auth.password_login").unwrap(), "off").unwrap(),
            ),
        ];
        let (text, config) = apply(FILE, &changes).unwrap();
        assert!(text.starts_with("# My server\n\n[server]\n# Shown in the app\nname = \"box\"\n"));
        assert!(text.contains("trash_days = 60"), "{text}");
        assert!(text.contains("[auth]\npassword_login = false"), "{text}");
        assert_eq!(config.library.trash_days, 60);
        assert!(!config.auth.password_login);
        assert_eq!(config.server.name, "box");

        let (text, config) = apply(
            &text,
            &[(find("library.trash_days").unwrap(), Change::Reset)],
        )
        .unwrap();
        assert!(!text.contains("trash_days"));
        assert_eq!(config.library.trash_days, 30);
    }

    #[test]
    fn wrong_values_are_refused_before_writing() {
        let trash = find("library.trash_days").unwrap();
        assert!(from_text(trash, "-1").is_err());
        assert!(from_text(trash, "soon").is_err());
        assert!(from_text(find("network.allow_public").unwrap(), "maybe").is_err());
        assert!(from_text(find("storage.data_dir").unwrap(), "relative").is_err());
        assert!(from_text(find("network.allowed_networks").unwrap(), "300.1.1.1/8").is_err());
        assert!(from_json(trash, &serde_json::json!("60")).is_err());
        // The whole file must stay valid: a library inside the data folder's name clash.
        let same = find("storage.library_dir").unwrap();
        let change = from_text(same, "/var/lib/halden").unwrap();
        assert!(apply(FILE, &[(same, change)]).is_err());
        // A value too big for the setting.
        let big = from_text(trash, "99999999999").unwrap();
        assert!(apply(FILE, &[(trash, big)]).is_err());
    }

    #[test]
    fn values_from_the_app() {
        let networks = find("network.allowed_networks").unwrap();
        let change =
            from_json(networks, &serde_json::json!(["203.0.113.0/24", "10.1.2.3"])).unwrap();
        let (_, config) = apply("", &[(networks, change)]).unwrap();
        assert_eq!(config.network.allowed_networks.len(), 2);
        let mirror = find("mirror.path").unwrap();
        let (text, config) = apply(
            "",
            &[(
                mirror,
                from_json(mirror, &serde_json::json!("/mnt/usb")).unwrap(),
            )],
        )
        .unwrap();
        assert_eq!(config.mirror.path.as_deref(), Some(Path::new("/mnt/usb")));
        let (_, config) = apply(
            &text,
            &[(mirror, from_json(mirror, &serde_json::Value::Null).unwrap())],
        )
        .unwrap();
        assert!(config.mirror.path.is_none());
    }

    #[test]
    fn the_file_is_replaced_atomically_keeping_its_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(&path, FILE).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o660)).unwrap();
        let backup = find("backup.keep").unwrap();
        let config = change(&path, &[(backup, from_text(backup, "3").unwrap())]).unwrap();
        assert_eq!(config.backup.keep, 3);
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o660);
        assert!(
            std::fs::read_to_string(&path)
                .unwrap()
                .contains("# a month")
        );
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }
}
