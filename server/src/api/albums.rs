//! Albums: `GET/POST /albums`, `GET/PATCH/DELETE /albums/{id}`,
//! `POST/DELETE /albums/{id}/assets`.

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::Deserialize;
use uuid::Uuid;

use super::{ApiError, ApiJson, AppState, Auth, library::present};
use crate::library::albums::{self, Album, AlbumChange};

/// At most this many photos per request.
const MAX_IDS: usize = 5000;

fn album_id(text: &str) -> Result<String, ApiError> {
    Uuid::parse_str(text.trim())
        .map(|id| id.to_string())
        .map_err(|_| ApiError::validation("The album id must be a UUID."))
}

fn asset_ids(ids: Vec<String>) -> Result<Vec<String>, ApiError> {
    if ids.len() > MAX_IDS {
        return Err(ApiError::validation(format!(
            "At most {MAX_IDS} photos per request."
        )));
    }
    // Unknown or malformed ids are skipped, like ids of other accounts.
    Ok(ids
        .iter()
        .filter_map(|id| Uuid::parse_str(id.trim()).ok().map(|id| id.to_string()))
        .collect())
}

#[derive(serde::Serialize)]
pub struct AlbumList {
    albums: Vec<Album>,
}

/// `GET /albums`.
pub async fn list(State(state): State<AppState>, auth: Auth) -> Result<Json<AlbumList>, ApiError> {
    Ok(Json(AlbumList {
        albums: albums::list(state.db(), &auth.user.id).await?,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NewAlbum {
    /// Given by the device, so creating it again after a lost answer is safe.
    id: Option<String>,
    name: String,
    #[serde(default)]
    asset_ids: Vec<String>,
}

/// `POST /albums`: `201` with the new album, `200` when it was there already.
pub async fn create(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(body): ApiJson<NewAlbum>,
) -> Result<(StatusCode, Json<Album>), ApiError> {
    let id = match &body.id {
        Some(id) => album_id(id)?,
        None => Uuid::new_v4().to_string(),
    };
    let name = albums::clean_name(&body.name).map_err(ApiError::validation)?;
    let ids = asset_ids(body.asset_ids)?;
    match albums::create(state.db(), &auth.user.id, &id, &name, &ids).await? {
        Ok((album, true)) => Ok((StatusCode::CREATED, Json(album))),
        Ok((album, false)) => Ok((StatusCode::OK, Json(album))),
        Err(()) => Err(ApiError::conflict("This album id is taken.")),
    }
}

/// `GET /albums/{id}`.
pub async fn get(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<Json<Album>, ApiError> {
    albums::get(state.db(), &auth.user.id, &album_id(&id)?)
        .await?
        .filter(|album| album.deleted_at.is_none())
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AlbumChangeBody {
    name: Option<String>,
    #[serde(default, deserialize_with = "present")]
    cover_asset_id: Option<Option<String>>,
    sort_order: Option<i64>,
}

/// `PATCH /albums/{id}`: name, cover (`null`: the newest photo), place in the list.
pub async fn change(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<AlbumChangeBody>,
) -> Result<Json<Album>, ApiError> {
    let change = AlbumChange {
        name: body
            .name
            .as_deref()
            .map(albums::clean_name)
            .transpose()
            .map_err(ApiError::validation)?,
        cover_asset_id: body
            .cover_asset_id
            .map(|cover| cover.map(|c| asset_ids(vec![c])).transpose())
            .transpose()?
            .map(|cover| cover.and_then(|ids| ids.into_iter().next())),
        sort_order: body.sort_order,
    };
    albums::change(state.db(), &auth.user.id, &album_id(&id)?, &change)
        .await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AlbumAssets {
    asset_ids: Vec<String>,
}

/// `POST /albums/{id}/assets`: put photos in.
pub async fn add(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<AlbumAssets>,
) -> Result<Json<Album>, ApiError> {
    let ids = asset_ids(body.asset_ids)?;
    albums::add(state.db(), &auth.user.id, &album_id(&id)?, &ids)
        .await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

/// `DELETE /albums/{id}/assets`: take photos out (they stay in the library).
pub async fn remove(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    ApiJson(body): ApiJson<AlbumAssets>,
) -> Result<Json<Album>, ApiError> {
    let ids = asset_ids(body.asset_ids)?;
    albums::remove(state.db(), &auth.user.id, &album_id(&id)?, &ids)
        .await?
        .map(Json)
        .ok_or_else(ApiError::not_found)
}

/// `DELETE /albums/{id}`: the album goes, its photos stay. `204`, also when it was gone already.
pub async fn delete(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    if albums::delete(state.db(), &auth.user.id, &album_id(&id)?).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::not_found())
    }
}
