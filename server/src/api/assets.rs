//! Assets: look one up, check many hashes at once, add thumbnails and previews.

use axum::{
    Json,
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header},
};
use serde::{Deserialize, Serialize};

use super::{
    ApiError, ApiJson, AppState, Auth,
    uploads::{parse_asset_id, parse_sha256},
};
use crate::library::{
    assets::{self, Asset, CheckResult},
    derived::{self, DerivedError, DerivedRole, NewDerived},
    paths::MediaType,
};

/// More than this many items per `POST /assets/check` is refused.
const MAX_CHECK_ITEMS: usize = 1000;

impl From<DerivedError> for ApiError {
    fn from(error: DerivedError) -> Self {
        match error {
            DerivedError::NotFound => ApiError::not_found(),
            DerivedError::ChecksumMismatch => ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "checksum_mismatch",
                "The file that arrived does not match its SHA-256.",
            ),
            DerivedError::Database(error) => crate::accounts::AccountError::Database(error).into(),
            DerivedError::Io(error) => {
                tracing::error!(%error, "could not store a thumbnail or preview");
                ApiError::internal()
            }
        }
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(error: sqlx::Error) -> Self {
        crate::accounts::AccountError::Database(error).into()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CheckItem {
    asset_id: String,
    sha256: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckRequest {
    items: Vec<CheckItem>,
}

#[derive(Serialize)]
pub struct CheckResponse {
    results: Vec<CheckResult>,
}

/// `POST /assets/check`: which of these are backed up already? Up to 1000 at once, so a phone
/// importing its photo library learns in a few requests what it still has to send.
pub async fn check(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<CheckRequest>,
) -> Result<Json<CheckResponse>, ApiError> {
    if request.items.len() > MAX_CHECK_ITEMS {
        return Err(ApiError::validation(format!(
            "At most {MAX_CHECK_ITEMS} items per request."
        )));
    }
    let items = request
        .items
        .iter()
        .map(|item| {
            Ok((
                parse_asset_id(&item.asset_id)?.to_string(),
                parse_sha256(&item.sha256)?,
            ))
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    let results = assets::check_many(state.db(), &auth.user.id, &items).await?;
    Ok(Json(CheckResponse { results }))
}

fn header_number(headers: &HeaderMap, name: &str) -> Result<Option<u32>, ApiError> {
    match headers.get(name) {
        None => Ok(None),
        Some(value) => value
            .to_str()
            .ok()
            .and_then(|v| v.trim().parse::<u32>().ok())
            .filter(|n| (1..=100_000).contains(n))
            .map(Some)
            .ok_or_else(|| ApiError::validation(format!("{name} must be a number of pixels."))),
    }
}

/// `PUT /assets/{id}/files/{role}`: a thumbnail or preview in one request. Headers:
/// `Content-Type` (JPEG, HEIC, PNG or WebP), `Halden-Sha256`, and optionally `Halden-Width` and
/// `Halden-Height`.
pub async fn put_file(
    State(state): State<AppState>,
    auth: Auth,
    Path((id, role)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Result<Json<Asset>, ApiError> {
    let role = DerivedRole::parse(&role).ok_or_else(|| {
        ApiError::validation(
            "Only thumbnail and preview can be sent this way; originals use /uploads.",
        )
    })?;
    let media = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(MediaType::from_mime)
        .filter(MediaType::is_derived_image)
        .ok_or_else(|| {
            ApiError::unsupported_media_type(
                "Thumbnails and previews must be JPEG, HEIC, PNG or WebP.",
            )
        })?;
    let sha256 = parse_sha256(
        headers
            .get("halden-sha256")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default(),
    )?;
    let width = header_number(&headers, "halden-width")?;
    let height = header_number(&headers, "halden-height")?;
    let data = axum::body::to_bytes(body, derived::MAX_BYTES)
        .await
        .map_err(|_| ApiError::too_large("Thumbnails and previews may have at most 8 MiB."))?;

    let asset = derived::store(
        state.db(),
        state.derived_dir(),
        &auth.user.id,
        &id,
        NewDerived {
            role,
            media,
            sha256,
            width,
            height,
            data,
        },
    )
    .await?;
    Ok(Json(asset))
}
