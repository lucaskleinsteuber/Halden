//! `halden doctor`: checks the server and says how to fix what's wrong.

use std::{io::Write, path::Path};

use anyhow::{Result, bail};
use clap::Args;

use super::{Database, human_bytes};
use crate::{
    config::Config,
    doctor::{self, Level},
};

#[derive(Args)]
pub struct DoctorArgs {
    /// Also read every photo, video and thumbnail (and the mirror's copies) and compare it with
    /// its SHA-256 from when it arrived. Takes a while on a big library.
    #[arg(long)]
    files: bool,
    /// Print the result as JSON.
    #[arg(long)]
    json: bool,
}

pub async fn run(config_path: &Path, args: DoctorArgs) -> Result<()> {
    let config = match Config::load(config_path) {
        Ok(config) => config,
        Err(error) => {
            println!("  ✗ Settings          {error:#}");
            println!("                      → correct the file; until then the server can't start");
            bail!("doctor found problems");
        }
    };
    let database = Database::open(&config).await.ok();
    let report = doctor::check(
        &config,
        database.as_ref().map(Database::pool),
        &doctor::Options {
            config_path: Some(config_path.to_path_buf()),
            ..Default::default()
        },
    )
    .await;
    let mut files = None;
    if args.files {
        match &database {
            Some(database) => {
                let quiet = args.json;
                files = Some(
                    doctor::verify_files(&config, database.pool(), move |done, total| {
                        if !quiet {
                            eprint!("\r  reading files: {done} of {total}");
                            let _ = std::io::stderr().flush();
                        }
                    })
                    .await?,
                );
                if !args.json {
                    eprintln!();
                }
            }
            None => bail!("the database can't be opened (try with sudo)"),
        }
    }
    if let Some(database) = database {
        database.close().await?;
    }

    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({ "report": report, "files": files }))?
        );
    } else {
        for check in &report.checks {
            let symbol = match check.level {
                Level::Ok => "✓",
                Level::Warning => "!",
                Level::Problem => "✗",
            };
            println!("  {symbol} {:<17} {}", check.title, check.detail);
            if let Some(fix) = &check.fix {
                for (n, line) in fix.lines().enumerate() {
                    let arrow = if n == 0 { "→ " } else { "  " };
                    println!("  {:<19} {arrow}{line}", "");
                }
            }
        }
        if let Some(files) = &files {
            println!(
                "\n  Files: {} read ({}), {} missing, {} damaged, {} not in the library's records",
                files.checked,
                human_bytes(files.bytes),
                files.missing.len(),
                files.damaged.len(),
                files.unknown.len()
            );
            if files.mirror_checked > 0 || !files.mirror_missing.is_empty() {
                println!(
                    "  Mirror: {} read, {} missing, {} damaged",
                    files.mirror_checked,
                    files.mirror_missing.len(),
                    files.mirror_damaged.len()
                );
            }
            for (label, list) in [
                ("missing", &files.missing),
                ("damaged", &files.damaged),
                ("unknown", &files.unknown),
                ("missing on the mirror", &files.mirror_missing),
                ("damaged on the mirror", &files.mirror_damaged),
            ] {
                for path in list.iter().take(20) {
                    println!("    {label}: {path}");
                }
                if list.len() > 20 {
                    println!("    … and {} more {label}", list.len() - 20);
                }
            }
            if !files.damaged.is_empty() || !files.missing.is_empty() {
                println!(
                    "  → damaged or missing originals can be copied back from the mirror, if there is one"
                );
            }
        }
    }
    let files_broken = files.as_ref().is_some_and(|f| !f.intact());
    if report.level == Level::Problem || files_broken {
        bail!("doctor found problems");
    }
    Ok(())
}
