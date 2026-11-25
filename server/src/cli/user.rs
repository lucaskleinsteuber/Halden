//! `halden user …`: accounts.

use std::{io::IsTerminal, path::Path};

use anyhow::{Result, bail};
use clap::Subcommand;

use super::{ask_line, ask_new_password, local_time, print_table, with_database};
use crate::{
    accounts::{self, NewUser, Role, User},
    auth::password,
    seclog::{Event, Record},
};

#[derive(Subcommand)]
pub enum UserCommand {
    /// Create an account. Asks for its password.
    Add {
        /// Username for signing in (letters, digits, dots, dashes, underscores).
        name: String,
        /// Make the account an owner of the server.
        #[arg(long)]
        owner: bool,
        /// Name the apps show [default: the username]
        #[arg(long)]
        display_name: Option<String>,
        /// No password: devices can only join this account by pairing.
        #[arg(long)]
        no_password: bool,
    },
    /// List the accounts.
    List,
    /// Set a new password for an account. Asks for it.
    Passwd {
        name: String,
        /// Also sign out every device of the account.
        #[arg(long)]
        sign_out: bool,
    },
    /// Make an account an owner or a member.
    Role { name: String, role: Role },
    /// Delete an account and sign out its devices.
    Remove {
        name: String,
        /// Don't ask for confirmation.
        #[arg(long)]
        yes: bool,
    },
}

pub async fn run(config_path: &Path, command: UserCommand) -> Result<()> {
    match command {
        UserCommand::Add {
            name,
            owner,
            display_name,
            no_password,
        } => {
            let username = accounts::check_username(&name)?;
            let password_hash = if no_password {
                None
            } else {
                Some(password::hash(ask_new_password(&username)?).await?)
            };
            let role = if owner { Role::Owner } else { Role::Member };
            with_database(config_path, async |_, pool| {
                let user = accounts::create_user(
                    pool,
                    NewUser {
                        username: &username,
                        display_name: display_name.as_deref(),
                        role,
                        password_hash,
                    },
                )
                .await?;
                Record::new(Event::UserCreated)
                    .user(&user.id)
                    .detail(format!(
                        "{} as {} in the terminal",
                        user.username, user.role
                    ))
                    .write(pool)
                    .await;
                println!("Created the account {} ({}).", user.username, user.role);
                Ok(())
            })
            .await
        }
        UserCommand::List => {
            with_database(config_path, async |_, pool| {
                let users = accounts::list_users(pool).await?;
                if users.is_empty() {
                    println!(
                        "There are no accounts yet. Create one with: halden user add <name> --owner"
                    );
                    return Ok(());
                }
                let rows: Vec<Vec<String>> = users
                    .iter()
                    .map(|summary| {
                        let user = &summary.user;
                        vec![
                            user.username.clone(),
                            user.display_name.clone(),
                            user.role.to_string(),
                            match (user.disabled, user.has_password) {
                                (true, _) => "disabled".into(),
                                (false, true) => "active".into(),
                                (false, false) => "active, pairing only".into(),
                            },
                            summary.devices.to_string(),
                            local_time(user.created_at),
                        ]
                    })
                    .collect();
                print_table(
                    &["USERNAME", "NAME", "ROLE", "STATE", "DEVICES", "CREATED"],
                    &rows,
                );
                Ok(())
            })
            .await
        }
        UserCommand::Passwd { name, sign_out } => {
            // Look the account up first, so a typo is reported before asking for a password.
            let user = with_database(config_path, async |_, pool| find(pool, &name).await).await?;
            let hash = password::hash(ask_new_password(&user.username)?).await?;
            with_database(config_path, async |_, pool| {
                accounts::set_password_hash(pool, &user.id, &hash).await?;
                let signed_out = if sign_out {
                    accounts::revoke_other_devices(pool, &user.id, None).await?
                } else {
                    0
                };
                Record::new(Event::PasswordReset)
                    .user(&user.id)
                    .detail(format!(
                        "in the terminal, {} signed out",
                        crate::seclog::devices(signed_out as u64)
                    ))
                    .write(pool)
                    .await;
                println!("The password of {} is changed.", user.username);
                if sign_out {
                    println!("{signed_out} devices were signed out.");
                }
                Ok(())
            })
            .await
        }
        UserCommand::Role { name, role } => {
            with_database(config_path, async |_, pool| {
                let user = find(pool, &name).await?;
                if user.role == role {
                    println!("{} is already {role}.", user.username);
                    return Ok(());
                }
                accounts::set_role(pool, &user.id, role).await?;
                Record::new(Event::RoleChanged)
                    .user(&user.id)
                    .detail(format!("{} → {role} in the terminal", user.role))
                    .write(pool)
                    .await;
                println!("{} is now {role}.", user.username);
                Ok(())
            })
            .await
        }
        UserCommand::Remove { name, yes } => {
            with_database(config_path, async |_, pool| {
                let user = find(pool, &name).await?;
                if !yes {
                    if !std::io::stdin().is_terminal() {
                        bail!("add --yes to delete {} without being asked", user.username);
                    }
                    let typed = ask_line(&format!(
                        "This deletes the account {} and signs out its devices.\n\
                         Type the username to confirm: ",
                        user.username
                    ))?;
                    if !typed.eq_ignore_ascii_case(&user.username) {
                        bail!("not deleted");
                    }
                }
                accounts::delete_user(pool, &user.id).await?;
                Record::new(Event::UserDeleted)
                    .user(&user.id)
                    .detail(format!("{} in the terminal", user.username))
                    .write(pool)
                    .await;
                println!("Deleted the account {}.", user.username);
                Ok(())
            })
            .await
        }
    }
}

pub(crate) async fn find(pool: &crate::db::Db, name: &str) -> Result<User> {
    match accounts::user_by_name(pool, name).await? {
        Some(user) => Ok(user),
        None => bail!("there is no account named {name} (see `halden user list`)"),
    }
}
