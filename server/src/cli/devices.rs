//! `halden devices`: signed-in devices.

use std::path::Path;

use anyhow::{Result, bail};
use clap::{Args, Subcommand};

use super::{local_time, print_table, with_database};
use crate::{
    accounts::{self, Platform},
    seclog::{Event, Record},
};

/// Ids are shown this long; `revoke` takes any unique beginning.
const SHORT_ID: usize = 8;

#[derive(Args)]
pub struct DevicesArgs {
    /// Only the devices of this account.
    #[arg(long)]
    user: Option<String>,
    #[command(subcommand)]
    action: Option<DevicesAction>,
}

#[derive(Subcommand)]
enum DevicesAction {
    /// Sign a device out. It needs to sign in or pair again.
    Revoke {
        /// The device id from `halden devices` (the first characters are enough).
        id: String,
    },
}

pub async fn run(config_path: &Path, args: DevicesArgs) -> Result<()> {
    with_database(config_path, async |_, pool| match &args.action {
        None => {
            let user = match &args.user {
                Some(name) => Some(super::user::find(pool, name).await?),
                None => None,
            };
            let devices =
                accounts::list_devices(pool, user.as_ref().map(|u| u.id.as_str())).await?;
            if devices.is_empty() {
                println!("No devices are signed in. Add one with: halden pair");
                return Ok(());
            }
            let rows: Vec<Vec<String>> = devices
                .iter()
                .map(|listing| {
                    let device = &listing.device;
                    vec![
                        device.id.chars().take(SHORT_ID).collect(),
                        listing.username.clone(),
                        device.name.clone(),
                        match device.platform {
                            Platform::Ios => "iPhone".into(),
                            Platform::Macos => "Mac".into(),
                            Platform::Cli => "command line".into(),
                        },
                        if device.confirmed {
                            "ok".into()
                        } else {
                            "new, not confirmed".into()
                        },
                        local_time(device.last_seen_at),
                        device.last_seen_ip.clone().unwrap_or_default(),
                    ]
                })
                .collect();
            print_table(
                &[
                    "ID",
                    "ACCOUNT",
                    "NAME",
                    "KIND",
                    "STATE",
                    "LAST SEEN",
                    "FROM",
                ],
                &rows,
            );
            Ok(())
        }
        Some(DevicesAction::Revoke { id }) => {
            let mut found = accounts::find_devices_by_prefix(pool, id).await?;
            let device = match found.len() {
                0 => bail!("no signed-in device has the id {id} (see `halden devices`)"),
                1 => found.remove(0),
                _ => bail!("several devices start with {id}; type more of the id"),
            };
            accounts::revoke_device(pool, &device.id).await?;
            Record::new(Event::DeviceRevoked)
                .user(&device.user_id)
                .device(&device.id)
                .detail("in the terminal")
                .write(pool)
                .await;
            println!("Signed out {}.", device.name);
            Ok(())
        }
    })
    .await
}
