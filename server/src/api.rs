//! The HTTP API the apps talk to. All routes live under `/api/v1`.

use std::{sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use serde::Serialize;
use serde_json::json;
use sqlx::SqlitePool;
use tower_http::{limit::RequestBodyLimitLayer, timeout::TimeoutLayer, trace::TraceLayer};
use uuid::Uuid;

use crate::{API_VERSION, VERSION, db, tls::Fingerprint};

/// Requests other than uploads are small; anything bigger is refused early.
const MAX_BODY_BYTES: usize = 64 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub struct AppState(Arc<Inner>);

struct Inner {
    server_id: Uuid,
    name: String,
    fingerprint: Fingerprint,
    db: SqlitePool,
}

impl AppState {
    pub fn new(server_id: Uuid, name: String, fingerprint: Fingerprint, db: SqlitePool) -> Self {
        Self(Arc::new(Inner {
            server_id,
            name,
            fingerprint,
            db,
        }))
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/server", get(server_info))
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
    match db::ping(&state.0.db).await {
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
}

/// Public facts an app needs before pairing: which server this is and how to recognise it.
async fn server_info(State(state): State<AppState>) -> Json<ServerInfo> {
    Json(ServerInfo {
        name: state.0.name.clone(),
        server_id: state.0.server_id,
        version: VERSION,
        api_version: API_VERSION,
        fingerprint: state.0.fingerprint.hex(),
    })
}

async fn not_found() -> Response {
    (StatusCode::NOT_FOUND, Json(json!({ "error": "not_found" }))).into_response()
}
