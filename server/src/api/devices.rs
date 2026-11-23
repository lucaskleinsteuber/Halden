//! Signed-in devices ("That was me", block, sign out) and the security log.

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use super::{ApiError, ApiQuery, AppState, Auth};
use crate::{
    accounts::{self, Device, DeviceListing},
    seclog::{self, Event, LogEntry, Record},
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceView {
    #[serde(flatten)]
    listing: DeviceListing,
    /// The device asking.
    current: bool,
}

#[derive(Serialize)]
pub struct DeviceList {
    devices: Vec<DeviceView>,
}

/// The own devices; owners see the devices of every account.
pub async fn list(State(state): State<AppState>, auth: Auth) -> Result<Json<DeviceList>, ApiError> {
    let scope = (!auth.user.is_owner()).then_some(auth.user.id.as_str());
    let devices = accounts::list_devices(state.db(), scope)
        .await?
        .into_iter()
        .map(|listing| DeviceView {
            current: listing.device.id == auth.device.id,
            listing,
        })
        .collect();
    Ok(Json(DeviceList { devices }))
}

/// A signed-in device the asker may manage: one of their own, or any for an owner. Others
/// look like they don't exist.
async fn manageable(state: &AppState, auth: &Auth, id: &str) -> Result<Device, ApiError> {
    match accounts::device_by_id(state.db(), id).await? {
        Some(device)
            if device.revoked_at.is_none()
                && (device.user_id == auth.user.id || auth.user.is_owner()) =>
        {
            Ok(device)
        }
        _ => Err(ApiError::not_found()),
    }
}

fn record<'a>(event: Event, device: &'a Device, auth: &'a Auth) -> Record<'a> {
    let record = Record::new(event)
        .user(&device.user_id)
        .device(&device.id)
        .ip(auth.ip);
    if device.user_id == auth.user.id {
        record
    } else {
        record.detail(format!("by {}", auth.user.username))
    }
}

/// "That was me."
pub async fn confirm(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let device = manageable(&state, &auth, &id).await?;
    if device.id == auth.device.id && !device.confirmed {
        return Err(ApiError::forbidden(
            "A new device can't vouch for itself. Confirm it on another device.",
        ));
    }
    accounts::confirm_device(state.db(), &device.id).await?;
    record(Event::DeviceConfirmed, &device, &auth)
        .write(state.db())
        .await;
    Ok(StatusCode::NO_CONTENT)
}

/// Sign the device out and refuse its installation from now on.
pub async fn block(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let device = manageable(&state, &auth, &id).await?;
    accounts::block_device(state.db(), &device).await?;
    record(Event::DeviceBlocked, &device, &auth)
        .write(state.db())
        .await;
    Ok(StatusCode::NO_CONTENT)
}

/// Sign the device out. It can sign in again.
pub async fn revoke(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let device = manageable(&state, &auth, &id).await?;
    accounts::revoke_device(state.db(), &device.id).await?;
    record(Event::DeviceRevoked, &device, &auth)
        .write(state.db())
        .await;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LogQuery {
    /// Continue after this entry id (`nextBefore` of the previous page).
    before: Option<i64>,
    /// Entries per page, 1 to 200 [default: 50].
    limit: Option<u32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogPage {
    entries: Vec<LogEntry>,
    /// Pass as `before` for the next page; missing on the last page.
    #[serde(skip_serializing_if = "Option::is_none")]
    next_before: Option<i64>,
}

/// Members see their own entries, owners see all.
pub async fn security_log(
    State(state): State<AppState>,
    auth: Auth,
    ApiQuery(query): ApiQuery<LogQuery>,
) -> Result<Json<LogPage>, ApiError> {
    let limit = query.limit.unwrap_or(50).clamp(1, 200);
    let scope = (!auth.user.is_owner()).then_some(auth.user.id.as_str());
    let entries = seclog::list(state.db(), scope, query.before, limit).await?;
    let next_before = (entries.len() == limit as usize)
        .then(|| entries.last().map(|entry| entry.id))
        .flatten();
    Ok(Json(LogPage {
        entries,
        next_before,
    }))
}
