//! `halden log`: the security log.

use std::path::Path;

use anyhow::Result;
use clap::Args;

use super::{local_time, print_table, with_database};
use crate::seclog;

#[derive(Args)]
pub struct LogArgs {
    /// How many entries, newest first.
    #[arg(long, default_value_t = 50)]
    limit: u32,
    /// Only the entries about this account.
    #[arg(long)]
    user: Option<String>,
}

pub async fn run(config_path: &Path, args: LogArgs) -> Result<()> {
    with_database(config_path, async |_, pool| {
        let user = match &args.user {
            Some(name) => Some(super::user::find(pool, name).await?),
            None => None,
        };
        let entries = seclog::list(
            pool,
            user.as_ref().map(|u| u.id.as_str()),
            None,
            args.limit.max(1),
        )
        .await?;
        if entries.is_empty() {
            println!("The security log is empty.");
            return Ok(());
        }
        // Oldest at the top, like a log file, so the newest entry is right above the prompt.
        let rows: Vec<Vec<String>> = entries
            .iter()
            .rev()
            .map(|entry| {
                vec![
                    local_time(entry.at),
                    entry.event.replace('_', " "),
                    entry.username.clone().unwrap_or_default(),
                    entry.device_name.clone().unwrap_or_default(),
                    entry.ip.clone().unwrap_or_default(),
                    entry.detail.clone().unwrap_or_default(),
                ]
            })
            .collect();
        print_table(
            &["TIME", "EVENT", "ACCOUNT", "DEVICE", "FROM", "DETAIL"],
            &rows,
        );
        Ok(())
    })
    .await
}
