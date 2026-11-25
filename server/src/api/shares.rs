//! Shared links of the own account: `GET/POST /shares`, `DELETE /shares/{id}`.

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use super::{ApiError, ApiJson, AppState, Auth};
use crate::share::{self, NewShare, Share};

/// A link ends at the latest after this long.
const LONGEST_MS: i64 = 10 * 365 * 24 * 60 * 60 * 1000;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareList {
    shares: Vec<Share>,
    /// Whether links can be opened from the internet (`[share] enabled` and `public_url`).
    reachable: bool,
}

fn public_url(state: &AppState) -> Option<String> {
    let config = state.config();
    (config.share.enabled && !config.share.public_url.trim().is_empty())
        .then(|| config.share.public_url.trim().to_string())
}

/// `GET /shares`: the links still open.
pub async fn list(State(state): State<AppState>, auth: Auth) -> Result<Json<ShareList>, ApiError> {
    let url = public_url(&state);
    Ok(Json(ShareList {
        shares: share::list(state.db(), &auth.user.id, url.as_deref()).await?,
        reachable: url.is_some(),
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NewShareBody {
    title: Option<String>,
    album_id: Option<String>,
    #[serde(default)]
    asset_ids: Vec<String>,
    /// Unix milliseconds; missing or `null`: never.
    expires_at: Option<i64>,
    password: Option<String>,
    #[serde(default)]
    allow_originals: bool,
}

/// `POST /shares`: a new link to photos or an album.
pub async fn create(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(body): ApiJson<NewShareBody>,
) -> Result<(StatusCode, Json<Share>), ApiError> {
    let now = crate::db::now_ms();
    if let Some(end) = body.expires_at
        && (end <= now || end > now + LONGEST_MS)
    {
        return Err(ApiError::validation(
            "expiresAt must be in the future, within ten years.",
        ));
    }
    if body.asset_ids.len() > 5000 {
        return Err(ApiError::validation(
            "At most 5000 photos per link; share an album instead.",
        ));
    }
    if body.title.as_ref().is_some_and(|t| t.chars().count() > 200)
        || body.password.as_ref().is_some_and(|p| p.len() > 200)
    {
        return Err(ApiError::validation("The title or password is too long."));
    }
    let album_id = match &body.album_id {
        Some(id) => Some(
            uuid::Uuid::parse_str(id.trim())
                .map_err(|_| ApiError::validation("albumId must be a UUID."))?
                .to_string(),
        ),
        None => None,
    };
    let asset_ids = share::parse_ids(&serde_json::json!(body.asset_ids));
    if asset_ids.len() != body.asset_ids.len() {
        return Err(ApiError::validation("assetIds must be UUIDs."));
    }
    let url = public_url(&state);
    let made = share::create(
        state.db(),
        &auth.user.id,
        NewShare {
            title: body.title,
            album_id,
            asset_ids,
            expires_at: body.expires_at,
            password: body.password,
            allow_originals: body.allow_originals,
        },
        url.as_deref(),
    )
    .await
    .map_err(|error| {
        tracing::error!(%error, "could not make a shared link");
        ApiError::internal()
    })?;
    match made {
        Ok(share) => Ok((StatusCode::CREATED, Json(share))),
        Err(problem) => Err(ApiError::validation(problem)),
    }
}

/// `DELETE /shares/{id}`: the link ends now.
pub async fn revoke(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    if share::revoke(state.db(), &auth.user.id, &id).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found())
    }
}
