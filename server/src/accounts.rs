//! Accounts and devices in the database. The HTTP API and the terminal commands both use this,
//! so the rules (like "the last owner stays an owner") hold no matter where a change comes from.

use std::{fmt, net::IpAddr, str::FromStr};

use serde::{Deserialize, Serialize};
use sqlx::{Executor, Sqlite, SqlitePool};
use uuid::Uuid;

use crate::{
    auth::{pairing, token},
    db::now_ms,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// Runs the server: manages accounts and devices. Still can't see other people's photos.
    Owner,
    Member,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Member => "member",
        }
    }
}

impl FromStr for Role {
    type Err = String;
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        match text {
            "owner" => Ok(Self::Owner),
            "member" => Ok(Self::Member),
            _ => Err(format!("{text:?} is not a role (owner or member)")),
        }
    }
}

impl fmt::Display for Role {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Ios,
    Macos,
    Cli,
}

impl Platform {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ios => "ios",
            Self::Macos => "macos",
            Self::Cli => "cli",
        }
    }
}

impl FromStr for Platform {
    type Err = String;
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        match text {
            "ios" => Ok(Self::Ios),
            "macos" => Ok(Self::Macos),
            "cli" => Ok(Self::Cli),
            _ => Err(format!("{text:?} is not a platform (ios, macos or cli)")),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct User {
    pub id: String,
    pub username: String,
    pub display_name: String,
    pub role: Role,
    pub disabled: bool,
    /// False for accounts that can only add devices by pairing.
    pub has_password: bool,
    pub created_at: i64,
}

impl User {
    pub fn is_owner(&self) -> bool {
        self.role == Role::Owner
    }
}

#[derive(sqlx::FromRow)]
struct UserRow {
    id: String,
    username: String,
    display_name: String,
    role: String,
    password_hash: Option<String>,
    disabled: bool,
    created_at: i64,
}

impl UserRow {
    fn split(self) -> (User, Option<String>) {
        let user = User {
            id: self.id,
            username: self.username,
            display_name: self.display_name,
            // The table only allows the two roles; anything else gets the smaller one.
            role: self.role.parse().unwrap_or(Role::Member),
            disabled: self.disabled,
            has_password: self.password_hash.is_some(),
            created_at: self.created_at,
        };
        (user, self.password_hash)
    }
}

/// Column lists are macros so queries stay `&'static str` (sqlx refuses SQL built at runtime).
macro_rules! user_columns {
    () => {
        "id, username, display_name, role, password_hash, disabled, created_at"
    };
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub user_id: String,
    pub name: String,
    pub platform: Platform,
    #[serde(skip)]
    pub installation_id: Option<String>,
    /// False for a device that signed in with the password and nobody has confirmed yet.
    pub confirmed: bool,
    pub created_at: i64,
    pub last_seen_at: i64,
    pub last_seen_ip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<i64>,
}

#[derive(sqlx::FromRow)]
struct DeviceRow {
    id: String,
    user_id: String,
    name: String,
    platform: String,
    installation_id: Option<String>,
    confirmed: bool,
    created_at: i64,
    last_seen_at: i64,
    last_seen_ip: Option<String>,
    revoked_at: Option<i64>,
}

impl From<DeviceRow> for Device {
    fn from(row: DeviceRow) -> Self {
        Self {
            id: row.id,
            user_id: row.user_id,
            name: row.name,
            platform: row.platform.parse().unwrap_or(Platform::Cli),
            installation_id: row.installation_id,
            confirmed: row.confirmed,
            created_at: row.created_at,
            last_seen_at: row.last_seen_at,
            last_seen_ip: row.last_seen_ip,
            revoked_at: row.revoked_at,
        }
    }
}

macro_rules! device_columns {
    () => {
        "d.id, d.user_id, d.name, d.platform, d.installation_id, d.confirmed, d.created_at, \
         d.last_seen_at, d.last_seen_ip, d.revoked_at"
    };
}

#[derive(Debug, thiserror::Error)]
pub enum AccountError {
    /// Input breaks a rule; the text is a sentence for the person.
    #[error("{0}")]
    Invalid(String),
    #[error("the username {0} is already taken")]
    UsernameTaken(String),
    #[error("there is no such account or device")]
    NotFound,
    #[error("the server needs at least one active owner")]
    LastOwner,
    #[error(transparent)]
    Database(#[from] sqlx::Error),
}

// ---------------------------------------------------------------------------------------------
// Rules for names

/// 2 to 32 letters, digits, dots, dashes or underscores, starting with a letter or digit.
/// Case is kept for display, but `Lucas` and `lucas` are the same account.
pub fn check_username(name: &str) -> Result<String, AccountError> {
    let name = name.trim();
    let valid = (2..=32).contains(&name.len())
        && name
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_alphanumeric())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'));
    if valid {
        Ok(name.to_string())
    } else {
        Err(AccountError::Invalid(
            "A username has 2 to 32 letters, digits, dots, dashes or underscores and starts \
             with a letter or digit."
                .into(),
        ))
    }
}

/// Display and device names: 1 to 64 characters, no control characters.
fn check_name(name: &str, what: &str) -> Result<String, AccountError> {
    let name = name.trim();
    let count = name.chars().count();
    if (1..=64).contains(&count) && !name.chars().any(char::is_control) {
        Ok(name.to_string())
    } else {
        Err(AccountError::Invalid(format!(
            "The {what} needs 1 to 64 characters and no control characters."
        )))
    }
}

pub fn check_display_name(name: &str) -> Result<String, AccountError> {
    check_name(name, "name")
}

pub fn check_device_name(name: &str) -> Result<String, AccountError> {
    check_name(name, "device name")
}

pub fn check_installation_id(id: &str) -> Result<String, AccountError> {
    let id = id.trim();
    if (8..=128).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_graphic()) {
        Ok(id.to_string())
    } else {
        Err(AccountError::Invalid(
            "The installation id needs 8 to 128 visible ASCII characters.".into(),
        ))
    }
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    matches!(error, sqlx::Error::Database(db) if db.is_unique_violation())
}

// ---------------------------------------------------------------------------------------------
// Accounts

pub struct NewUser<'a> {
    pub username: &'a str,
    pub display_name: Option<&'a str>,
    pub role: Role,
    /// Already hashed with [`crate::auth::password::hash`]. `None`: pairing only.
    pub password_hash: Option<String>,
}

