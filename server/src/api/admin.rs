//! Managing accounts. Owners only; changes that hand out access (new accounts, roles,
//! someone else's password, deleting) need the owner's own password again.

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};

use super::{ApiError, ApiJson, AppState, Auth};
use crate::{
    accounts::{self, NewUser, Role, User, UserSummary},
    auth::password,
    seclog::{Event, Record},
};

#[derive(Serialize)]
pub struct UserList {
    users: Vec<UserSummary>,
}

pub async fn list_users(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<Json<UserList>, ApiError> {
    auth.require_owner()?;
    Ok(Json(UserList {
        users: accounts::list_users(state.db()).await?,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateUser {
    username: String,
    display_name: Option<String>,
    #[serde(default = "member")]
    role: Role,
    /// Leave out for an account that only adds devices by pairing.
    password: Option<String>,
    current_password: Option<String>,
}

fn member() -> Role {
    Role::Member
}

pub async fn create_user(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<CreateUser>,
) -> Result<(StatusCode, Json<User>), ApiError> {
    auth.require_owner()?;
    auth.confirm_password(&state, request.current_password)
        .await?;
    let username = accounts::check_username(&request.username)?;
    let password_hash = match request.password {
        Some(new) => {
            password::check_new(&new, &username).map_err(ApiError::validation)?;
            Some(password::hash(new).await?)
        }
        None => None,
    };
    let db = state.db();
    let user = accounts::create_user(
        db,
        NewUser {
            username: &username,
            display_name: request.display_name.as_deref(),
            role: request.role,
            password_hash,
        },
    )
    .await?;
    Record::new(Event::UserCreated)
        .user(&user.id)
        .device(&auth.device.id)
        .ip(auth.ip)
        .detail(format!(
            "{} as {} by {}",
            user.username, user.role, auth.user.username
        ))
        .write(db)
        .await;
    Ok((StatusCode::CREATED, Json(user)))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateUser {
    display_name: Option<String>,
    /// Needs `currentPassword`.
    role: Option<Role>,
    disabled: Option<bool>,
    /// A new password for the account. Needs `currentPassword`.
    password: Option<String>,
    /// With `password`: also sign out all devices of the account.
    #[serde(default)]
    sign_out_devices: bool,
    current_password: Option<String>,
}

pub async fn update_user(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<UpdateUser>,
) -> Result<Json<User>, ApiError> {
    auth.require_owner()?;
    let db = state.db();
    let target = accounts::user_by_id(db, &id)
        .await?
        .ok_or_else(ApiError::not_found)?;
    if request.role.is_some() || request.password.is_some() {
        auth.confirm_password(&state, request.current_password)
            .await?;
    }
    // Check everything before changing anything.
    if let Some(name) = &request.display_name {
        accounts::check_display_name(name)?;
    }
    let password_hash = match request.password {
        Some(new) => {
            password::check_new(&new, &target.username).map_err(ApiError::validation)?;
            Some(password::hash(new).await?)
        }
        None => None,
    };

    let log = |event: Event, detail: String| {
        Record::new(event)
            .user(&target.id)
            .device(&auth.device.id)
            .ip(auth.ip)
            .detail(format!("{detail} by {}", auth.user.username))
    };
    if let Some(role) = request.role.filter(|role| *role != target.role) {
        accounts::set_role(db, &target.id, role).await?;
        log(Event::RoleChanged, format!("{} → {role}", target.role))
            .write(db)
            .await;
    }
    if let Some(disabled) = request.disabled.filter(|d| *d != target.disabled) {
        accounts::set_disabled(db, &target.id, disabled).await?;
        let event = if disabled {
            Event::UserDisabled
        } else {
            Event::UserEnabled
        };
        log(event, target.username.clone()).write(db).await;
    }
    if let Some(name) = request
        .display_name
        .filter(|n| n.trim() != target.display_name)
    {
        accounts::set_display_name(db, &target.id, &name).await?;
        log(
            Event::UserRenamed,
            format!("{} → {}", target.display_name, name.trim()),
        )
        .write(db)
        .await;
    }
    if let Some(hash) = password_hash {
        accounts::set_password_hash(db, &target.id, &hash).await?;
        let keep = (target.id == auth.user.id).then_some(auth.device.id.as_str());
        let signed_out = if request.sign_out_devices {
            accounts::revoke_other_devices(db, &target.id, keep).await?
        } else {
            0
        };
        log(
            Event::PasswordReset,
            format!("{signed_out} devices signed out"),
        )
        .write(db)
        .await;
    }

    let updated = accounts::user_by_id(db, &target.id)
        .await?
        .ok_or_else(ApiError::not_found)?;
    Ok(Json(updated))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeleteUser {
    current_password: Option<String>,
}

/// Deletes the account and its devices. Never the last owner.
pub async fn delete_user(
    State(state): State<AppState>,
    auth: Auth,
    Path(id): Path<String>,
    ApiJson(request): ApiJson<DeleteUser>,
) -> Result<StatusCode, ApiError> {
    auth.require_owner()?;
    let db = state.db();
    let target = accounts::user_by_id(db, &id)
        .await?
        .ok_or_else(ApiError::not_found)?;
    auth.confirm_password(&state, request.current_password)
        .await?;
    accounts::delete_user(db, &target.id).await?;
    let mut record = Record::new(Event::UserDeleted)
        .user(&target.id)
        .ip(auth.ip)
        .detail(format!("{} by {}", target.username, auth.user.username));
    if target.id != auth.user.id {
        record = record.device(&auth.device.id);
    }
    record.write(db).await;
    Ok(StatusCode::NO_CONTENT)
}
