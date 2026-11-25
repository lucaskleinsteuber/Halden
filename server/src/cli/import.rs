//! `halden import`: a photo library from elsewhere into an account (see `crate::import`).

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use clap::Subcommand;

use super::with_database;
use crate::import::{Importer, Progress, immich::Immich, takeout::Takeout};

#[derive(Subcommand)]
pub enum ImportCommand {
    /// Google Photos from Google Takeout: the folders or the ZIP files, all parts at once.
    Takeout {
        /// The Takeout folders or ZIP files
        #[arg(required = true)]
        paths: Vec<PathBuf>,
        /// The account the photos go to
        #[arg(long)]
        user: String,
        /// Only count what would come in
        #[arg(long)]
        dry_run: bool,
    },
    /// The photos of an Immich account, with an API key from Immich (Account Settings › API Keys).
    Immich {
        /// The Immich server, as in the browser (https://immich.example.com)
        #[arg(long)]
        url: String,
        /// The API key
        #[arg(long, env = "IMMICH_API_KEY")]
        api_key: String,
        /// The account the photos go to
        #[arg(long)]
        user: String,
        /// Only count what would come in
        #[arg(long)]
        dry_run: bool,
    },
}

pub async fn run(config_path: &Path, command: ImportCommand) -> Result<()> {
    match command {
        ImportCommand::Takeout {
            paths,
            user,
            dry_run,
        } => {
            for path in &paths {
                if !path.exists() {
                    bail!("{} doesn't exist", path.display());
                }
            }
            let mut takeout = Takeout::open(&paths)?;
            let items = takeout.items();
            println!("Google Takeout: {} photos and videos found.", items.len());
            with_database(config_path, async |config, pool| {
                let mut importer =
                    Importer::connect(config, pool, &user, "Google Takeout", "takeout", dry_run)
                        .await?;
                bring(&mut importer, &items, &mut takeout).await
            })
            .await
        }
        ImportCommand::Immich {
            url,
            api_key,
            user,
            dry_run,
        } => {
            let mut immich = Immich::new(&url, &api_key)?;
            let items = immich.items().await?;
            println!("Immich: {} photos and videos found.", items.len());
            with_database(config_path, async |config, pool| {
                let mut importer =
                    Importer::connect(config, pool, &user, "Immich", "immich", dry_run).await?;
                bring(&mut importer, &items, &mut immich).await
            })
            .await
        }
    }
}

async fn bring(
    importer: &mut Importer,
    items: &[crate::import::Item],
    fetch: &mut impl crate::import::Fetch,
) -> Result<()> {
    let mut progress = Progress::new(items.len());
    for item in items {
        let outcome = importer.bring(item, fetch).await;
        progress.count(outcome, &item.file_name);
    }
    println!("{}", progress.line());
    if importer.dry_run {
        println!("Nothing was changed (--dry-run).");
    } else if progress.failed > 0 {
        println!("Run the same command again to try the ones that failed; what is in stays in.");
    } else {
        println!("Done. Thumbnails and small copies of videos follow in the background.");
    }
    Ok(())
}
