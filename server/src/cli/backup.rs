//! `halden backup`: database backups.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use clap::Subcommand;

use super::{Database, ask_line, human_bytes, local_time, print_table};
use crate::{
    backup::{database, mirror},
    config::Config,
};

#[derive(Subcommand)]
pub enum BackupCommand {
    /// Back up the database now (works while the server runs).
    Now,
    /// List the database backups, newest first.
    List,
    /// Put a backup in place of the database. Stop the server first.
    Restore {
        /// A file from `halden backup list` (its name is enough) or a path.
        file: String,
        /// Don't ask for confirmation.
        #[arg(long)]
        yes: bool,
    },
}

pub async fn run(config_path: &Path, command: BackupCommand) -> Result<()> {
    let config = Config::load(config_path)?;
    match command {
        BackupCommand::Now => {
            let database = Database::open(&config).await?;
            let made = database::make(database.pool(), &config).await;
            database.close().await?;
            let made = made?;
            println!(
                "Backed up the database to {} ({}).",
                made.path.display(),
                human_bytes(made.size)
            );
            match mirror::mirror_backup(&config, &made.path).await {
                Ok(()) if config.mirror.path.is_some() => println!("Copied it to the mirror too."),
                Ok(()) => {}
                Err(error) => println!("Warning: not copied to the mirror: {error}"),
            }
            Ok(())
        }
        BackupCommand::List => {
            let backups = database::list(&config);
            if backups.is_empty() {
                println!("There are no backups yet. Make one with: halden backup now");
                return Ok(());
            }
            let rows: Vec<Vec<String>> = backups
                .iter()
                .map(|b| vec![b.name.clone(), local_time(b.made_at), human_bytes(b.size)])
                .collect();
            print_table(&["FILE", "MADE", "SIZE"], &rows);
            println!("\nIn {}", config.backup_dir().display());
            Ok(())
        }
        BackupCommand::Restore { file, yes } => {
            let path = if file.contains('/') {
                PathBuf::from(&file)
            } else {
                config.backup_dir().join(&file)
            };
            if !path.is_file() {
                bail!(
                    "there is no backup {} (see `halden backup list`)",
                    path.display()
                );
            }
            if !yes {
                if !std::io::IsTerminal::is_terminal(&std::io::stdin()) {
                    bail!("add --yes to restore without being asked");
                }
                let answer = ask_line(&format!(
                    "This replaces the database with {}.\n\
                     Photos uploaded after that backup stay in the library but won't be listed.\n\
                     Type \"restore\" to go on: ",
                    path.display()
                ))?;
                if answer != "restore" {
                    bail!("not restored");
                }
            }
            let aside = database::restore(&config, &path).await?;
            crate::setup::give_database_back(&config)?;
            println!("Restored {}.", path.display());
            println!(
                "The database before the restore is kept as {}.",
                aside.display()
            );
            println!("Start the server again: sudo systemctl start halden");
            Ok(())
        }
    }
}
