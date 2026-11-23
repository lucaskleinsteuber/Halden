//! Looking after the server from the apps (owners only): how it is doing, its settings, backups,
//! the mirror, background jobs and `halden doctor`. What the terminal can do, the apps can do,
//! except what needs the server stopped (restoring a backup) or could lock the apps out
//! (folders, port, certificate). Changes that open the server up or can delete data need the
//! owner's password again.

use std::path::PathBuf;

use axum::{Json, extract::State, http::StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{ApiError, ApiJson, ApiQuery, AppState, Auth};
use crate::{
    API_VERSION, VERSION, accounts,
    backup::{
        database,
        mirror::{self, BackupStatus},
    },
    config::{
        Config,
        edit::{self, Change},
        keys::{self, Access, Key},
    },
    db::now_ms,
    doctor, fsutil,
    jobs::{self, QueueStats},
    library::assets,
    seclog::{Event, Record},
    update,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Disk {
    path: String,
    free_bytes: u64,
    total_bytes: u64,
}

fn disk(path: &std::path::Path) -> Option<Disk> {
    Some(Disk {
        path: path.display().to_string(),
        free_bytes: fs4::available_space(path).ok()?,
        total_bytes: fs4::total_space(path).ok()?,
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountUsage {
    user_id: String,
    username: String,
    photos: i64,
    videos: i64,
    trashed: i64,
    library_bytes: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolsFound {
    ffmpeg: bool,
    libheif: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerStatus {
    name: String,
    server_id: String,
    version: &'static str,
    api_version: u32,
    /// When the server process started (Unix ms).
    started_at: i64,
    /// Restarts with new settings since then.
    restarts: u64,
    /// The server's own memory, where the system tells (Linux).
    memory_bytes: Option<u64>,
    library_disk: Option<Disk>,
    data_disk: Option<Disk>,
    mirror_disk: Option<Disk>,
    accounts: Vec<AccountUsage>,
    uploads_in_progress: usize,
    jobs: QueueStats,
    backup: BackupStatus,
    tools: ToolsFound,
    /// The config file was changed but can't be used; the server runs with its old settings.
    config_problem: Option<String>,
    /// Running in a container: updates come with a new image, not from the app.
    in_docker: bool,
}

/// The server's own memory in bytes (resident, anonymous pages: what it really uses).
pub fn own_memory() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("RssAnon:"))?;
    let kb: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb * 1024)
}

pub async fn status(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<Json<ServerStatus>, ApiError> {
    auth.require_owner()?;
    let db = state.db();
    let config = state.config();
    let mut usage = Vec::new();
    for summary in accounts::list_users(db).await? {
        let stats = assets::stats(db, Some(&summary.user.id)).await?;
        usage.push(AccountUsage {
            user_id: summary.user.id.clone(),
            username: summary.user.username.clone(),
            photos: stats.photos,
            videos: stats.videos,
            trashed: stats.trashed,
            library_bytes: stats.library_bytes,
        });
    }
    let tools = jobs::Tools::find();
    Ok(Json(ServerStatus {
        name: config.server.name.clone(),
        server_id: state.server_id().to_string(),
        version: VERSION,
        api_version: API_VERSION,
        started_at: state.control().started_at(),
        restarts: state.control().restarts(),
        memory_bytes: own_memory(),
        library_disk: disk(&config.storage.library_dir),
        data_disk: disk(&config.storage.data_dir),
        mirror_disk: config.mirror.path.as_deref().and_then(disk),
        accounts: usage,
        uploads_in_progress: state.uploads().in_progress(),
        jobs: jobs::stats(db).await?,
        backup: mirror::compute_status(db, config).await,
        tools: ToolsFound {
            ffmpeg: tools.ffmpeg.is_some() && tools.ffprobe.is_some(),
            libheif: tools.heif_dec.is_some() && tools.heif_enc.is_some(),
        },
        config_problem: state.control().config_problem(),
        in_docker: std::env::var_os("HALDEN_IN_DOCKER").is_some(),
    }))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Setting {
    #[serde(flatten)]
    key: Key,
    value: Value,
    default: Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    settings: Vec<Setting>,
    /// Whether the server can save changes (it was started from a config file it may write).
    can_change: bool,
    config_problem: Option<String>,
    /// True when the server is about to start again with the changes.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    restarting: bool,
}

fn settings_of(state: &AppState, config: &Config, restarting: bool) -> Settings {
    let defaults = Config::default();
    Settings {
        settings: keys::KEYS
            .iter()
            .map(|key| Setting {
                key: *key,
                value: key.value_in(config),
                default: key.value_in(&defaults),
            })
            .collect(),
        can_change: state.control().config_path().is_some(),
        config_problem: state.control().config_problem(),
        restarting,
    }
}

pub async fn config(State(state): State<AppState>, auth: Auth) -> Result<Json<Settings>, ApiError> {
    auth.require_owner()?;
    Ok(Json(settings_of(&state, state.config(), false)))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChangeSettings {
    /// `{"library.trash_days": 60}`; `null` puts a setting back to its default.
    changes: Map<String, Value>,
    current_password: Option<String>,
}

/// Turns requested changes into checked ones; asks for the password when one needs it.
async fn checked_changes(
    state: &AppState,
    auth: &Auth,
    changes: &Map<String, Value>,
    current_password: Option<String>,
) -> Result<Vec<(&'static Key, Change)>, ApiError> {
    if changes.is_empty() {
        return Err(ApiError::validation("Nothing to change."));
    }
    let mut checked = Vec::new();
    let mut needs_password = false;
    for (name, value) in changes {
        let key = keys::find(name)
            .ok_or_else(|| ApiError::validation(format!("There is no setting {name}.")))?;
        match key.access {
            Access::Terminal => {
                return Err(ApiError::forbidden(format!(
                    "{name} can only be changed in the server's terminal: sudo halden config set {name} <value>"
                )));
            }
            Access::Password => needs_password = true,
            Access::Owner => {}
        }
        let mut change =
            edit::from_json(key, value).map_err(|e| ApiError::validation(e.to_string()))?;
        if key.name == "mirror.path"
            && let Change::Set(value) = &change
            && let Some(folder) = value.as_str()
        {
            // The same checks as `halden mirror set`: a real folder outside the library, marked
            // as the mirror.
            let library = state.config().storage.library_dir.clone();
            let folder = PathBuf::from(folder);
            let prepared = tokio::task::spawn_blocking(move || mirror::prepare(&folder, &library))
                .await
                .map_err(|e| ApiError::from(anyhow::anyhow!(e.to_string())))?
                .map_err(|e| ApiError::validation(format!("{e:#}")))?;
            change = Change::Set(prepared.display().to_string().into());
        }
        checked.push((key, change));
    }
    if needs_password {
        auth.confirm_password(state, current_password).await?;
    }
    Ok(checked)
}

/// Writes the changes to the config file and restarts the server with them.
async fn save(
    state: &AppState,
    auth: &Auth,
    changes: &[(&'static Key, Change)],
) -> Result<Config, ApiError> {
    let Some(path) = state.control().config_path().map(PathBuf::from) else {
        return Err(ApiError::conflict(
            "This server was not started from a config file, so settings can't be changed.",
        ));
    };
    let text = std::fs::read_to_string(&path).map_err(|e| anyhow::anyhow!(e))?;
    let (new_text, config) =
        edit::apply(&text, changes).map_err(|e| ApiError::validation(format!("{e:#}")))?;
    let write_to = path.clone();
    tokio::task::spawn_blocking(move || fsutil::replace_file(&write_to, new_text.as_bytes()))
        .await
        .map_err(|e| anyhow::anyhow!(e.to_string()))?
        .map_err(|e| {
            tracing::error!(error = format!("{e:#}"), "could not save the settings");
            ApiError::new(
                StatusCode::CONFLICT,
                "settings_not_saved",
                "The server may not write its config file. Run `sudo halden setup` on the server once, or change the setting there with `halden config set`.",
            )
        })?;
    let summary: Vec<String> = changes
        .iter()
        .map(|(key, change)| match change {
            Change::Set(value) => format!("{} = {}", key.name, value.to_string().trim()),
            Change::Reset => format!("{} reset", key.name),
        })
        .collect();
    Record::new(Event::SettingsChanged)
        .user(&auth.user.id)
        .device(&auth.device.id)
        .ip(auth.ip)
        .detail(summary.join(", "))
        .write(state.db())
        .await;
    state.control().restart_soon();
    Ok(config)
}

pub async fn change_config(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<ChangeSettings>,
) -> Result<Json<Settings>, ApiError> {
    auth.require_owner()?;
    let changes =
        checked_changes(&state, &auth, &request.changes, request.current_password).await?;
    let config = save(&state, &auth, &changes).await?;
    Ok(Json(settings_of(&state, &config, true)))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Backup {
    name: String,
    size: u64,
    made_at: i64,
}

impl From<database::BackupFile> for Backup {
    fn from(file: database::BackupFile) -> Self {
        Self {
            name: file.name,
            size: file.size,
            made_at: file.made_at,
        }
    }
}

pub async fn backups(State(state): State<AppState>, auth: Auth) -> Result<Json<Value>, ApiError> {
    auth.require_owner()?;
    let list: Vec<Backup> = database::list(state.config())
        .into_iter()
        .map(Backup::from)
        .collect();
    Ok(Json(json!({ "backups": list })))
}

pub async fn back_up_now(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<(StatusCode, Json<Backup>), ApiError> {
    auth.require_owner()?;
    let made = database::make(state.db(), state.config()).await?;
    if let Err(error) = mirror::mirror_backup(state.config(), &made.path).await {
        tracing::warn!(%error, "could not copy the database backup to the mirror");
    }
    Ok((StatusCode::CREATED, Json(made.into())))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MirrorInfo {
    path: Option<String>,
    #[serde(flatten)]
    status: BackupStatus,
}

pub async fn mirror(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<Json<MirrorInfo>, ApiError> {
    auth.require_owner()?;
    let config = state.config();
    Ok(Json(MirrorInfo {
        path: config.mirror.path.as_ref().map(|p| p.display().to_string()),
        status: mirror::compute_status(state.db(), config).await,
    }))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SetMirror {
    path: String,
    current_password: Option<String>,
}

pub async fn set_mirror(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<SetMirror>,
) -> Result<Json<Value>, ApiError> {
    auth.require_owner()?;
    let mut changes = Map::new();
    changes.insert("mirror.path".into(), Value::String(request.path));
    let changes = checked_changes(&state, &auth, &changes, request.current_password).await?;
    let config = save(&state, &auth, &changes).await?;
    let path = config.mirror.path.clone().unwrap_or_default();
    Ok(Json(json!({
        "path": path.display().to_string(),
        "mirrorOnSameDisk": mirror::same_disk(&path, &config.storage.library_dir),
        "restarting": true,
    })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Confirm {
    current_password: Option<String>,
}

pub async fn mirror_off(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<Confirm>,
) -> Result<Json<Value>, ApiError> {
    auth.require_owner()?;
    let mut changes = Map::new();
    changes.insert("mirror.path".into(), Value::Null);
    let changes = checked_changes(&state, &auth, &changes, request.current_password).await?;
    save(&state, &auth, &changes).await?;
    Ok(Json(json!({ "path": null, "restarting": true })))
}

#[derive(Deserialize)]
pub struct JobsQuery {
    /// `failed` (default) or `all`.
    state: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
pub struct JobRow {
    id: i64,
    kind: String,
    asset_id: String,
    state: String,
    attempts: i64,
    last_error: Option<String>,
    run_after: i64,
    updated_at: i64,
}

pub async fn jobs(
    State(state): State<AppState>,
    auth: Auth,
    ApiQuery(query): ApiQuery<JobsQuery>,
) -> Result<Json<Value>, ApiError> {
    auth.require_owner()?;
    let all = match query.state.as_deref() {
        None | Some("failed") => false,
        Some("all") => true,
        Some(other) => {
            return Err(ApiError::validation(format!(
                "state must be failed or all, not {other}"
            )));
        }
    };
    let rows: Vec<JobRow> = sqlx::query_as(
        "SELECT id, kind, asset_id, state, attempts, last_error, run_after, updated_at FROM jobs \
         WHERE ?1 OR state = 'failed' ORDER BY updated_at DESC LIMIT 500",
    )
    .bind(all)
    .fetch_all(state.db().read())
    .await?;
    Ok(Json(
        json!({ "jobs": rows, "counts": jobs::stats(state.db()).await? }),
    ))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Retry {
    /// Jobs to try again; leave out for every failed job.
    ids: Option<Vec<i64>>,
}

pub async fn retry_jobs(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<Retry>,
) -> Result<Json<Value>, ApiError> {
    auth.require_owner()?;
    let now = now_ms();
    let retried = match request.ids {
        None => sqlx::query(
            "UPDATE jobs SET state = 'queued', attempts = 0, run_after = ?1, \
                 last_error = NULL, updated_at = ?1 WHERE state = 'failed'",
        )
        .bind(now)
        .execute(state.db().write())
        .await?
        .rows_affected(),
        Some(ids) => {
            if ids.len() > 1000 {
                return Err(ApiError::validation("At most 1000 jobs at a time."));
            }
            let mut retried = 0;
            let mut tx = state.db().begin().await?;
            for id in ids {
                retried += sqlx::query(
                    "UPDATE jobs SET state = 'queued', attempts = 0, run_after = ?1, \
                     last_error = NULL, updated_at = ?1 WHERE id = ?2 AND state = 'failed'",
                )
                .bind(now)
                .bind(id)
                .execute(&mut *tx)
                .await?
                .rows_affected();
            }
            tx.commit().await?;
            retried
        }
    };
    state.wake_workers();
    Ok(Json(json!({ "retried": retried })))
}

pub async fn doctor(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<Json<doctor::Report>, ApiError> {
    auth.require_owner()?;
    let report = doctor::check(
        state.config(),
        Some(state.db()),
        &doctor::Options {
            config_path: state.control().config_path().map(PathBuf::from),
            config_problem: state.control().config_problem(),
            from_server: true,
        },
    )
    .await;
    Ok(Json(report))
}

pub async fn restart(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    auth.require_owner()?;
    if state.control().config_path().is_none() {
        return Err(ApiError::conflict(
            "This server was not started by `halden serve`, so it can't restart itself.",
        ));
    }
    Record::new(Event::ServerRestarted)
        .user(&auth.user.id)
        .device(&auth.device.id)
        .ip(auth.ip)
        .write(state.db())
        .await;
    state.control().restart_soon();
    Ok((StatusCode::ACCEPTED, Json(json!({ "restarting": true }))))
}

/// Is root's updater installed (`halden-update-request.path`, from the install script)?
fn updater_installed() -> bool {
    #[cfg(debug_assertions)]
    if std::env::var_os("HALDEN_UPDATER_INSTALLED").is_some() {
        return true;
    }
    [
        "/etc/systemd/system",
        "/lib/systemd/system",
        "/usr/lib/systemd/system",
    ]
    .iter()
    .any(|dir| {
        std::path::Path::new(dir)
            .join("halden-update-request.path")
            .exists()
    })
}

fn in_docker() -> bool {
    std::env::var_os("HALDEN_IN_DOCKER").is_some()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    /// The version that answers right now.
    running: &'static str,
    #[serde(flatten)]
    status: update::UpdateStatus,
    in_docker: bool,
    /// Whether "Install" in the app can work here.
    can_install: bool,
    /// Why not, when it can't.
    #[serde(skip_serializing_if = "Option::is_none")]
    install_hint: Option<&'static str>,
}

fn update_info(state: &AppState) -> UpdateInfo {
    let has_key = update::Source::official().key.is_some();
    let hint = if in_docker() {
        Some("Update the container: docker compose pull && docker compose up -d")
    } else if !has_key {
        Some(
            "This build installs no updates (it has no release key). Install the new version by hand.",
        )
    } else if !updater_installed() {
        Some(
            "The update helper is not installed. Run the install script on the server again: curl -fsSL https://raw.githubusercontent.com/lucaskleinsteuber/Halden/main/packaging/linux/get-halden.sh | sudo bash",
        )
    } else {
        None
    };
    UpdateInfo {
        running: VERSION,
        status: update::status::read(state.config()),
        in_docker: in_docker(),
        can_install: hint.is_none(),
        install_hint: hint,
    }
}

pub async fn update_status(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<Json<UpdateInfo>, ApiError> {
    auth.require_owner()?;
    Ok(Json(update_info(&state)))
}

/// Looks for a new version now (the server does this once a day by itself).
pub async fn check_for_update(
    State(state): State<AppState>,
    auth: Auth,
) -> Result<Json<UpdateInfo>, ApiError> {
    auth.require_owner()?;
    let config = state.config().clone();
    let checked = tokio::time::timeout(
        std::time::Duration::from_secs(25),
        update::check(&update::Source::official(), config.update.beta),
    )
    .await
    .unwrap_or_else(|_| Err(anyhow::anyhow!("GitHub did not answer in time")));
    match checked {
        Ok(found) => {
            update::install::checked(&config, found.as_ref());
        }
        Err(error) => update::install::report(
            &config,
            update::UpdateState::Failed,
            VERSION,
            None,
            Some(format!("could not look for a new version: {error:#}")),
        ),
    }
    Ok(Json(update_info(&state)))
}

/// Asks root's updater to install the newest version: leaves a request file, which systemd's
/// `halden-update-request.path` notices. The request carries nothing but "install".
pub async fn install_update(
    State(state): State<AppState>,
    auth: Auth,
    ApiJson(request): ApiJson<Confirm>,
) -> Result<(StatusCode, Json<UpdateInfo>), ApiError> {
    auth.require_owner()?;
    let info = update_info(&state);
    if let Some(hint) = info.install_hint {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "update_unavailable",
            hint,
        ));
    }
    if info.status.state != update::UpdateState::Available {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "no_update",
            "There is no newer version to install. Look for one first.",
        ));
    }
    auth.confirm_password(&state, request.current_password)
        .await?;
    let path = update::status::install_request(state.config());
    fsutil::write_atomic(&path, b"install\n", 0o600)?;
    Record::new(Event::UpdateRequested)
        .user(&auth.user.id)
        .device(&auth.device.id)
        .ip(auth.ip)
        .detail(format!(
            "{} to {}",
            VERSION,
            info.status.latest.as_deref().unwrap_or("?")
        ))
        .write(state.db())
        .await;
    Ok((StatusCode::ACCEPTED, Json(update_info(&state))))
}
