//! What handlers pull out of a request: the signed-in device ([`Auth`]), the client's address
//! ([`ClientIp`]) and JSON bodies or query strings that fail with our JSON errors ([`ApiJson`],
//! [`ApiQuery`]).

use std::{
    net::{IpAddr, SocketAddr},
    time::Instant,
};

use axum::{
    Json,
    extract::{ConnectInfo, FromRequest, FromRequestParts, Query, Request},
    http::{header, request::Parts},
};
use serde::de::DeserializeOwned;

use super::{ApiError, AppState};
use crate::{
    accounts::{self, Device, User},
    auth::{password, token},
    db::now_ms,
    seclog::{Event, Record},
};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;
/// "Last seen" is written at most this often per device.
const TOUCH_EVERY_MS: i64 = 60 * 1000;

/// The address the request came from (IPv4 addresses arriving as IPv6 are shown as IPv4).
pub struct ClientIp(pub Option<IpAddr>);

impl<S: Send + Sync> FromRequestParts<S> for ClientIp {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        Ok(Self(client_ip(parts)))
    }
}

fn client_ip(parts: &Parts) -> Option<IpAddr> {
    parts
        .extensions
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ConnectInfo(addr)| addr.ip().to_canonical())
}

/// A signed-in device and its account. Every protected route takes this: the token is looked
/// up by its hash, and a signed-out device, a disabled account or a device unused for too long
/// is refused.
pub struct Auth {
    pub user: User,
    pub device: Device,
    pub ip: Option<IpAddr>,
}

impl FromRequestParts<AppState> for Auth {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let ip = client_ip(parts);
        let token = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| {
                value
                    .strip_prefix("Bearer ")
                    .or_else(|| value.strip_prefix("bearer "))
            })
            .map(|token| token.trim().to_string())
            .ok_or_else(|| ApiError::unauthorized("Sign in first."))?;
        if !token::is_well_formed(&token) {
            return Err(ApiError::unauthorized("This device is not signed in."));
        }
        let db = state.db();
        let Some((device, user)) = accounts::device_for_token(db, &token).await? else {
            return Err(ApiError::unauthorized("This device is not signed in."));
        };
        if device.revoked_at.is_some() {
            return Err(ApiError::unauthorized("This device was signed out."));
        }

        let now = now_ms();
        let inactive_days = state.auth().device_inactive_days;
        if inactive_days > 0 && now - device.last_seen_at > i64::from(inactive_days) * DAY_MS {
            accounts::revoke_device(db, &device.id).await?;
            Record::new(Event::DeviceExpired)
                .user(&user.id)
                .device(&device.id)
                .ip(ip)
                .detail(format!("unused for more than {inactive_days} days"))
                .write(db)
                .await;
            return Err(ApiError::unauthorized(
                "This device was signed out because it was not used for a long time.",
            ));
        }
        if user.disabled {
            return Err(ApiError::unauthorized("This account is disabled."));
        }

        let ip_text = ip.map(|ip| ip.to_string());
        if (now - device.last_seen_at >= TOUCH_EVERY_MS || device.last_seen_ip != ip_text)
            && let Err(error) = accounts::touch_device(db, &device.id, now, ip).await
        {
            tracing::warn!(%error, "could not note when a device was last seen");
        }
        Ok(Self { user, device, ip })
    }
}

impl Auth {
    pub fn require_owner(&self) -> Result<(), ApiError> {
        if self.user.is_owner() {
            Ok(())
        } else {
            Err(ApiError::forbidden(
                "Only an owner of this server can do this.",
            ))
        }
    }

    /// For changes that matter (accounts, roles, someone else's password): the person types
    /// their own password again. The brakes against guessing apply here too, so a stolen token
    /// can't be used to find out the password.
    pub async fn confirm_password(
        &self,
        state: &AppState,
        given: Option<String>,
    ) -> Result<(), ApiError> {
        let Some(given) = given.filter(|password| !password.is_empty()) else {
            return Err(ApiError::password_required(
                "Enter your current password to do this.",
            ));
        };
        let db = state.db();
        let Some(hash) = accounts::password_hash_of(db, &self.user.id).await? else {
            return Err(ApiError::password_required(
                "Set a password for your account first.",
            ));
        };
        let now = Instant::now();
        state
            .limiter()
            .check_user(&self.user.username, now)
            .map_err(ApiError::rate_limited)?;
        if password::verify(given, Some(hash)).await {
            state.limiter().user_succeeded(&self.user.username);
            Ok(())
        } else {
            state.limiter().user_failed(&self.user.username, now);
            Record::new(Event::PasswordCheckFailed)
                .user(&self.user.id)
                .device(&self.device.id)
                .ip(self.ip)
                .write(db)
                .await;
            Err(ApiError::wrong_current_password())
        }
    }
}

/// A JSON body. Malformed bodies get a `validation_failed` error instead of axum's plain text.
pub struct ApiJson<T>(pub T);

impl<T, S> FromRequest<S> for ApiJson<T>
where
    T: DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request(request: Request, state: &S) -> Result<Self, ApiError> {
        match Json::<T>::from_request(request, state).await {
            Ok(Json(value)) => Ok(Self(value)),
            Err(rejection) => Err(ApiError::new(
                rejection.status(),
                "validation_failed",
                rejection.body_text(),
            )),
        }
    }
}

/// A query string, failing like [`ApiJson`].
pub struct ApiQuery<T>(pub T);

impl<T, S> FromRequestParts<S> for ApiQuery<T>
where
    T: DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, ApiError> {
        match Query::<T>::from_request_parts(parts, state).await {
            Ok(Query(value)) => Ok(Self(value)),
            Err(rejection) => Err(ApiError::new(
                rejection.status(),
                "validation_failed",
                rejection.body_text(),
            )),
        }
    }
}
