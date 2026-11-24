//! The library: sync, files, corrections and location suggestions.

use axum::{
    Json,
    extract::{Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Deserializer, Serialize};
use uuid::Uuid;

use super::{
    ApiError, ApiJson, ApiQuery, AppState, Auth,
    uploads::{parse_asset_id, parse_sha256},
};
use crate::{
    files::{self, BulkItem, Caching, FileToSend},
    library::{
        assets::{self, ROLES, StoredFile},
        edits::{
            self, AssetDetail, Correction, NewLocation, Playback, Suggestion, WithoutLocation,
        },
        sync::{self, SyncPage},
    },
};

/// At most this many files per bulk request.
const MAX_BULK: usize = 500;
const MAX_BULK_EDIT: usize = 1000;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SyncQuery {
    #[serde(default)]
    since: i64,
    limit: Option<u32>,
}

/// `GET /sync?since=N&limit=1000`.
pub async fn changes(
    State(state): State<AppState>,
    auth: Auth,
    ApiQuery(query): ApiQuery<SyncQuery>,
) -> Result<Json<SyncPage>, ApiError> {
    let page = sync::changes(
        state.db(),
        &auth.user.id,
        query.since.max(0),
        query.limit.unwrap_or(sync::DEFAULT_PAGE),
    )
    .await?;
    Ok(Json(page))
}

fn to_send(state: &AppState, file: StoredFile, caching: Caching) -> Result<FileToSend, ApiError> {
    let path = file
        .resolve(state.library_dir(), state.derived_dir())
        .ok_or_else(ApiError::not_found)?;
    Ok(FileToSend {
        path,
        download_name: file.download_name(),
        mime: file.mime,
        sha256_hex: hex::encode(&file.sha256),
        size: file.size.max(0) as u64,
        caching,
    })
}

/// `GET /files/{sha256}`: any file of the own account, by its content. Cached forever.
pub async fn file_by_hash(
    State(state): State<AppState>,
    auth: Auth,
    Path(sha256): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let hash = parse_sha256(&sha256).map_err(|_| ApiError::not_found())?;
    let file = assets::stored_file_by_hash(state.db(), &auth.user.id, &hash)
        .await?
        .ok_or_else(ApiError::not_found)?;
    Ok(files::send(to_send(&state, file, Caching::Immutable)?, &headers).await)
}

/// `GET /assets/{id}/files/{role}`: the current file in a role (`original`, `thumbnail`, …).
pub async fn file_by_role(
    State(state): State<AppState>,
    auth: Auth,
    Path((id, role)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if !ROLES.contains(&role.as_str()) {
        return Err(ApiError::not_found());
    }
    let file = assets::stored_file(state.db(), &auth.user.id, &id, &role)
        .await?
        .ok_or_else(ApiError::not_found)?;
    Ok(files::send(to_send(&state, file, Caching::Revalidate)?, &headers).await)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BulkRequest {
    ids: Vec<String>,
    #[serde(default = "thumbnail")]
    role: String,
}

fn thumbnail() -> String {
    "thumbnail".into()
}

/// `POST /thumbnails`: up to 500 thumbnails (or previews) in one streamed answer. See
/// [`files::bulk`] for the format.
pub async fn bulk(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<BulkRequest>,
) -> Result<Response, ApiError> {
    if request.ids.len() > MAX_BULK {
        return Err(ApiError::validation(format!(
            "At most {MAX_BULK} ids per request."
        )));
    }
    if !matches!(request.role.as_str(), "thumbnail" | "preview") {
        return Err(ApiError::validation("role must be thumbnail or preview."));
    }
    let ids = request
        .ids
        .iter()
        .map(|id| parse_asset_id(id))
        .collect::<Result<Vec<Uuid>, _>>()?;
    let keys: Vec<String> = ids.iter().map(Uuid::to_string).collect();
    let mut found =
        assets::stored_files_for(state.db(), &auth.user.id, &keys, &request.role).await?;
    let items = ids
        .into_iter()
        .zip(keys)
        .map(|(asset_id, key)| BulkItem {
            asset_id,
            path: found
                .remove(&key)
                .and_then(|file| file.resolve(state.library_dir(), state.derived_dir())),
        })
        .collect();
    Ok(files::bulk(items))
}

/// `GET /assets/{id}`: everything about one asset.
pub async fn detail(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<Json<AssetDetail>, ApiError> {
    edits::detail(state.db(), &auth.user.id, &id)
        .await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

/// Tells "field missing" (`None`) apart from "field is null" (`Some(None)`).
pub(super) fn present<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CorrectionBody {
    taken_at: Option<i64>,
    time_zone_offset_minutes: Option<i32>,
    /// An object sets the location; `null` removes it.
    #[serde(default, deserialize_with = "present")]
    location: Option<Option<NewLocation>>,
    #[serde(default, deserialize_with = "present")]
    title: Option<Option<String>>,
    #[serde(default, deserialize_with = "present")]
    description: Option<Option<String>>,
    /// The slow part of a slow-motion video; `null` removes it.
    #[serde(default, deserialize_with = "present")]
    playback: Option<Option<Playback>>,
    /// Drop corrections: `["takenAt", "location"]`.
    #[serde(default)]
    restore: Vec<String>,
}

impl From<CorrectionBody> for Correction {
    fn from(body: CorrectionBody) -> Self {
        Self {
            taken_at: body.taken_at,
            tz_offset_min: body.time_zone_offset_minutes,
            location: body.location,
            title: body.title,
            description: body.description,
            playback: body.playback,
            restore: body.restore,
        }
    }
}

/// `PATCH /assets/{id}`: correct time, place, title or description.
pub async fn correct(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<CorrectionBody>,
) -> Result<Json<assets::Asset>, ApiError> {
    let correction = Correction::from(body);
    correction.check().map_err(ApiError::validation)?;
    edits::correct(
        state.db(),
        &auth.user.id,
        &id,
        Some(&auth.device.id),
        &correction,
    )
    .await?
    .map(Json)
    .ok_or_else(ApiError::not_found)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BulkLocation {
    ids: Vec<String>,
    location: NewLocation,
}

#[derive(Serialize)]
pub struct Changed {
    changed: u64,
}

/// `POST /assets/location`: one place for many photos.
pub async fn set_location(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(body): ApiJson<BulkLocation>,
) -> Result<Json<Changed>, ApiError> {
    if body.ids.len() > MAX_BULK_EDIT {
        return Err(ApiError::validation(format!(
            "At most {MAX_BULK_EDIT} ids per request."
        )));
    }
    let correction = Correction {
        location: Some(Some(body.location)),
        ..Correction::default()
    };
    correction.check().map_err(ApiError::validation)?;
    let changed = edits::correct_many(
        state.db(),
        &auth.user.id,
        &body.ids,
        Some(&auth.device.id),
        &correction,
    )
    .await?;
    Ok(Json(Changed { changed }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WithoutLocationQuery {
    before: Option<i64>,
    limit: Option<u32>,
}

#[derive(Serialize)]
pub struct WithoutLocationPage {
    assets: Vec<WithoutLocation>,
}

/// `GET /assets/without-location?before=<takenAt>&limit=200`: photos without a place, each with
/// a suggestion from its neighbours in time.
pub async fn without_location(
    State(state): State<AppState>,
    auth: Auth,
    ApiQuery(query): ApiQuery<WithoutLocationQuery>,
) -> Result<Response, ApiError> {
    let assets = edits::without_location(
        state.db(),
        &auth.user.id,
        query.before,
        query.limit.unwrap_or(200),
        state.suggest_window_ms(),
    )
    .await?;
    Ok(Json(WithoutLocationPage { assets }).into_response())
}

#[derive(Serialize)]
pub struct SuggestionAnswer {
    suggestion: Option<Suggestion>,
}

/// `GET /assets/{id}/location-suggestion`.
pub async fn suggestion(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<Json<SuggestionAnswer>, ApiError> {
    let asset = assets::get(state.db().read(), &auth.user.id, &id)
        .await?
        .ok_or_else(ApiError::not_found)?;
    let suggestion = edits::suggest(
        state.db(),
        &auth.user.id,
        &asset.id,
        asset.taken_at,
        state.suggest_window_ms(),
    )
    .await?;
    Ok(Json(SuggestionAnswer { suggestion }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ids {
    ids: Vec<String>,
}

fn check_ids(ids: &[String]) -> Result<(), ApiError> {
    if ids.len() > MAX_BULK_EDIT {
        return Err(ApiError::validation(format!(
            "At most {MAX_BULK_EDIT} ids per request."
        )));
    }
    Ok(())
}

/// `POST /assets/trash`: move to the trash.
pub async fn trash(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(body): ApiJson<Ids>,
) -> Result<Json<Changed>, ApiError> {
    check_ids(&body.ids)?;
    let changed = crate::library::trash::trash(state.db(), &auth.user.id, &body.ids).await?;
    Ok(Json(Changed { changed }))
}

/// `POST /assets/restore`: take out of the trash.
pub async fn restore(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(body): ApiJson<Ids>,
) -> Result<Json<Changed>, ApiError> {
    check_ids(&body.ids)?;
    let changed = crate::library::trash::restore(state.db(), &auth.user.id, &body.ids).await?;
    Ok(Json(Changed { changed }))
}

/// `POST /assets/delete`: delete for good, only assets that are in the trash.
pub async fn delete(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(body): ApiJson<Ids>,
) -> Result<Json<Changed>, ApiError> {
    check_ids(&body.ids)?;
    let changed = crate::library::trash::delete(
        state.db(),
        crate::library::trash::Roots {
            library: state.library_dir(),
            derived: state.derived_dir(),
            mirror: state.mirror_dir(),
        },
        &auth.user.id,
        &body.ids,
    )
    .await?;
    Ok(Json(Changed { changed }))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsAnswer {
    #[serde(flatten)]
    settings: crate::library::settings::Settings,
    /// Conversions queued because a format changed.
    #[serde(skip_serializing_if = "Option::is_none")]
    queued_conversions: Option<u64>,
}

/// `GET /me/settings`.
pub async fn settings(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<Json<SettingsAnswer>, ApiError> {
    let settings = crate::library::settings::get(state.db(), &auth.user.id).await?;
    Ok(Json(SettingsAnswer {
        settings,
        queued_conversions: None,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsChange {
    photo_format: Option<crate::library::settings::PhotoFormat>,
    video_format: Option<crate::library::settings::VideoFormat>,
}

/// `PUT /me/settings`: change the preferred formats. Existing photos and videos are converted in
/// the background.
pub async fn change_settings(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(change): ApiJson<SettingsChange>,
) -> Result<Json<SettingsAnswer>, ApiError> {
    let mut settings = crate::library::settings::get(state.db(), &auth.user.id).await?;
    if let Some(photo) = change.photo_format {
        settings.photo_format = photo;
    }
    if let Some(video) = change.video_format {
        settings.video_format = video;
    }
    let queued = crate::library::settings::set(state.db(), &auth.user.id, settings).await?;
    state.wake_workers();
    Ok(Json(SettingsAnswer {
        settings,
        queued_conversions: Some(queued),
    }))
}
