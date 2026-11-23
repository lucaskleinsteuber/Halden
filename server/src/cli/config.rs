//! `halden config`: show and change settings. Changes go into the config file with its comments
//! kept; the running server picks them up by itself within a few seconds.

use std::path::Path;

use anyhow::{Context, Result};
use clap::Subcommand;
use serde_json::Value;

use super::{is_listening, print_table};
use crate::{
    backup::mirror,
    config::{
        Config,
        edit::{self, Change},
        keys::{self, Access, Key},
    },
};

#[derive(Subcommand)]
pub enum ConfigCommand {
    /// Show every setting with its value and what it does.
    List,
    /// Show one setting, e.g. `halden config get library.trash_days`.
    Get { key: String },
    /// Change a setting, e.g. `halden config set library.trash_days 60`.
    Set { key: String, value: String },
    /// Put a setting back to its default.
    Reset { key: String },
}

pub async fn run(config_path: &Path, command: ConfigCommand) -> Result<()> {
    let config = Config::load(config_path)?;
    match command {
        ConfigCommand::List => {
            let defaults = Config::default();
            let rows: Vec<Vec<String>> = keys::KEYS
                .iter()
                .map(|key| {
                    let value = key.value_in(&config);
                    let marker = if value == key.value_in(&defaults) {
                        ""
                    } else {
                        " *"
                    };
                    vec![
                        key.name.to_string(),
                        format!("{}{marker}", show(&value)),
                        key.about.to_string(),
                    ]
                })
                .collect();
            print_table(&["SETTING", "VALUE", "WHAT IT DOES"], &rows);
            println!(
                "\n  * changed from the default. Change with: halden config set <setting> <value>"
            );
            Ok(())
        }
        ConfigCommand::Get { key } => {
            let key = find(&key)?;
            println!("{}", show(&key.value_in(&config)));
            Ok(())
        }
        ConfigCommand::Set { key, value } => {
            let key = find(&key)?;
            let mut change = edit::from_text(key, &value)?;
            if key.name == "mirror.path"
                && let Change::Set(value) = &change
                && let Some(folder) = value.as_str()
            {
                let folder = mirror::prepare(Path::new(folder), &config.storage.library_dir)?;
                change = Change::Set(folder.display().to_string().into());
            }
            save(config_path, &config, key, change)
        }
        ConfigCommand::Reset { key } => {
            let key = find(&key)?;
            save(config_path, &config, key, Change::Reset)
        }
    }
}

fn find(name: &str) -> Result<&'static Key> {
    keys::find(name)
        .with_context(|| format!("there is no setting {name}; `halden config list` shows them all"))
}

fn save(config_path: &Path, old: &Config, key: &'static Key, change: Change) -> Result<()> {
    let config = edit::change(config_path, &[(key, change)])?;
    let value = key.value_in(&config);
    if value == key.value_in(old) {
        println!("{} stays {}.", key.name, show(&value));
        return Ok(());
    }
    println!("{} is now {}.", key.name, show(&value));
    if is_listening(old.server.port) {
        println!("The running server picks this up by itself within a few seconds.");
    }
    if key.name == "mirror.path" && config.mirror.path.is_some() {
        println!(
            "\nUnder systemd the server may only write to its own folders. If the mirror is not \
             under /mnt or /media, allow it with\n  sudo systemctl edit halden\nand add\n  \
             [Service]\n  ReadWritePaths={}\n`halden doctor` checks this.",
            config
                .mirror
                .path
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        );
    }
    if key.access == Access::Terminal {
        println!("Devices may have to connect again.");
    }
    Ok(())
}

/// A setting's value as a person reads it.
fn show(value: &Value) -> String {
    match value {
        Value::Null => "(none)".into(),
        Value::String(text) => text.clone(),
        Value::Array(items) if items.is_empty() => "(none)".into(),
        Value::Array(items) => items.iter().map(show).collect::<Vec<_>>().join(", "),
        other => other.to_string(),
    }
}
