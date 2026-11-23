//! The HTTP API the apps talk to. All routes live under `/api/v1`; see `docs/PROTOCOL.md`.

mod admin;
mod assets;
mod auth;
mod devices;
mod error;
mod extract;
mod library;
mod manage;
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
    suggest_window_ms: i64,
    wake: Arc<tokio::sync::Notify>,
    mirror_dir: Option<PathBuf>,
    backup_status: Arc<crate::backup::mirror::StatusCell>,
    control: crate::server::Control,
    /// The settings this server runs with.
    config: Config,
}

/// What the running server hands to the API.
pub struct Services {
    pub server_id: Uuid,
    pub fingerprint: Fingerprint,
    /// The port the server really listens on.
    pub port: u16,
    pub db: Db,
    pub uploads: Arc<Uploads>,
    pub wake: Arc<tokio::sync::Notify>,
    pub backup_status: Arc<crate::backup::mirror::StatusCell>,
    pub control: crate::server::Control,
}

impl AppState {
    pub fn new(config: &Config, services: Services) -> Self {
        Self(Arc::new(Inner {
            server_id: services.server_id,
            name: config.server.name.clone(),
            fingerprint: services.fingerprint,
            port: services.port,
            db: services.db,
            auth: config.auth.clone(),
            limiter: RateLimiter::new(),
            uploads: services.uploads,
            library_dir: config.storage.library_dir.clone(),
            derived_dir: config.derived_dir(),
            suggest_window_ms: i64::from(config.library.location_suggest_minutes) * 60_000,
            wake: services.wake,
            mirror_dir: config.mirror.path.clone(),
            backup_status: services.backup_status,
            control: services.control,
            config: config.clone(),
        }))
    }

    pub fn control(&self) -> &crate::server::Control {
        &self.0.control
    }

    pub fn config(&self) -> &Config {
        &self.0.config
    }

    pub fn server_id(&self) -> Uuid {
        self.0.server_id
    }

    pub fn uploads(&self) -> &Arc<Uploads> {
        &self.0.uploads
    }

    pub fn library_dir(&self) -> &std::path::Path {
        &self.0.library_dir
    }

    pub fn derived_dir(&self) -> &std::path::Path {
        &self.0.derived_dir
    }

    pub fn mirror_dir(&self) -> Option<&std::path::Path> {
        self.0.mirror_dir.as_deref()
    }

    /// The backup status, refreshed in the background.
    pub fn backup_status(&self) -> crate::backup::mirror::BackupStatus {
        self.0.backup_status.get()
    }

    /// Tells the background workers that new jobs are waiting.
    pub fn wake_workers(&self) {
        self.0.wake.notify_waiters();
    }

    pub fn suggest_window_ms(&self) -> i64 {
        self.0.suggest_window_ms
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
        .route("/api/v1/assets/location", post(library::set_location))
        .route("/api/v1/assets/trash", post(library::trash))
        .route("/api/v1/assets/restore", post(library::restore))
        .route("/api/v1/assets/delete", post(library::delete))
        .route(
            "/api/v1/me/settings",
            get(library::settings).put(library::change_settings),
        )
        .route(
            "/api/v1/assets/without-location",
            get(library::without_location),
        )
        .route(
            "/api/v1/assets/{id}",
            get(library::detail).patch(library::correct),
        )
        .route(
            "/api/v1/assets/{id}/location-suggestion",
            get(library::suggestion),
        )
        .route("/api/v1/sync", get(library::changes))
        .route("/api/v1/admin/status", get(manage::status))
        .route(
            "/api/v1/admin/config",
            get(manage::config).patch(manage::change_config),
        )
        .route(
            "/api/v1/admin/backups",
            get(manage::backups).post(manage::back_up_now),
        )
        .route(
            "/api/v1/admin/mirror",
            get(manage::mirror)
                .put(manage::set_mirror)
                .delete(manage::mirror_off),
        )
        .route("/api/v1/admin/jobs", get(manage::jobs))
        .route("/api/v1/admin/jobs/retry", post(manage::retry_jobs))
        .route("/api/v1/admin/doctor", get(manage::doctor))
        .route("/api/v1/admin/restart", post(manage::restart))
        .route("/api/v1/admin/update", get(manage::update_status))
        .route("/api/v1/admin/update/check", post(manage::check_for_update))
        .route("/api/v1/admin/update/install", post(manage::install_update))
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
        .route(
            "/api/v1/assets/{id}/files/{role}",
            get(library::file_by_role).put(assets::put_file),
        )
        .route("/api/v1/files/{sha256}", get(library::file_by_hash))
        .route("/api/v1/thumbnails", post(library::bulk));

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
