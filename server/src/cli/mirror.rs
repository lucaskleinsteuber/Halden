//! `halden mirror`: the second copy on another disk.

use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::Subcommand;

use super::{Database, local_time, row};
use crate::{
    backup::mirror::{self, MirrorState},
    config::{
        Config,
        edit::{self, Change},
        keys,
    },
};

#[derive(Subcommand)]
pub enum MirrorCommand {
    /// Use this folder (another disk!) as the mirror. The server picks it up by itself.
    Set { folder: PathBuf },
    /// Stop mirroring (the copies stay where they are).
    Off,
    /// Show how far the mirror is.
    Status,
}

pub async fn run(config_path: &Path, command: MirrorCommand) -> Result<()> {
    let config = Config::load(config_path)?;
    match command {
        MirrorCommand::Set { folder } => {
            let folder = mirror::prepare(&folder, &config.storage.library_dir)?;
            if mirror::same_disk(&folder, &config.storage.library_dir) {
                println!(
                    "Warning: {} is on the same disk as the library. If that disk breaks, the \
                     mirror goes with it. Use another disk.",
                    folder.display()
                );
            }
            let key = keys::find("mirror.path").expect("mirror.path is a setting");
            edit::change(
                config_path,
                &[(key, Change::Set(folder.display().to_string().into()))],
            )?;
            println!("The mirror is {}.", folder.display());
            if !folder.starts_with("/mnt") && !folder.starts_with("/media") {
                println!(
                    "\nUnder systemd the server may only write to its own folders and to /mnt and \
                     /media. Allow this one with\n  sudo systemctl edit halden\nand add:\n  \
                     [Service]\n  ReadWritePaths={}\nthen: sudo systemctl restart halden",
                    folder.display()
                );
            }
            println!(
                "The server picks this up by itself and copies everything that is missing. \
                 `halden mirror status` shows how far it is."
            );
            Ok(())
        }
        MirrorCommand::Off => {
            let key = keys::find("mirror.path").expect("mirror.path is a setting");
            edit::change(config_path, &[(key, Change::Reset)])?;
            println!("Mirroring is off. The copies stay where they are.");
            Ok(())
        }
        MirrorCommand::Status => {
            let database = Database::open(&config).await?;
            let status = mirror::compute_status(database.pool(), &config).await;
            database.close().await?;
            print_status(&config, &status);
            Ok(())
        }
    }
}

pub(super) fn print_status(config: &Config, status: &mirror::BackupStatus) {
    let folder = config
        .mirror
        .path
        .as_ref()
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    row(
        "Mirror",
        match status.mirror {
            MirrorState::None => {
                "none: every photo exists only once (set one up with `halden mirror set`)".into()
            }
            MirrorState::Ok => format!("{folder}, complete"),
            MirrorState::Behind => {
                format!("{folder}, {} files still to copy", status.files_waiting)
            }
            MirrorState::Unreachable => {
                format!("{folder} is not reachable (disk connected? marker file there?)")
            }
        },
    );
    if status.mirror_on_same_disk {
        row("", "WARNING: the mirror is on the same disk as the library");
    }
    row(
        "DB backup",
        status
            .last_database_backup_at
            .map_or_else(|| "none yet".into(), local_time),
    );
}
