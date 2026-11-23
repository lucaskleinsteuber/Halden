//! Signing in and out, the own account, and pairing codes.

use std::time::Instant;

use axum::{Json, extract::State, http::StatusCode};
use serde::{Deserialize, Serialize};

use super::{ApiError, ApiJson, AppState, Auth, ClientIp};
use crate::{
    accounts::{self, Device, NewDevice, PairOutcome, PairRequest, Platform, User},
    auth::{pairing, password},
    net,
    seclog::{Event, Record},
};

/// What a device says about itself when it signs in or pairs.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceInfo {
    /// "Lucas' iPhone"
    name: String,
    platform: Platform,
    /// A random id the app creates once per installation. Lets an owner block the device for
    /// good instead of only signing it out.
    installation_id: Option<String>,
}

impl DeviceInfo {
    fn check(&self) -> Result<(), ApiError> {
        accounts::check_device_name(&self.name)?;
        if let Some(id) = &self.installation_id {
            accounts::check_installation_id(id)?;
        }
        Ok(())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedIn {
    /// Send as `Authorization: Bearer <token>`. Shown only this once.
    token: String,
    user: User,
    device: Device,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LoginRequest {
    username: String,
    password: String,
    device: DeviceInfo,
}

pub async fn login(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    ApiJson(request): ApiJson<LoginRequest>,
) -> Result<Json<SignedIn>, ApiError> {
    if !state.auth().password_login {
        return Err(ApiError::password_login_disabled());
    }
    let now = Instant::now();
    if let Some(ip) = ip {
        state
            .limiter()
            .attempt_from(ip, now)
            .map_err(ApiError::rate_limited)?;
    }
    request.device.check()?;
    let db = state.db();

    let found = accounts::user_with_password(db, &request.username).await?;
    if let Err(wait) = state.limiter().check_user(&request.username, now) {
        let mut record = Record::new(Event::LoginThrottled).ip(ip);
        if let Some((user, _)) = &found {
            record = record.user(&user.id);
        }
        record.write(db).await;
        return Err(ApiError::rate_limited(wait));
    }
    let (user, hash) = match found {
        Some((user, hash)) => (Some(user), hash),
        None => (None, None),
    };
    let correct = password::verify(request.password, hash).await;
    let user = match user {
        Some(user) if correct => user,
        user => {
            state.limiter().user_failed(&request.username, now);
            let mut record = Record::new(Event::LoginFailed).ip(ip);
            if let Some(user) = &user {
                record = record.user(&user.id);
            }
            record.write(db).await;
            return Err(ApiError::invalid_credentials());
        }
    };
    state.limiter().user_succeeded(&request.username);

    if user.disabled {
        return Err(ApiError::forbidden("This account is disabled."));
    }
    let installation_id = request.device.installation_id.as_deref();
    if accounts::is_blocked(db.read(), &user.id, installation_id).await? {
        Record::new(Event::BlockedDeviceRefused)
            .user(&user.id)
            .ip(ip)
            .detail(format!("sign-in from {}", request.device.name.trim()))
            .write(db)
            .await;
        return Err(ApiError::device_blocked());
    }

    // A first device has nobody to confirm it; any later one shows up as new on the others.
    let confirmed = !accounts::has_active_devices(db.read(), &user.id).await?;
    let (device, token) = accounts::add_device(
        db.write(),
        NewDevice {
            user_id: &user.id,
            name: &request.device.name,
            platform: request.device.platform,
            installation_id,
            confirmed,
            ip,
        },
    )
    .await?;
    Record::new(Event::LoginSucceeded)
        .user(&user.id)
        .device(&device.id)
        .ip(ip)
        .detail(if confirmed {
            "first device"
        } else {
            "new device, waiting for confirmation"
        })
        .write(db)
        .await;
    Ok(Json(SignedIn {
        token,
        user,
        device,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairBody {
    code: String,
    device: DeviceInfo,
}

pub async fn pair(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    ApiJson(request): ApiJson<PairBody>,
) -> Result<Json<SignedIn>, ApiError> {
    if let Some(ip) = ip {
        state
            .limiter()
            .attempt_from(ip, Instant::now())
            .map_err(ApiError::rate_limited)?;
    }
    request.device.check()?;
    let Some(code) = pairing::normalize(&request.code) else {
        return Err(pairing_failed(&state, ip).await);
    };
    let db = state.db();
    let outcome = accounts::pair_device(
        db,
        PairRequest {
            code: &code,
            device_name: &request.device.name,
            platform: request.device.platform,
            installation_id: request.device.installation_id.as_deref(),
            ip,
        },
    )
    .await?;
    match outcome {
        PairOutcome::Paired {
            user,
            device,
            token,
        } => {
            Record::new(Event::PairSucceeded)
                .user(&user.id)
                .device(&device.id)
                .ip(ip)
                .detail(if device.confirmed {
                    "paired"
                } else {
                    "paired with a code from another account, waiting for confirmation"
                })
                .write(db)
                .await;
            Ok(Json(SignedIn {
                token,
                user,
                device,
            }))
        }
        PairOutcome::InvalidCode => Err(pairing_failed(&state, ip).await),
        PairOutcome::AccountDisabled(_) => Err(ApiError::forbidden("This account is disabled.")),
        PairOutcome::Blocked(user) => {
            Record::new(Event::BlockedDeviceRefused)
                .user(&user.id)
                .ip(ip)
                .detail(format!("pairing from {}", request.device.name.trim()))
                .write(db)
                .await;
            Err(ApiError::device_blocked())
        }
    }
}

async fn pairing_failed(state: &AppState, ip: Option<std::net::IpAddr>) -> ApiError {
    let db = state.db();
    Record::new(Event::PairFailed).ip(ip).write(db).await;
    if state.limiter().pairing_failed() {
        match accounts::cancel_open_codes(db).await {
            Ok(cancelled) => {
                Record::new(Event::PairingCodesCancelled)
                    .detail(format!(
                        "{cancelled} open codes cancelled after {} wrong codes",
                        pairing::MAX_FAILURES
                    ))
                    .write(db)
                    .await;
            }
            Err(error) => tracing::error!(%error, "could not cancel the open pairing codes"),
        }
    }
    ApiError::invalid_code()
}

pub async fn logout(State(state): State<AppState>, auth: Auth) -> Result<StatusCode, ApiError> {
    let db = state.db();
    accounts::revoke_device(db, &auth.device.id).await?;
    Record::new(Event::Logout)
        .user(&auth.user.id)
        .device(&auth.device.id)
        .ip(auth.ip)
        .write(db)
        .await;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Me {
    user: User,
    device: Device,
    /// New devices waiting for "That was me" or "Block": the account's own, and for owners
    /// those of every account.
    unconfirmed_devices: i64,
    /// Whether the photos exist a second time. Apps warn while `onlyOneCopy` is true.
    backup: crate::backup::mirror::BackupStatus,
}

pub async fn me(State(state): State<AppState>, auth: Auth) -> Result<Json<Me>, ApiError> {
    let scope = (!auth.user.is_owner()).then_some(auth.user.id.as_str());
    let unconfirmed_devices =
        accounts::unconfirmed_count(state.db(), scope, &auth.device.id).await?;
    Ok(Json(Me {
        user: auth.user,
        device: auth.device,
        unconfirmed_devices,
        backup: state.backup_status(),
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChangePassword {
    /// Needed when the account has a password already.
    current_password: Option<String>,
    new_password: String,
    /// Sign out every other device of this account, e.g. after a lost phone.
    #[serde(default)]
    sign_out_other_devices: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PasswordChanged {
    signed_out_devices: u64,
}

pub async fn change_password(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<ChangePassword>,
) -> Result<Json<PasswordChanged>, ApiError> {
    if auth.user.has_password {
        auth.confirm_password(&state, request.current_password)
            .await?;
    }
    password::check_new(&request.new_password, &auth.user.username)
        .map_err(ApiError::validation)?;
    let hash = password::hash(request.new_password).await?;
    let db = state.db();
    accounts::set_password_hash(db, &auth.user.id, &hash).await?;
    let signed_out_devices = if request.sign_out_other_devices {
        accounts::revoke_other_devices(db, &auth.user.id, Some(&auth.device.id)).await?
    } else {
        0
    };
    Record::new(Event::PasswordChanged)
        .user(&auth.user.id)
        .device(&auth.device.id)
        .ip(auth.ip)
        .detail(format!("{signed_out_devices} other devices signed out"))
        .write(db)
        .await;
    Ok(Json(PasswordChanged { signed_out_devices }))
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NewPairingCode {
    /// Another account (owners only). Leave out for the own account.
    user_id: Option<String>,
    /// Needed for another account: it gives that account's photos to the new device.
    current_password: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingCodeCreated {
    /// `ABCDE-FGHJK`, for typing.
    code: String,
    /// `halden://pair?…`, for the QR code.
    url: String,
    expires_at: i64,
    user_id: String,
}

pub async fn create_pairing_code(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<NewPairingCode>,
) -> Result<(StatusCode, Json<PairingCodeCreated>), ApiError> {
    let db = state.db();
    let target = match request.user_id {
        Some(id) if id != auth.user.id => {
            auth.require_owner()?;
            auth.confirm_password(&state, request.current_password)
                .await?;
            accounts::user_by_id(db.read(), &id)
                .await?
                .ok_or_else(ApiError::not_found)?
        }
        _ => auth.user.clone(),
    };
    if target.disabled {
        return Err(ApiError::conflict("This account is disabled."));
    }
    let created = accounts::create_pairing_code(db, &target.id, Some(&auth.device.id)).await?;
    let mut record = Record::new(Event::PairingCodeCreated)
        .user(&target.id)
        .device(&auth.device.id)
        .ip(auth.ip);
    if target.id != auth.user.id {
        record = record.detail(format!("by {}", auth.user.username));
    }
    record.write(db).await;

    let addresses = net::local_addresses();
    let fingerprint = state.0.fingerprint.hex();
    let url = pairing::Invite {
        server_id: state.0.server_id,
        server_name: &state.0.name,
        addresses: &addresses,
        port: state.0.port,
        fingerprint: &fingerprint,
        code: &created.code,
    }
    .url();
    Ok((
        StatusCode::CREATED,
        Json(PairingCodeCreated {
            code: pairing::display(&created.code),
            url,
            expires_at: created.expires_at,
            user_id: target.id,
        }),
    ))
}
