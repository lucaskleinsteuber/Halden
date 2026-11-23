//! `halden mirror`: the second copy on another disk.

use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::Subcommand;

use super::{Database, local_time, row};
use crate::{
    backup::mirror::{self, MirrorState},
    config::Config,
};

#[derive(Subcommand)]
pub enum MirrorCommand {
    /// Use this folder (another disk!) as the mirror. Restart the server afterwards.
    Set { folder: PathBuf },
    /// Stop mirroring (the copies stay where they are).
    Off,
    /// Show how far the mirror is.
    Status,
}

pub async fn run(config_path: &Path, command: MirrorCommand) -> Result<()> {
    let mut config = Config::load(config_path)?;
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
            config.mirror.path = Some(folder.clone());
            config.save(config_path)?;
            println!("The mirror is {}.", folder.display());
            println!(
                "\nThe server may only write to its own folders. Allow this one with\n  \
                 sudo systemctl edit halden\nand add:\n  [Service]\n  ReadWritePaths={}\n\
                 then restart the server:\n  sudo systemctl restart halden\n\
                 It copies everything that is missing right after starting.",
                folder.display()
            );
            Ok(())
        }
        MirrorCommand::Off => {
            config.mirror.path = None;
            config.save(config_path)?;
            println!("Mirroring is off. Restart the server: sudo systemctl restart halden");
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