pub async fn create_user(pool: &SqlitePool, new: NewUser<'_>) -> Result<User, AccountError> {
    let username = check_username(new.username)?;
    let display_name = match new.display_name {
        Some(name) => check_display_name(name)?,
        None => username.clone(),
    };
    let id = Uuid::new_v4().to_string();
    let result = sqlx::query(
        "INSERT INTO users (id, username, display_name, role, password_hash, created_at) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(&id)
    .bind(&username)
    .bind(&display_name)
    .bind(new.role.as_str())
    .bind(&new.password_hash)
    .bind(now_ms())
    .execute(pool)
    .await;
    match result {
        Ok(_) => user_by_id(pool, &id).await?.ok_or(AccountError::NotFound),
        Err(error) if is_unique_violation(&error) => Err(AccountError::UsernameTaken(username)),
        Err(error) => Err(error.into()),
    }
}

pub async fn user_by_id<'e, E>(db: E, id: &str) -> Result<Option<User>, AccountError>
where
    E: Executor<'e, Database = Sqlite>,
{
    let row = sqlx::query_as::<_, UserRow>(concat!(
        "SELECT ",
        user_columns!(),
        " FROM users WHERE id = ?"
    ))
    .bind(id)
    .fetch_optional(db)
    .await?;
    Ok(row.map(|row| row.split().0))
}

/// The account and its password hash, for signing in.
pub async fn user_with_password(
    pool: &SqlitePool,
    username: &str,
) -> Result<Option<(User, Option<String>)>, AccountError> {
    let row = sqlx::query_as::<_, UserRow>(concat!(
        "SELECT ",
        user_columns!(),
        " FROM users WHERE username = ?"
    ))
    .bind(username.trim())
    .fetch_optional(pool)
    .await?;
    Ok(row.map(UserRow::split))
}

pub async fn user_by_name(pool: &SqlitePool, username: &str) -> Result<Option<User>, AccountError> {
    Ok(user_with_password(pool, username)
        .await?
        .map(|(user, _)| user))
}

pub async fn password_hash_of(
    pool: &SqlitePool,
    user_id: &str,
) -> Result<Option<String>, AccountError> {
    let hash: Option<(Option<String>,)> =
        sqlx::query_as("SELECT password_hash FROM users WHERE id = ?")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    Ok(hash.and_then(|(hash,)| hash))
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserSummary {
    #[serde(flatten)]
    pub user: User,
    /// Devices that are signed in.
    pub devices: i64,
}

pub async fn list_users(pool: &SqlitePool) -> Result<Vec<UserSummary>, AccountError> {
    #[derive(sqlx::FromRow)]
    struct Row {
        #[sqlx(flatten)]
        user: UserRow,
        devices: i64,
    }
    let rows = sqlx::query_as::<_, Row>(concat!(
        "SELECT ",
        user_columns!(),
        ", \
             (SELECT count(*) FROM devices d WHERE d.user_id = users.id AND d.revoked_at IS NULL) \
             AS devices \
         FROM users ORDER BY username COLLATE NOCASE"
    ))
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| UserSummary {
            user: row.user.split().0,
            devices: row.devices,
        })
        .collect())
}

