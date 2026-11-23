//! `halden pair`: a QR code in the terminal that adds a device to an account.

use std::{io::IsTerminal, path::Path, time::Duration};

use anyhow::{Context, Result, bail};
use clap::Args;

use super::{is_listening, local_time, with_database};
use crate::{
    accounts,
    auth::pairing::{self, Invite},
    db, net,
    seclog::{Event, Record},
    tls,
};

#[derive(Args)]
pub struct PairArgs {
    /// The account the device joins [default: the only account, if there is just one]
    #[arg(long)]
    user: Option<String>,
}

pub async fn run(config_path: &Path, args: PairArgs) -> Result<()> {
    with_database(config_path, async |config, pool| {
        let fingerprint = tls::identity_fingerprint(config)
            .context("could not read the certificate (try with sudo)")?;
        let user = match &args.user {
            Some(name) => super::user::find(pool, name).await?,
            None => {
                let mut users = accounts::list_users(pool).await?;
                match users.len() {
                    0 => bail!(
                        "there is no account yet; create one with `halden user add <name> --owner`"
                    ),
                    1 => users.remove(0).user,
                    _ => {
                        let names: Vec<&str> =
                            users.iter().map(|u| u.user.username.as_str()).collect();
                        bail!(
                            "which account should the device join? Add --user <name> ({})",
                            names.join(", ")
                        )
                    }
                }
            }
        };
        if user.disabled {
            bail!("the account {} is disabled", user.username);
        }

        let created = accounts::create_pairing_code(pool, &user.id, None).await?;
        Record::new(Event::PairingCodeCreated)
            .user(&user.id)
            .detail("in the terminal")
            .write(pool)
            .await;
        let addresses = net::local_addresses();
        let fingerprint_hex = fingerprint.hex();
        let url = Invite {
            server_id: db::server_id(pool).await?,
            server_name: &config.server.name,
            addresses: &addresses,
            port: config.server.port,
            fingerprint: &fingerprint_hex,
            code: &created.code,
        }
        .url();

        println!(
            "Scan this with the Halden app to add a device to {} ({}):\n",
            user.display_name, user.username
        );
        println!(
            "{}\n",
            pairing::render_qr(&url, std::io::stdout().is_terminal())?
        );
        println!("  Code         {}", pairing::display(&created.code));
        println!("  Valid until  {} (once)", local_time(created.expires_at));
        if addresses.is_empty() {
            println!(
                "\nWarning: this computer has no home network address, so the device won't find it."
            );
        }
        if !is_listening(config.server.port) {
            println!(
                "\nWarning: the server is not running, so the code can't be used yet.\n\
                 Start it with: sudo systemctl start halden"
            );
        }
        println!("\nWaiting for the device… (Ctrl-C to stop)");

        let stop = tokio::signal::ctrl_c();
        tokio::pin!(stop);
        loop {
            tokio::select! {
                _ = &mut stop => {
                    accounts::cancel_code(pool, &created.code).await?;
                    println!("Stopped. The code no longer works.");
                    return Ok(());
                }
                () = tokio::time::sleep(Duration::from_secs(1)) => {}
            }
            if let Some(device) = accounts::paired_device_for_code(pool, &created.code).await? {
                println!("✓ {} is connected.", device.name);
                return Ok(());
            }
            if db::now_ms() >= created.expires_at {
                bail!("the code expired before a device used it; run `halden pair` again");
            }
        }
    })
    .await
}
