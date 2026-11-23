//! The security log: sign-ins, new devices, blocked devices, account changes.
//!
//! Members see their own entries, owners see all of them. Entries never contain passwords,
//! tokens, pairing codes or file paths. Old entries are removed after `security.log_retention_days`.

use std::net::IpAddr;

use anyhow::Result;
use serde::Serialize;

use crate::db::{Db, now_ms};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    LoginSucceeded,
    LoginFailed,
    LoginThrottled,
    PairingCodeCreated,
    PairSucceeded,
    PairFailed,
    PairingCodesCancelled,
    BlockedDeviceRefused,
    Logout,
    DeviceConfirmed,
    DeviceBlocked,
    DeviceRevoked,
    DeviceExpired,
    PasswordChanged,
    PasswordReset,
    PasswordCheckFailed,
    UserCreated,
    UserRenamed,
    RoleChanged,
    UserDisabled,
    UserEnabled,
    UserDeleted,
}

impl Event {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LoginSucceeded => "login_succeeded",
            Self::LoginFailed => "login_failed",
            Self::LoginThrottled => "login_throttled",
            Self::PairingCodeCreated => "pairing_code_created",
            Self::PairSucceeded => "pair_succeeded",
            Self::PairFailed => "pair_failed",
            Self::PairingCodesCancelled => "pairing_codes_cancelled",
            Self::BlockedDeviceRefused => "blocked_device_refused",
            Self::Logout => "logout",
            Self::DeviceConfirmed => "device_confirmed",
            Self::DeviceBlocked => "device_blocked",
            Self::DeviceRevoked => "device_revoked",
            Self::DeviceExpired => "device_expired",
            Self::PasswordChanged => "password_changed",
            Self::PasswordReset => "password_reset",
            Self::PasswordCheckFailed => "password_check_failed",
            Self::UserCreated => "user_created",
            Self::UserRenamed => "user_renamed",
            Self::RoleChanged => "role_changed",
            Self::UserDisabled => "user_disabled",
            Self::UserEnabled => "user_enabled",
            Self::UserDeleted => "user_deleted",
        }
    }
}

/// One entry about to be written.
pub struct Record<'a> {
    event: Event,
    user_id: Option<&'a str>,
    device_id: Option<&'a str>,
    ip: Option<IpAddr>,
    detail: Option<String>,
}

impl<'a> Record<'a> {
    pub fn new(event: Event) -> Self {
        Self {
            event,
            user_id: None,
            device_id: None,
            ip: None,
            detail: None,
        }
    }

    /// The account the entry is about (it shows up in that account's log).
    pub fn user(mut self, user_id: &'a str) -> Self {
        self.user_id = Some(user_id);
        self
    }

    pub fn device(mut self, device_id: &'a str) -> Self {
        self.device_id = Some(device_id);
        self
    }

    pub fn ip(mut self, ip: Option<IpAddr>) -> Self {
        self.ip = ip.map(|ip| ip.to_canonical());
        self
    }

    pub fn detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    /// Writes the entry. A failure is reported in the server log but never stops the action
    /// that is being logged.
    pub async fn write(self, db: &Db) {
        let result = sqlx::query(
            "INSERT INTO security_log (at, event, user_id, device_id, ip, detail) \
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(now_ms())
        .bind(self.event.as_str())
        .bind(self.user_id)
        .bind(self.device_id)
        .bind(self.ip.map(|ip| ip.to_string()))
        .bind(self.detail)
        .execute(db.write())
        .await;
        if let Err(error) = result {
            tracing::error!(%error, event = self.event.as_str(), "could not write the security log");
        }
    }
}

#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
pub struct LogEntry {
    pub id: i64,
    pub at: i64,
    pub event: String,
    pub user_id: Option<String>,
    pub username: Option<String>,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
    pub ip: Option<String>,
    pub detail: Option<String>,
}

/// Newest first. `user_id` limits the list to one account; `before` continues after the last
/// entry of the previous page.
pub async fn list(
    db: &Db,
    user_id: Option<&str>,
    before: Option<i64>,
    limit: u32,
) -> Result<Vec<LogEntry>> {
    let entries = sqlx::query_as::<_, LogEntry>(
        "SELECT l.id, l.at, l.event, l.user_id, u.username, l.device_id, d.name AS device_name, \
                l.ip, l.detail \
         FROM security_log l \
         LEFT JOIN users u ON u.id = l.user_id \
         LEFT JOIN devices d ON d.id = l.device_id \
         WHERE (?1 IS NULL OR l.user_id = ?1) AND (?2 IS NULL OR l.id < ?2) \
         ORDER BY l.id DESC LIMIT ?3",
    )
    .bind(user_id)
    .bind(before)
    .bind(i64::from(limit))
    .fetch_all(db.read())
    .await?;
    Ok(entries)
}

/// Removes entries older than `retention_days` (0 keeps everything). Returns how many went.
pub async fn prune(db: &Db, retention_days: u32, now: i64) -> Result<u64> {
    if retention_days == 0 {
        return Ok(0);
    }
    let cutoff = now - i64::from(retention_days) * 24 * 60 * 60 * 1000;
    let result = sqlx::query("DELETE FROM security_log WHERE at < ?")
        .bind(cutoff)
        .execute(db.write())
        .await?;
    Ok(result.rows_affected())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn entries_are_listed_newest_first_and_pruned() {
        let dir = tempfile::tempdir().unwrap();
        let pool = Db::open(&dir.path().join("halden.db")).await.unwrap();
        for _ in 0..3 {
            Record::new(Event::LoginFailed)
                .user("u1")
                .ip(Some("::ffff:192.168.1.5".parse().unwrap()))
                .write(&pool)
                .await;
        }
        Record::new(Event::Logout).user("u2").write(&pool).await;

        let all = list(&pool, None, None, 10).await.unwrap();
        assert_eq!(all.len(), 4);
        assert_eq!(all[0].event, "logout");
        assert_eq!(all[1].ip.as_deref(), Some("192.168.1.5"));

        let mine = list(&pool, Some("u1"), None, 2).await.unwrap();
        assert_eq!(mine.len(), 2);
        let rest = list(&pool, Some("u1"), Some(mine[1].id), 2).await.unwrap();
        assert_eq!(rest.len(), 1);

        assert_eq!(prune(&pool, 90, now_ms()).await.unwrap(), 0);
        assert_eq!(prune(&pool, 0, now_ms()).await.unwrap(), 0);
        let in_a_year = now_ms() + 365 * 24 * 60 * 60 * 1000;
        assert_eq!(prune(&pool, 90, in_a_year).await.unwrap(), 4);
    }
}
