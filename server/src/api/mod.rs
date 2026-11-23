//! The HTTP API the apps talk to. All routes live under `/api/v1`; see `docs/PROTOCOL.md`.

mod admin;
mod assets;
mod auth;
mod devices;
mod error;
mod extract;
mod uploads;

use std::{path::PathBuf, sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{delete, get, patch, post, put},
};
use serde::Serialize;
use serde_json::json;
use tower_http::{
    compression::{CompressionLayer, CompressionLevel, predicate::SizeAbove},
    timeout::TimeoutLayer,
    trace::TraceLayer,
};
use uuid::Uuid;

pub use self::{
    error::ApiError,
    extract::{ApiJson, ApiQuery, Auth, ClientIp},
};
use crate::{
    API_VERSION, VERSION,
    auth::ratelimit::RateLimiter,
    config::{AuthConfig, Config},
    db::{self, Db},
    tls::Fingerprint,
    upload::Uploads,
};

/// JSON requests are small (the biggest is a check of 1000 hashes, about 110 KB); anything
/// bigger is refused before it is read.
const MAX_BODY_BYTES: usize = 256 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// JSON smaller than this isn't worth compressing.
const COMPRESS_ABOVE_BYTES: u64 = 1024;

#[derive(Clone)]
pub struct AppState(Arc<Inner>);

struct Inner {
    server_id: Uuid,
    name: String,
    fingerprint: Fingerprint,
    /// The port the server really listens on (the config may say 0 in tests).
    port: u16,
    db: Db,
    auth: AuthConfig,
    limiter: RateLimiter,
    uploads: Arc<Uploads>,
    library_dir: PathBuf,
    derived_dir: PathBuf,
}

impl AppState {
    pub fn new(
        config: &Config,
        server_id: Uuid,
        fingerprint: Fingerprint,
        port: u16,
        db: Db,
        uploads: Arc<Uploads>,
    ) -> Self {
        Self(Arc::new(Inner {
            server_id,
            name: config.server.name.clone(),
            fingerprint,
            port,
            db,
            auth: config.auth.clone(),
            limiter: RateLimiter::new(),
            uploads,
            library_dir: config.storage.library_dir.clone(),
            derived_dir: config.derived_dir(),
        }))
    }

    pub fn uploads(&self) -> &Uploads {
        &self.0.uploads
    }

    pub fn library_dir(&self) -> &std::path::Path {
        &self.0.library_dir
    }

    pub fn derived_dir(&self) -> &std::path::Path {
        &self.0.derived_dir
    }

    pub fn db(&self) -> &Db {
        &self.0.db
    }

    pub fn auth(&self) -> &AuthConfig {
        &self.0.auth
    }

    pub fn limiter(&self) -> &RateLimiter {
        &self.0.limiter
    }
}

/// Two kinds of routes. Small JSON requests get a 30 s limit, a 256 KiB body limit and
/// compressed answers. File transfers get none of that: a 2 GB video may take an hour over a slow
/// link, and its bytes are streamed and limited by the upload's declared size instead. Transfers
/// still stop when nothing arrives for a minute.
pub fn router(state: AppState) -> Router {
    let json = Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/server", get(server_info))
        .route("/api/v1/auth/login", post(auth::login))
        .route("/api/v1/auth/pair", post(auth::pair))
        .route("/api/v1/auth/logout", post(auth::logout))
        .route("/api/v1/me", get(auth::me))
        .route("/api/v1/me/password", put(auth::change_password))
        .route("/api/v1/pairing-codes", post(auth::create_pairing_code))
        .route("/api/v1/devices", get(devices::list))
        .route("/api/v1/devices/{id}", delete(devices::revoke))
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
        .route("/api/v1/uploads", post(uploads::create))
        .route(
            "/api/v1/uploads/{id}",
            get(uploads::status).delete(uploads::cancel),
        )
        .route("/api/v1/uploads/{id}/complete", post(uploads::complete))
        .route("/api/v1/assets/check", post(assets::check))
        .route("/api/v1/assets/{id}", get(assets::get))
        .layer(
            CompressionLayer::new()
                .gzip(true)
                .br(true)
                .quality(CompressionLevel::Fastest)
                .compress_when(SizeAbove::new(COMPRESS_ABOVE_BYTES)),
        )
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            REQUEST_TIMEOUT,
        ));

    let transfers = Router::new()
        .route("/api/v1/uploads/{id}", patch(uploads::send))
        .route("/api/v1/assets/{id}/files/{role}", put(assets::put_file));

    json.merge(transfers)
        .fallback(not_found)
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