pub async fn count_users(pool: &SqlitePool) -> Result<i64, AccountError> {
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM users")
        .fetch_one(pool)
        .await?;
    Ok(count)
}

/// Tells "no such account" apart from "refused to protect the last owner".
async fn not_found_or_last_owner(pool: &SqlitePool, user_id: &str) -> AccountError {
    match user_by_id(pool, user_id).await {
        Ok(Some(_)) => AccountError::LastOwner,
        Ok(None) => AccountError::NotFound,
        Err(error) => error,
    }
}

/// This condition holds unless the change would leave no active owner. The check and the change
/// are one statement, so two changes at the same time can't both slip through.
macro_rules! keeps_an_owner {
    () => {
        "(role <> 'owner' OR disabled = 1 \
         OR (SELECT count(*) FROM users WHERE role = 'owner' AND disabled = 0) > 1)"
    };
}

pub async fn set_role(pool: &SqlitePool, user_id: &str, role: Role) -> Result<(), AccountError> {
    let result = sqlx::query(concat!(
        "UPDATE users SET role = ?2 WHERE id = ?1 AND (?2 = 'owner' OR ",
        keeps_an_owner!(),
        ")"
    ))
    .bind(user_id)
    .bind(role.as_str())
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(not_found_or_last_owner(pool, user_id).await);
    }
    Ok(())
}

pub async fn set_disabled(
    pool: &SqlitePool,
    user_id: &str,
    disabled: bool,
) -> Result<(), AccountError> {
    let result = sqlx::query(concat!(
        "UPDATE users SET disabled = ?2 WHERE id = ?1 AND (?2 = 0 OR ",
        keeps_an_owner!(),
        ")"
    ))
    .bind(user_id)
    .bind(disabled)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(not_found_or_last_owner(pool, user_id).await);
    }
    Ok(())
}

pub async fn delete_user(pool: &SqlitePool, user_id: &str) -> Result<(), AccountError> {
    let result = sqlx::query(concat!(
        "DELETE FROM users WHERE id = ?1 AND ",
        keeps_an_owner!()
    ))
    .bind(user_id)
    .execute(pool)
    .await?;
    if result.rows_affected() == 0 {
        return Err(not_found_or_last_owner(pool, user_id).await);
    }
    Ok(())
}

pub async fn set_display_name(
    pool: &SqlitePool,
    user_id: &str,
    name: &str,
) -> Result<(), AccountError> {
    let name = check_display_name(name)?;
    let result = sqlx::query("UPDATE users SET display_name = ? WHERE id = ?")
        .bind(name)
        .bind(user_id)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(AccountError::NotFound);
    }
    Ok(())
}

/// Stores a new password hash (see [`crate::auth::password::hash`]).
pub async fn set_password_hash(
    pool: &SqlitePool,
    user_id: &str,
    hash: &str,
) -> Result<(), AccountError> {
    let result = sqlx::query("UPDATE users SET password_hash = ? WHERE id = ?")
        .bind(hash)
        .bind(user_id)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(AccountError::NotFound);
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Devices

pub struct NewDevice<'a> {
    pub user_id: &'a str,
    pub name: &'a str,
    pub platform: Platform,
    pub installation_id: Option<&'a str>,
    pub confirmed: bool,
    pub ip: Option<IpAddr>,
}

