//! Uploads: announce, send in pieces, finish. See `docs/PROTOCOL.md` and [`crate::upload`].

use axum::{
    Json,
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, HeaderName, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use uuid::Uuid;

use super::{ApiError, ApiJson, AppState, Auth};
use crate::{
    library::paths::MediaType,
    upload::{ClientMetadata, MAX_FILE_BYTES, NewUpload, UploadError, UploadRole, UploadState},
};

pub const UPLOAD_OFFSET: HeaderName = HeaderName::from_static("upload-offset");
pub const UPLOAD_LENGTH: HeaderName = HeaderName::from_static("upload-length");

impl From<UploadError> for ApiError {
    fn from(error: UploadError) -> Self {
        match error {
            UploadError::NotFound => ApiError::not_found(),
            UploadError::Busy => ApiError::new(
                StatusCode::CONFLICT,
                "upload_busy",
                "Another request is sending this upload right now.",
            ),
            UploadError::OffsetMismatch { expected } => ApiError::new(
                StatusCode::CONFLICT,
                "offset_mismatch",
                format!("The upload continues at byte {expected}."),
            )
            .with_offset(expected),
            UploadError::ChecksumMismatch => ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                "checksum_mismatch",
                "The file that arrived does not match its SHA-256. Start the upload again.",
            ),
            UploadError::Failed(reason) => ApiError::new(
                StatusCode::GONE,
                "upload_failed",
                format!("This upload ended ({reason}). Start it again."),
            ),
            UploadError::Conflict(message) => ApiError::conflict(message),
            UploadError::NotEnoughSpace(space) => ApiError::insufficient_storage(format!(
                "Not enough space on the server: the file needs {} MB, {} MB can be used.",
                space.needed.div_ceil(1_000_000),
                space.available / 1_000_000
            )),
            UploadError::Database(error) => crate::accounts::AccountError::Database(error).into(),
            UploadError::Io(error) => {
                tracing::error!(%error, "upload storage error");
                ApiError::internal()
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateUpload {
    /// UUID the device gave the photo when it was taken.
    asset_id: String,
    #[serde(default = "original")]
    role: UploadRole,
    size: u64,
    /// Lowercase or uppercase hex.
    sha256: String,
    mime_type: String,
    #[serde(default)]
    metadata: ClientMetadata,
}

fn original() -> UploadRole {
    UploadRole::Original
}

pub fn parse_sha256(text: &str) -> Result<[u8; 32], ApiError> {
    let mut hash = [0u8; 32];
    hex::decode_to_slice(text.trim(), &mut hash)
        .map_err(|_| ApiError::validation("sha256 must be 64 hex characters."))?;
    Ok(hash)
}

pub fn parse_asset_id(text: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(text.trim()).map_err(|_| ApiError::validation("assetId must be a UUID."))
}

fn with_offset_headers(state: &UploadState, mut response: Response) -> Response {
    let (offset, length) = match state {
        UploadState::Receiving(progress) => (Some(progress.offset), Some(progress.size)),
        UploadState::Completed { asset } => {
            let size = asset
                .files
                .iter()
                .find(|f| f.role == "original")
                .map(|f| f.size as u64);
            (size, size)
        }
        UploadState::Duplicate { .. } => (None, None),
    };
    if let Some(offset) = offset {
        response
            .headers_mut()
            .insert(UPLOAD_OFFSET, HeaderValue::from(offset));
    }
    if let Some(length) = length {
        response
            .headers_mut()
            .insert(UPLOAD_LENGTH, HeaderValue::from(length));
    }
    response
}

/// `POST /uploads`: announce a file.
pub async fn create(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<CreateUpload>,
) -> Result<Response, ApiError> {
    let asset_id = parse_asset_id(&request.asset_id)?;
    let sha256 = parse_sha256(&request.sha256)?;
    if request.size == 0 || request.size > MAX_FILE_BYTES {
        return Err(ApiError::validation(
            "size must be between 1 byte and 1 TiB.",
        ));
    }
    let media = MediaType::from_mime(&request.mime_type).ok_or_else(|| {
        ApiError::unsupported_media_type(format!(
            "Halden doesn't store files of type {}.",
            request.mime_type
        ))
    })?;
    request.metadata.check().map_err(ApiError::validation)?;

    let upload = state
        .uploads()
        .create(
            state.db(),
            &auth.user,
            &auth.device.id,
            NewUpload {
                asset_id,
                role: request.role,
                size: request.size,
                sha256,
                media,
                metadata: request.metadata,
            },
        )
        .await?;
    let status = match &upload {
        UploadState::Receiving(progress) if progress.offset == 0 => StatusCode::CREATED,
        _ => StatusCode::OK,
    };
    let response = (status, Json(&upload)).into_response();
    Ok(with_offset_headers(&upload, response))
}

/// `GET /uploads/{id}` (and `HEAD`): where the upload stands.
pub async fn status(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let upload = state.uploads().status(state.db(), &auth.user, &id).await?;
    let response = Json(&upload).into_response();
    Ok(with_offset_headers(&upload, response))
}

/// `PATCH /uploads/{id}` with `Upload-Offset`: the next bytes.
pub async fn send(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Result<Response, ApiError> {
    let offset = headers
        .get(&UPLOAD_OFFSET)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .ok_or_else(|| ApiError::validation("The Upload-Offset header is missing or invalid."))?;
    let upload = state
        .uploads()
        .receive(state.db(), &auth.user, &id, offset, body)
        .await?;
    let response = Json(&upload).into_response();
    Ok(with_offset_headers(&upload, response))
}

/// `POST /uploads/{id}/complete`: finishes an upload whose bytes all arrived (normally the last
/// `PATCH` does this already; this is for retries).
pub async fn complete(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let uploads = state.uploads();
    let upload = match uploads.status(state.db(), &auth.user, &id).await? {
        UploadState::Receiving(progress) if progress.offset < progress.size => {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "upload_incomplete",
                format!(
                    "{} of {} bytes arrived. Send the rest first.",
                    progress.offset, progress.size
                ),
            )
            .with_offset(progress.offset));
        }
        UploadState::Receiving(progress) => {
            uploads
                .receive(state.db(), &auth.user, &id, progress.offset, Body::empty())
                .await?
        }
        done => done,
    };
    let response = Json(&upload).into_response();
    Ok(with_offset_headers(&upload, response))
}

/// `DELETE /uploads/{id}`: give up on an upload.
pub async fn cancel(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    state.uploads().cancel(state.db(), &auth.user, &id).await?;
    Ok(StatusCode::NO_CONTENT)
}
