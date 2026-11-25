//! `halden update`: look for, download, check and install a new version (as root). See
//! [`crate::update`].

use std::path::Path;

use anyhow::{Result, bail};
use clap::Args;

use super::ask_line;
use crate::{
    VERSION,
    config::{
        Config,
        edit::{self, Change},
        keys,
    },
    update::{
        self, Source,
        install::{self, Machine, Outcome},
        status::{self, UpdateState},
    },
};

#[derive(Args)]
pub struct UpdateArgs {
    /// Only look: show the installed and the newest version.
    #[arg(long)]
    check: bool,
    /// Install without asking.
    #[arg(long)]
    yes: bool,
    /// Also install test versions (pre-releases): on or off.
    #[arg(long, value_name = "on|off")]
    beta: Option<String>,
    /// Run by systemd when the app asked for an update.
    #[arg(long, hide = true)]
    from_app: bool,
}

pub async fn run(config_path: &Path, args: UpdateArgs) -> Result<()> {
    let config = Config::load(config_path)?;
    if let Some(beta) = args.beta {
        let key = keys::find("update.beta").expect("update.beta is a setting");
        let change = edit::from_text(key, &beta)?;
        let on = matches!(&change, Change::Set(value) if value.as_bool() == Some(true));
        edit::change(config_path, &[(key, change)])?;
        if on {
            println!("Test versions are on: halden update also installs pre-releases.");
        } else {
            println!(
                "Test versions are off. An installed test version stays until a newer release \
                 comes out."
            );
        }
        return Ok(());
    }
    if std::env::var_os("HALDEN_IN_DOCKER").is_some() {
        bail!(
            "in Docker, update by pulling the new image: docker compose pull && docker compose up -d"
        );
    }
    let mut yes = args.yes;
    if args.from_app {
        // Only a request file left by the server starts an installation; it carries nothing.
        let request = status::install_request(&config);
        if !request.exists() {
            return Ok(());
        }
        let _ = std::fs::remove_file(&request);
        yes = true;
    }

    let source = Source::official();
    let checked = match update::check(&source, config.update.beta).await {
        Ok(checked) => checked,
        Err(error) => {
            install::report(
                &config,
                UpdateState::Failed,
                VERSION,
                None,
                Some(format!("{error:#}")),
            );
            return Err(error);
        }
    };
    install::checked(&config, &checked);
    // With test versions off, say when one is waiting: while Halden is 0.x every release is one.
    let test_hint = checked.test_version.as_ref().map(|test| {
        format!(
            "Test version {test} is available too. To get test versions: sudo halden update --beta on"
        )
    });
    let Some(found) = checked.found else {
        println!("Halden {VERSION} is the newest version.");
        if let Some(hint) = test_hint {
            println!("{hint}");
        }
        return Ok(());
    };
    println!(
        "Installed: {VERSION}\nNewest:    {}{}\nNotes:     {}",
        found.version,
        if found.prerelease {
            " (test version)"
        } else {
            ""
        },
        found.notes_url
    );
    if let Some(hint) = test_hint {
        println!("{hint}");
    }
    if args.check {
        return Ok(());
    }
    if source.key.is_none() {
        let message = "this build has no release key, so it installs no updates; install the new \
                       version by hand (see docs/UPDATE_SIGNING.md)";
        install::report(
            &config,
            UpdateState::Failed,
            VERSION,
            Some(&found),
            Some(message.into()),
        );
        bail!(message);
    }
    if !yes {
        let answer = ask_line(&format!("Install Halden {} now? [y/N] ", found.version))?;
        if !matches!(answer.to_lowercase().as_str(), "y" | "yes" | "j" | "ja") {
            println!("Nothing was installed.");
            return Ok(());
        }
    }

    install::report(
        &config,
        UpdateState::Installing,
        VERSION,
        Some(&found),
        Some(format!("installing {}", found.version)),
    );
    let work = config
        .storage
        .data_dir
        .join("update")
        .join(found.version.to_string());
    let result = async {
        let downloaded = install::download(&source, &found, &work).await?;
        let machine = Machine::this().await?;
        install::install(config_path, &config, &machine, &downloaded, &found.version).await
    }
    .await;
    let _ = std::fs::remove_dir_all(&work);
    let new = found.version.to_string();
    match result {
        Ok(Outcome::Installed { restarted: true }) => {
            install::report(
                &config,
                UpdateState::Installed,
                &new,
                Some(&found),
                Some(format!("Halden {new} is installed and running")),
            );
            println!("Halden {new} is installed and running.");
            Ok(())
        }
        Ok(Outcome::Installed { restarted: false }) => {
            install::report(
                &config,
                UpdateState::Installed,
                &new,
                Some(&found),
                Some(format!(
                    "Halden {new} is installed; start the server again to use it"
                )),
            );
            println!("Halden {new} is installed. Start the server again to use it.");
            Ok(())
        }
        Ok(Outcome::RolledBack) => {
            let message = format!(
                "Halden {new} did not start, so {VERSION} and its database are back; nothing was lost"
            );
            install::report(
                &config,
                UpdateState::RolledBack,
                VERSION,
                Some(&found),
                Some(message.clone()),
            );
            bail!(message)
        }
        Err(error) => {
            install::report(
                &config,
                UpdateState::Failed,
                VERSION,
                Some(&found),
                Some(format!("{error:#}")),
            );
            Err(error)
        }
    }
}