/// Adds a signed-in device and returns it with its token. The token is shown only now.
pub async fn add_device<'e, E>(db: E, new: NewDevice<'_>) -> Result<(Device, String), AccountError>
where
    E: Executor<'e, Database = Sqlite>,
{
    let name = check_device_name(new.name)?;
    let installation_id = new.installation_id.map(check_installation_id).transpose()?;
    let token = token::generate();
    let now = now_ms();
    let device = Device {
        id: Uuid::new_v4().to_string(),
        user_id: new.user_id.to_string(),
        name,
        platform: new.platform,
        installation_id,
        confirmed: new.confirmed,
        created_at: now,
        last_seen_at: now,
        last_seen_ip: new.ip.map(|ip| ip.to_canonical().to_string()),
        revoked_at: None,
    };
    sqlx::query(
        "INSERT INTO devices (id, user_id, name, platform, token_hash, installation_id, \
             confirmed, created_at, last_seen_at, last_seen_ip) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(&device.id)
    .bind(&device.user_id)
    .bind(&device.name)
    .bind(device.platform.as_str())
    .bind(token.hash.as_slice())
    .bind(&device.installation_id)
    .bind(device.confirmed)
    .bind(device.created_at)
    .bind(device.last_seen_at)
    .bind(&device.last_seen_ip)
    .execute(db)
    .await?;
    Ok((device, token.token))
}

/// Does the account have any signed-in device? A first device has nobody to confirm it.
pub async fn has_active_devices<'e, E>(db: E, user_id: &str) -> Result<bool, AccountError>
where
    E: Executor<'e, Database = Sqlite>,
{
    let (count,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM devices WHERE user_id = ? AND revoked_at IS NULL")
            .bind(user_id)
            .fetch_one(db)
            .await?;
    Ok(count > 0)
}

/// The device a token belongs to, revoked or not, and its account.
pub async fn device_for_token(
    pool: &SqlitePool,
    token: &str,
) -> Result<Option<(Device, User)>, AccountError> {
    let hash = token::hash(token);
    let Some(row) = sqlx::query_as::<_, DeviceRow>(concat!(
        "SELECT ",
        device_columns!(),
        " FROM devices d WHERE d.token_hash = ?"
    ))
    .bind(hash.as_slice())
    .fetch_optional(pool)
    .await?
    else {
        return Ok(None);
    };
    let device = Device::from(row);
    Ok(user_by_id(pool, &device.user_id)
        .await?
        .map(|user| (device, user)))
}

pub async fn touch_device(
    pool: &SqlitePool,
    device_id: &str,
    now: i64,
    ip: Option<IpAddr>,
) -> Result<(), AccountError> {
    sqlx::query("UPDATE devices SET last_seen_at = ?, last_seen_ip = ? WHERE id = ?")
        .bind(now)
        .bind(ip.map(|ip| ip.to_canonical().to_string()))
        .bind(device_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn device_by_id(pool: &SqlitePool, id: &str) -> Result<Option<Device>, AccountError> {
    let row = sqlx::query_as::<_, DeviceRow>(concat!(
        "SELECT ",
        device_columns!(),
        " FROM devices d WHERE d.id = ?"
    ))
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(Device::from))
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceListing {
    #[serde(flatten)]
    pub device: Device,
    pub username: String,
}

/// Signed-in devices, of one account or of all, newest first.
pub async fn list_devices(
    pool: &SqlitePool,
    user_id: Option<&str>,
) -> Result<Vec<DeviceListing>, AccountError> {
    #[derive(sqlx::FromRow)]
    struct Row {
        #[sqlx(flatten)]
        device: DeviceRow,
        username: String,
    }
    let rows = sqlx::query_as::<_, Row>(concat!(
        "SELECT ",
        device_columns!(),
        ", u.username FROM devices d JOIN users u ON u.id = d.user_id \
         WHERE d.revoked_at IS NULL AND (?1 IS NULL OR d.user_id = ?1) \
         ORDER BY d.created_at DESC"
    ))
    .bind(user_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| DeviceListing {
            device: row.device.into(),
            username: row.username,
        })
        .collect())
}

/// Signed-in devices whose id starts with `prefix` (the terminal shows shortened ids).
pub async fn find_devices_by_prefix(
    pool: &SqlitePool,
    prefix: &str,
) -> Result<Vec<Device>, AccountError> {
    let prefix = prefix.trim().to_ascii_lowercase();
    if prefix.is_empty() || !prefix.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Ok(Vec::new());
    }
    let rows = sqlx::query_as::<_, DeviceRow>(concat!(
        "SELECT ",
        device_columns!(),
        " FROM devices d \
         WHERE d.revoked_at IS NULL AND substr(d.id, 1, length(?1)) = ?1"
    ))
    .bind(prefix)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(Device::from).collect())
}

/// "That was me": the device is no longer shown as new.
pub async fn confirm_device(pool: &SqlitePool, device_id: &str) -> Result<(), AccountError> {
    let result =
        sqlx::query("UPDATE devices SET confirmed = 1 WHERE id = ? AND revoked_at IS NULL")
            .bind(device_id)
            .execute(pool)
            .await?;
    if result.rows_affected() == 0 {
        return Err(AccountError::NotFound);
    }
    Ok(())
}

/// Signs a device out: its token stops working at once.
pub async fn revoke_device(pool: &SqlitePool, device_id: &str) -> Result<(), AccountError> {
    let result =
        sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
            .bind(now_ms())
            .bind(device_id)
            .execute(pool)
            .await?;
    if result.rows_affected() == 0 {
        return Err(AccountError::NotFound);
    }
    Ok(())
}

/// Signs a device out and refuses its installation from now on, for sign-in and pairing.
pub async fn block_device(pool: &SqlitePool, device: &Device) -> Result<(), AccountError> {
    let mut tx = pool.begin().await?;
    let now = now_ms();
    sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
        .bind(now)
        .bind(&device.id)
        .execute(&mut *tx)
        .await?;
    if let Some(installation) = &device.installation_id {
        sqlx::query(
            "INSERT INTO blocked_installations (installation_id, user_id, blocked_at) \
             VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
        )
        .bind(installation)
        .bind(&device.user_id)
        .bind(now)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(())
}

/// Signs out every device of the account except `keep`. Returns how many.
pub async fn revoke_other_devices(
    pool: &SqlitePool,
    user_id: &str,
    keep: Option<&str>,
) -> Result<u64, AccountError> {
    let result = sqlx::query(
        "UPDATE devices SET revoked_at = ?1 \
         WHERE user_id = ?2 AND revoked_at IS NULL AND (?3 IS NULL OR id <> ?3)",
    )
    .bind(now_ms())
    .bind(user_id)
    .bind(keep)
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

pub async fn is_blocked<'e, E>(
    db: E,
    user_id: &str,
    installation_id: Option<&str>,
) -> Result<bool, AccountError>
where
    E: Executor<'e, Database = Sqlite>,
{
    let Some(installation_id) = installation_id else {
        return Ok(false);
    };
    let found: Option<(i64,)> = sqlx::query_as(
        "SELECT 1 FROM blocked_installations WHERE installation_id = ? AND user_id = ?",
    )
    .bind(installation_id.trim())
    .bind(user_id)
    .fetch_optional(db)
    .await?;
    Ok(found.is_some())
}

/// New devices nobody confirmed yet, other than `except`: of one account, or of all.
pub async fn unconfirmed_count(
    pool: &SqlitePool,
    user_id: Option<&str>,
    except: &str,
) -> Result<i64, AccountError> {
    let (count,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM devices \
         WHERE confirmed = 0 AND revoked_at IS NULL AND id <> ?1 \
           AND (?2 IS NULL OR user_id = ?2)",
    )
    .bind(except)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    Ok(count)
}

// ---------------------------------------------------------------------------------------------
// Pairing

pub struct PairingCode {
    /// Normalised (no dash).
    pub code: String,
    pub expires_at: i64,
}

/// A new one-time code for adding a device to `user_id`. `created_by` is the device that asked
/// for it, `None` for the terminal.
pub async fn create_pairing_code(
    pool: &SqlitePool,
    user_id: &str,
    created_by: Option<&str>,
) -> Result<PairingCode, AccountError> {
    let now = now_ms();
    let code = pairing::generate_code();
    let expires_at = now + pairing::CODE_TTL_MS;
    sqlx::query(
        "INSERT INTO pairing_codes (code_hash, user_id, created_by_device, created_at, expires_at) \
         VALUES (?, ?, ?, ?, ?)",
    )
    .bind(pairing::hash(&code).as_slice())
    .bind(user_id)
    .bind(created_by)
    .bind(now)
    .bind(expires_at)
    .execute(pool)
    .await?;
    Ok(PairingCode { code, expires_at })
}

pub enum PairOutcome {
    Paired {
        user: User,
        device: Device,
        token: String,
    },
    /// Wrong, expired or already used.
    InvalidCode,
    AccountDisabled(User),
    Blocked(User),
}

pub struct PairRequest<'a> {
    /// Normalised code.
    pub code: &'a str,
    pub device_name: &'a str,
    pub platform: Platform,
    pub installation_id: Option<&'a str>,
    pub ip: Option<IpAddr>,
}

/// Uses a pairing code to add a device. A code works only once, even if two devices try it at
/// the same moment: claiming it is the first write, so the second attempt waits and then finds it
/// used.
pub async fn pair_device(
    pool: &SqlitePool,
    request: PairRequest<'_>,
) -> Result<PairOutcome, AccountError> {
    // Check the names before the code is spent on a request that can't succeed.
    check_device_name(request.device_name)?;
    if let Some(id) = request.installation_id {
        check_installation_id(id)?;
    }
    let code_hash = pairing::hash(request.code);
    let now = now_ms();
    let mut tx = pool.begin().await?;
    let claimed: Option<(String, Option<String>)> = sqlx::query_as(
        "UPDATE pairing_codes SET used_at = ?1 \
         WHERE code_hash = ?2 AND used_at IS NULL AND expires_at > ?1 \
         RETURNING user_id, created_by_device",
    )
    .bind(now)
    .bind(code_hash.as_slice())
    .fetch_optional(&mut *tx)
    .await?;
    let Some((user_id, created_by)) = claimed else {
        return Ok(PairOutcome::InvalidCode);
    };
    let Some(user) = user_by_id(&mut *tx, &user_id).await? else {
        return Ok(PairOutcome::InvalidCode);
    };
    // Returning early drops the transaction, which leaves the code unused.
    if user.disabled {
        return Ok(PairOutcome::AccountDisabled(user));
    }
    if is_blocked(&mut *tx, &user.id, request.installation_id).await? {
        return Ok(PairOutcome::Blocked(user));
    }

    // A code the account made itself (or the server's terminal) vouches for the device. A code
    // an owner made for someone else's account does not, so that account sees the new device.
    let creator_account: Option<(String,)> = match &created_by {
        Some(device_id) => {
            sqlx::query_as("SELECT user_id FROM devices WHERE id = ?")
                .bind(device_id)
                .fetch_optional(&mut *tx)
                .await?
        }
        None => None,
    };
    let vouched = match (&created_by, creator_account) {
        (None, _) => true,
        (Some(_), Some((account,))) => account == user.id,
        (Some(_), None) => false,
    };
    let confirmed = vouched || !has_active_devices(&mut *tx, &user.id).await?;

    let (device, token) = add_device(
        &mut *tx,
        NewDevice {
            user_id: &user.id,
            name: request.device_name,
            platform: request.platform,
            installation_id: request.installation_id,
            confirmed,
            ip: request.ip,
        },
    )
    .await?;
    sqlx::query("UPDATE pairing_codes SET used_by_device = ? WHERE code_hash = ?")
        .bind(&device.id)
        .bind(code_hash.as_slice())
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(PairOutcome::Paired {
        user,
        device,
        token,
    })
}

/// The device a code added, once it was used. For `halden pair`, which waits for it.
pub async fn paired_device_for_code(
    pool: &SqlitePool,
    code: &str,
) -> Result<Option<Device>, AccountError> {
    let row = sqlx::query_as::<_, DeviceRow>(concat!(
        "SELECT ",
        device_columns!(),
        " FROM pairing_codes p JOIN devices d ON d.id = p.used_by_device \
         WHERE p.code_hash = ?"
    ))
    .bind(pairing::hash(code).as_slice())
    .fetch_optional(pool)
    .await?;
    Ok(row.map(Device::from))
}

/// Cancels one code if nobody used it yet (`halden pair` stopped with Ctrl-C).
pub async fn cancel_code(pool: &SqlitePool, code: &str) -> Result<(), AccountError> {
    sqlx::query("UPDATE pairing_codes SET expires_at = ? WHERE code_hash = ? AND used_at IS NULL")
        .bind(now_ms())
        .bind(pairing::hash(code).as_slice())
        .execute(pool)
        .await?;
    Ok(())
}

/// Cancels every code that is still open. Returns how many.
pub async fn cancel_open_codes(pool: &SqlitePool) -> Result<u64, AccountError> {
    let now = now_ms();
    let result = sqlx::query(
        "UPDATE pairing_codes SET expires_at = ?1 WHERE used_at IS NULL AND expires_at > ?1",
    )
    .bind(now)
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

// ---------------------------------------------------------------------------------------------
// Tidying up

/// What [`tidy`] did.
#[derive(Debug, Default)]
pub struct Tidied {
    /// (device id, account id) of devices signed out for being unused too long.
    pub expired_devices: Vec<(String, String)>,
}

/// Signs out devices unused for `inactive_days` (0: never), removes old pairing codes and
/// devices that were signed out longer ago than the security log keeps entries.
pub async fn tidy(
    pool: &SqlitePool,
    inactive_days: u32,
    log_retention_days: u32,
    now: i64,
) -> Result<Tidied, AccountError> {
    const DAY_MS: i64 = 24 * 60 * 60 * 1000;
    let mut tidied = Tidied::default();
    if inactive_days > 0 {
        tidied.expired_devices = sqlx::query_as(
            "UPDATE devices SET revoked_at = ?1 \
             WHERE revoked_at IS NULL AND last_seen_at < ?2 RETURNING id, user_id",
        )
        .bind(now)
        .bind(now - i64::from(inactive_days) * DAY_MS)
        .fetch_all(pool)
        .await?;
    }
    sqlx::query("DELETE FROM pairing_codes WHERE expires_at < ?")
        .bind(now - DAY_MS)
        .execute(pool)
        .await?;
    if log_retention_days > 0 {
        sqlx::query("DELETE FROM devices WHERE revoked_at < ?")
            .bind(now - i64::from(log_retention_days) * DAY_MS)
            .execute(pool)
            .await?;
    }
    Ok(tidied)
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn pool() -> (tempfile::TempDir, SqlitePool) {
        let dir = tempfile::tempdir().unwrap();
        let pool = crate::db::open(&dir.path().join("halden.db"))
            .await
            .unwrap();
        (dir, pool)
    }

    async fn user(pool: &SqlitePool, name: &str, role: Role) -> User {
        create_user(
            pool,
            NewUser {
                username: name,
                display_name: None,
                role,
                password_hash: None,
            },
        )
        .await
        .unwrap()
    }

    fn device<'a>(user: &'a User, installation: Option<&'a str>) -> NewDevice<'a> {
        NewDevice {
            user_id: &user.id,
            name: "Test iPhone",
            platform: Platform::Ios,
            installation_id: installation,
            confirmed: false,
            ip: None,
        }
    }

    #[test]
    fn username_rules() {
        assert_eq!(check_username(" Lucas ").unwrap(), "Lucas");
        assert!(check_username("anna.k-2_b").is_ok());
        for bad in ["a", "-anna", "anna k", "änna", &"a".repeat(33)] {
            assert!(check_username(bad).is_err(), "{bad} should be refused");
        }
        assert!(check_device_name("Lucas' iPhone").is_ok());
        assert!(check_device_name("bad\nname").is_err());
        assert!(check_device_name("  ").is_err());
    }

    #[tokio::test]
    async fn usernames_are_unique_without_case() {
        let (_dir, pool) = pool().await;
        let lucas = user(&pool, "Lucas", Role::Owner).await;
        assert_eq!(lucas.display_name, "Lucas");
        assert!(matches!(
            create_user(
                &pool,
                NewUser {
                    username: "lucas",
                    display_name: None,
                    role: Role::Member,
                    password_hash: None,
                }
            )
            .await,
            Err(AccountError::UsernameTaken(_))
        ));
        assert_eq!(
            user_by_name(&pool, "LUCAS").await.unwrap().unwrap().id,
            lucas.id
        );
    }

    #[tokio::test]
    async fn the_last_owner_stays() {
        let (_dir, pool) = pool().await;
        let lucas = user(&pool, "lucas", Role::Owner).await;
        let anna = user(&pool, "anna", Role::Member).await;

        assert!(matches!(
            set_role(&pool, &lucas.id, Role::Member).await,
            Err(AccountError::LastOwner)
        ));
        assert!(matches!(
            set_disabled(&pool, &lucas.id, true).await,
            Err(AccountError::LastOwner)
        ));
        assert!(matches!(
            delete_user(&pool, &lucas.id).await,
            Err(AccountError::LastOwner)
        ));
        assert!(matches!(
            delete_user(&pool, "nobody").await,
            Err(AccountError::NotFound)
        ));

        set_role(&pool, &anna.id, Role::Owner).await.unwrap();
        set_role(&pool, &lucas.id, Role::Member).await.unwrap();
        delete_user(&pool, &lucas.id).await.unwrap();
        assert_eq!(count_users(&pool).await.unwrap(), 1);
    }

    #[tokio::test]
    async fn devices_are_found_by_token_and_revoked() {
        let (_dir, pool) = pool().await;
        let lucas = user(&pool, "lucas", Role::Owner).await;
        let (phone, token) = add_device(&pool, device(&lucas, Some("install-0001")))
            .await
            .unwrap();
        let (found, owner) = device_for_token(&pool, &token).await.unwrap().unwrap();
        assert_eq!(found.id, phone.id);
        assert_eq!(owner.id, lucas.id);
        assert!(device_for_token(&pool, "hd1_nope").await.unwrap().is_none());

        let (mac, _) = add_device(&pool, device(&lucas, None)).await.unwrap();
        assert_eq!(
            unconfirmed_count(&pool, Some(&lucas.id), &phone.id)
                .await
                .unwrap(),
            1
        );
        confirm_device(&pool, &mac.id).await.unwrap();
        assert_eq!(unconfirmed_count(&pool, None, &phone.id).await.unwrap(), 0);

        block_device(&pool, &phone).await.unwrap();
        let (found, _) = device_for_token(&pool, &token).await.unwrap().unwrap();
        assert!(found.revoked_at.is_some());
        assert!(
            is_blocked(&pool, &lucas.id, Some("install-0001"))
                .await
                .unwrap()
        );
        assert!(
            !is_blocked(&pool, &lucas.id, Some("install-0002"))
                .await
                .unwrap()
        );
        assert!(!is_blocked(&pool, &lucas.id, None).await.unwrap());

        assert_eq!(list_devices(&pool, Some(&lucas.id)).await.unwrap().len(), 1);
        assert_eq!(
            find_devices_by_prefix(&pool, &mac.id[..8])
                .await
                .unwrap()
                .len(),
            1
        );
        assert!(find_devices_by_prefix(&pool, "%").await.unwrap().is_empty());
        assert_eq!(
            revoke_other_devices(&pool, &lucas.id, None).await.unwrap(),
            1
        );
        assert!(!has_active_devices(&pool, &lucas.id).await.unwrap());

        // Deleting the account removes its devices.
        let anna = user(&pool, "anna", Role::Owner).await;
        delete_user(&pool, &lucas.id).await.unwrap();
        assert!(device_by_id(&pool, &mac.id).await.unwrap().is_none());
        assert!(
            list_devices(&pool, Some(&anna.id))
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn pairing_codes_work_once_and_expire() {
        let (_dir, pool) = pool().await;
        let lucas = user(&pool, "lucas", Role::Owner).await;
        fn request(code: &str) -> PairRequest<'_> {
            PairRequest {
                code,
                device_name: "Lucas' iPhone",
                platform: Platform::Ios,
                installation_id: None,
                ip: None,
            }
        }

        let first = create_pairing_code(&pool, &lucas.id, None).await.unwrap();
        let code = first.code.as_str();
        let PairOutcome::Paired { device, .. } = pair_device(&pool, request(code)).await.unwrap()
        else {
            panic!("the first use must work");
        };
        assert!(device.confirmed);
        assert_eq!(
            paired_device_for_code(&pool, code)
                .await
                .unwrap()
                .unwrap()
                .id,
            device.id
        );
        assert!(matches!(
            pair_device(&pool, request(code)).await.unwrap(),
            PairOutcome::InvalidCode
        ));

        let second = create_pairing_code(&pool, &lucas.id, None).await.unwrap();
        sqlx::query("UPDATE pairing_codes SET expires_at = 0 WHERE code_hash = ?")
            .bind(pairing::hash(&second.code).as_slice())
            .execute(&pool)
            .await
            .unwrap();
        let code = second.code.as_str();
        assert!(matches!(
            pair_device(&pool, request(code)).await.unwrap(),
            PairOutcome::InvalidCode
        ));

        let third = create_pairing_code(&pool, &lucas.id, None).await.unwrap();
        assert_eq!(cancel_open_codes(&pool).await.unwrap(), 1);
        let code = third.code.as_str();
        assert!(matches!(
            pair_device(&pool, request(code)).await.unwrap(),
            PairOutcome::InvalidCode
        ));
    }

    #[tokio::test]
    async fn unused_devices_expire() {
        let (_dir, pool) = pool().await;
        let lucas = user(&pool, "lucas", Role::Owner).await;
        let (phone, _) = add_device(&pool, device(&lucas, None)).await.unwrap();
        let tidied = tidy(&pool, 365, 90, now_ms()).await.unwrap();
        assert!(tidied.expired_devices.is_empty());
        let in_two_years = now_ms() + 2 * 365 * 24 * 60 * 60 * 1000;
        let tidied = tidy(&pool, 365, 90, in_two_years).await.unwrap();
        assert_eq!(
            tidied.expired_devices,
            vec![(phone.id.clone(), lucas.id.clone())]
        );
        assert!(
            tidy(&pool, 0, 0, in_two_years)
                .await
                .unwrap()
                .expired_devices
                .is_empty()
        );
    }
}
