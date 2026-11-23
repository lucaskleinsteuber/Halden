//! The HTTP API the apps talk to. All routes live under `/api/v1`; see `docs/PROTOCOL.md`.

mod admin;
mod auth;
mod devices;
mod error;
mod extract;

use std::{sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, patch, post, put},
};
use serde::Serialize;
use serde_json::json;
use sqlx::SqlitePool;
use tower_http::{limit::RequestBodyLimitLayer, timeout::TimeoutLayer, trace::TraceLayer};
use uuid::Uuid;

pub use self::{
    error::ApiError,
    extract::{ApiJson, ApiQuery, Auth, ClientIp},
};
use crate::{
    API_VERSION, VERSION,
    auth::ratelimit::RateLimiter,
    config::{AuthConfig, Config},
    db,
    tls::Fingerprint,
};

/// Requests other than uploads are small; anything bigger is refused early.
const MAX_BODY_BYTES: usize = 64 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub struct AppState(Arc<Inner>);

struct Inner {
    server_id: Uuid,
    name: String,
    fingerprint: Fingerprint,
    /// The port the server really listens on (the config may say 0 in tests).
    port: u16,
    db: SqlitePool,
    auth: AuthConfig,
    limiter: RateLimiter,
}

impl AppState {
    pub fn new(
        config: &Config,
        server_id: Uuid,
        fingerprint: Fingerprint,
        port: u16,
        db: SqlitePool,
    ) -> Self {
        Self(Arc::new(Inner {
            server_id,
            name: config.server.name.clone(),
            fingerprint,
            port,
            db,
            auth: config.auth.clone(),
            limiter: RateLimiter::new(),
        }))
    }

    pub fn db(&self) -> &SqlitePool {
        &self.0.db
    }

    pub fn auth(&self) -> &AuthConfig {
        &self.0.auth
    }

    pub fn limiter(&self) -> &RateLimiter {
        &self.0.limiter
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/server", get(server_info))
        .route("/api/v1/auth/login", post(auth::login))
        .route("/api/v1/auth/pair", post(auth::pair))
        .route("/api/v1/auth/logout", post(auth::logout))
        .route("/api/v1/me", get(auth::me))
        .route("/api/v1/me/password", put(auth::change_password))
        .route("/api/v1/pairing-codes", post(auth::create_pairing_code))
        .route("/api/v1/devices", get(devices::list))
        .route(
            "/api/v1/devices/{id}",
            axum::routing::delete(devices::revoke),
        )
        .route("/api/v1/devices/{id}/confirm", post(devices::confirm))
        .route("/api/v1/devices/{id}/block", post(devices::block))
        .route("/api/v1/security-log", get(devices::security_log))
        .route(
            "/api/v1/admin/users",
            get(admin::list_users).post(admin::create_user),
        )
        .route(
            "/api/v1/admin/users/{id}",
            patch(admin::update_user).delete(admin::delete_user),
        )
        .fallback(not_found)
        .layer(RequestBodyLimitLayer::new(MAX_BODY_BYTES))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            REQUEST_TIMEOUT,
        ))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// Is the server up and can it reach its database?
async fn health(State(state): State<AppState>) -> Response {
    match db::ping(state.db()).await {
        Ok(()) => Json(json!({ "status": "ok" })).into_response(),
        Err(error) => {
            tracing::error!(%error, "health check: database does not answer");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({ "status": "unavailable", "problem": "database" })),
            )
                .into_response()
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerInfo {
    pub name: String,
    pub server_id: Uuid,
    pub version: &'static str,
    pub api_version: u32,
    /// SHA-256 of the certificate, lowercase hex. Apps compare it with the one they pinned.
    pub fingerprint: String,
    /// Can devices sign in with a password, or only pair?
    pub password_login: bool,
}

/// Public facts an app needs before pairing: which server this is and how to recognise it.
async fn server_info(State(state): State<AppState>) -> Json<ServerInfo> {
    Json(ServerInfo {
        name: state.0.name.clone(),
        server_id: state.0.server_id,
        version: VERSION,
        api_version: API_VERSION,
        fingerprint: state.0.fingerprint.hex(),
        password_login: state.0.auth.password_login,
    })
}

async fn not_found() -> ApiError {
    ApiError::not_found()
}
