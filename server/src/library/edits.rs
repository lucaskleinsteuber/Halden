//! Corrections (time, place, title, description) with their history, the full metadata of one
//! asset, and location suggestions from neighbouring photos. Corrections never touch the
//! original values; they are stored next to them, and every change is kept in `asset_edits`.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::SqliteConnection;

use crate::{
    db::{Db, now_ms},
    library::assets::{self, Asset, AssetRow, Location, asset_columns},
};

/// A location set by hand or taken from a suggestion.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NewLocation {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude: Option<f64>,
    /// True when it came from a suggestion: shown as "estimated".
    #[serde(default)]
    pub estimated: bool,
}

impl NewLocation {
    pub fn check(&self) -> Result<(), String> {
        if !(-90.0..=90.0).contains(&self.latitude)
            || !(-180.0..=180.0).contains(&self.longitude)
            || self.altitude.is_some_and(|a| !a.is_finite())
        {
            return Err("The location is outside the valid range.".into());
        }
        Ok(())
    }
}

/// The slow part of a slow-motion video: from and to (milliseconds into the video) and how slow
/// (0.125 is eight times slower).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Playback {
    pub slow_from_ms: i64,
    pub slow_to_ms: i64,
    pub rate: f64,
}

impl Playback {
    pub fn check(&self) -> Result<(), String> {
        if self.slow_from_ms < 0
            || self.slow_to_ms <= self.slow_from_ms
            || !(0.01..=1.0).contains(&self.rate)
        {
            return Err(
                "playback needs 0 <= slowFromMs < slowToMs and a rate between 0.01 and 1.".into(),
            );
        }
        Ok(())
    }
}

/// What to change. A missing field stays as it is.
#[derive(Debug, Default)]
pub struct Correction {
    pub taken_at: Option<i64>,
    pub tz_offset_min: Option<i32>,
    /// `Some(None)`: remove the location (the original stays stored, but is not shown).
    pub location: Option<Option<NewLocation>>,
    pub title: Option<Option<String>>,
    pub description: Option<Option<String>>,
    /// `Some(None)`: play as recorded.
    pub playback: Option<Option<Playback>>,
    /// Drop corrections and show the original again: `takenAt` and/or `location`.
    pub restore: Vec<String>,
}

impl Correction {
    pub fn check(&self) -> Result<(), String> {
        if let Some(Some(location)) = &self.location {
            location.check()?;
        }
        if let Some(Some(playback)) = &self.playback {
            playback.check()?;
        }
        if let Some(taken) = self.taken_at
            && !(super::EARLIEST_TAKEN_AT..=super::LATEST_TAKEN_AT).contains(&taken)
        {
            return Err("takenAt must be between 1900 and 2200.".into());
        }
        if let Some(offset) = self.tz_offset_min
            && !(-18 * 60..=18 * 60).contains(&offset)
        {
            return Err("timeZoneOffsetMinutes must be between -1080 and 1080.".into());
        }
        for text in [&self.title, &self.description]
            .into_iter()
            .flatten()
            .flatten()
        {
            if text.chars().count() > 2000 {
                return Err("Titles and descriptions may have at most 2000 characters.".into());
            }
        }
        if let Some(field) = self
            .restore
            .iter()
            .find(|f| !matches!(f.as_str(), "takenAt" | "location"))
        {
            return Err(format!(
                "{field} can't be restored; only takenAt and location."
            ));
        }
        Ok(())
    }

    fn is_empty(&self) -> bool {
        self.taken_at.is_none()
            && self.tz_offset_min.is_none()
            && self.location.is_none()
            && self.title.is_none()
            && self.description.is_none()
            && self.playback.is_none()
            && self.restore.is_empty()
    }
}

fn time_json(at: i64, offset: Option<i64>) -> Value {
    json!({ "takenAt": at, "timeZoneOffsetMinutes": offset })
}

fn location_json(location: Option<Location>) -> Value {
    serde_json::to_value(location).unwrap_or(Value::Null)
}

async fn record(
    tx: &mut SqliteConnection,
    asset_id: &str,
    device_id: Option<&str>,
    field: &str,
    old: Value,
    new: Value,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO asset_edits (asset_id, device_id, at, field, old_json, new_json) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(asset_id)
    .bind(device_id)
    .bind(now_ms())
    .bind(field)
    .bind(old.to_string())
    .bind(new.to_string())
    .execute(&mut *tx)
    .await?;
    Ok(())
}

/// Applies a correction to an asset inside a write transaction.
async fn apply(
    tx: &mut SqliteConnection,
    row: &AssetRow,
    device_id: Option<&str>,
    correction: &Correction,
) -> Result<(), sqlx::Error> {
    let id = row.id.as_str();
    let effective_time = |row: &AssetRow| {
        (
            row.edit_taken_at.unwrap_or(row.taken_at),
            row.edit_tz_offset_min.or(row.tz_offset_min),
        )
    };

    if correction.restore.iter().any(|f| f == "takenAt") && row.edit_taken_at.is_some() {
        let (at, offset) = effective_time(row);
        sqlx::query(
            "UPDATE assets SET edit_taken_at = NULL, edit_tz_offset_min = NULL WHERE id = ?",
        )
        .bind(id)
        .execute(&mut *tx)
        .await?;
        record(
            tx,
            id,
            device_id,
            "takenAt",
            time_json(at, offset),
            time_json(row.taken_at, row.tz_offset_min),
        )
        .await?;
    }
    if correction.taken_at.is_some() || correction.tz_offset_min.is_some() {
        let (old_at, old_offset) = effective_time(row);
        let at = correction.taken_at.unwrap_or(old_at);
        let offset = correction.tz_offset_min.map(i64::from).or(old_offset);
        sqlx::query("UPDATE assets SET edit_taken_at = ?, edit_tz_offset_min = ? WHERE id = ?")
            .bind(at)
            .bind(offset)
            .bind(id)
            .execute(&mut *tx)
            .await?;
        record(
            tx,
            id,
            device_id,
            "takenAt",
            time_json(old_at, old_offset),
            time_json(at, offset),
        )
        .await?;
    }

    if correction.restore.iter().any(|f| f == "location") {
        let old = row.effective_location();
        sqlx::query(
            "UPDATE assets SET edit_latitude = NULL, edit_longitude = NULL, edit_altitude = NULL, \
                 edit_location_source = NULL, location_hidden = 0 WHERE id = ?",
        )
        .bind(id)
        .execute(&mut *tx)
        .await?;
        record(
            tx,
            id,
            device_id,
            "location",
            location_json(old),
            location_json(row.original_location()),
        )
        .await?;
    }
    match &correction.location {
        Some(Some(new)) => {
            let source = if new.estimated { "estimated" } else { "manual" };
            sqlx::query(
                "UPDATE assets SET edit_latitude = ?, edit_longitude = ?, edit_altitude = ?, \
                     edit_location_source = ?, location_hidden = 0 WHERE id = ?",
            )
            .bind(new.latitude)
            .bind(new.longitude)
            .bind(new.altitude)
            .bind(source)
            .bind(id)
            .execute(&mut *tx)
            .await?;
            let new_json = json!({ "latitude": new.latitude, "longitude": new.longitude,
                                   "altitude": new.altitude, "source": source });
            record(
                tx,
                id,
                device_id,
                "location",
                location_json(row.effective_location()),
                new_json,
            )
            .await?;
        }
        Some(None) => {
            sqlx::query(
                "UPDATE assets SET edit_latitude = NULL, edit_longitude = NULL, \
                     edit_altitude = NULL, edit_location_source = NULL, location_hidden = 1 \
                 WHERE id = ?",
            )
            .bind(id)
            .execute(&mut *tx)
            .await?;
            record(
                tx,
                id,
                device_id,
                "location",
                location_json(row.effective_location()),
                Value::Null,
            )
            .await?;
        }
        None => {}
    }

    for (field, column, value) in [
        ("title", "title", &correction.title),
        ("description", "description", &correction.description),
    ] {
        if let Some(value) = value {
            let value = value.as_ref().map(|v| v.trim()).filter(|v| !v.is_empty());
            let query = if column == "title" {
                "UPDATE assets SET title = ? WHERE id = ?"
            } else {
                "UPDATE assets SET description = ? WHERE id = ?"
            };
            sqlx::query(query)
                .bind(value)
                .bind(id)
                .execute(&mut *tx)
                .await?;
            record(tx, id, device_id, field, Value::Null, json!(value)).await?;
        }
    }

    if let Some(playback) = &correction.playback {
        let new = playback.as_ref().map(|p| json!(p));
        sqlx::query("UPDATE assets SET playback_json = ? WHERE id = ?")
            .bind(new.as_ref().map(Value::to_string))
            .bind(id)
            .execute(&mut *tx)
            .await?;
        let old = row
            .playback_json
            .as_deref()
            .and_then(|json| serde_json::from_str(json).ok())
            .unwrap_or(Value::Null);
        record(
            tx,
            id,
            device_id,
            "playback",
            old,
            new.unwrap_or(Value::Null),
        )
        .await?;
    }
    assets::touch(tx, id).await?;
    Ok(())
}

/// Corrects one asset of the account. `None` if it doesn't exist (for this account).
pub async fn correct(
    db: &Db,
    user_id: &str,
    asset_id: &str,
    device_id: Option<&str>,
    correction: &Correction,
) -> Result<Option<Asset>, sqlx::Error> {
    if correction.is_empty() {
        return assets::get(db.read(), user_id, asset_id).await;
    }
    let mut tx = db.begin().await?;
    // A tombstone keeps nothing about the photo, so it can't be corrected either.
    let Some(row) = assets::row(&mut *tx, user_id, asset_id)
        .await?
        .filter(|row| !row.is_deleted())
    else {
        return Ok(None);
    };
    apply(&mut tx, &row, device_id, correction).await?;
    tx.commit().await?;
    assets::get(db.read(), user_id, asset_id).await
}

/// Sets the same correction on many assets in one transaction (e.g. a place for twenty photos
/// without one). Returns how many were changed; unknown ids are skipped.
pub async fn correct_many(
    db: &Db,
    user_id: &str,
    asset_ids: &[String],
    device_id: Option<&str>,
    correction: &Correction,
) -> Result<u64, sqlx::Error> {
    let mut tx = db.begin().await?;
    let mut changed = 0;
    for asset_id in asset_ids {
        if let Some(row) = assets::row(&mut *tx, user_id, asset_id)
            .await?
            .filter(|row| !row.is_deleted())
        {
            apply(&mut tx, &row, device_id, correction).await?;
            changed += 1;
        }
    }
    tx.commit().await?;
    Ok(changed)
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Original {
    pub taken_at: i64,
    #[serde(rename = "timeZoneOffsetMinutes")]
    pub tz_offset_min: Option<i64>,
    pub taken_at_source: String,
    pub location: Option<Location>,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
pub struct Edit {
    pub at: i64,
    pub field: String,
    pub device_id: Option<String>,
    #[serde(skip)]
    old_json: Option<String>,
    #[serde(skip)]
    new_json: Option<String>,
    #[sqlx(skip)]
    pub old: Value,
    #[sqlx(skip)]
    pub new: Value,
}

/// Everything about one asset, for the info view.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetDetail {
    #[serde(flatten)]
    pub asset: Asset,
    /// The values as recorded, before corrections.
    pub original: Original,
    /// Fields read from the file (EXIF / QuickTime).
    pub exif: Value,
    /// What the device sent with the upload.
    pub client: Value,
    pub edits: Vec<Edit>,
}

pub async fn detail(
    db: &Db,
    user_id: &str,
    asset_id: &str,
) -> Result<Option<AssetDetail>, sqlx::Error> {
    let mut tx = db.read().begin().await?;
    let Some(row) = assets::row(&mut *tx, user_id, asset_id).await? else {
        return Ok(None);
    };
    let (exif, client): (Option<String>, Option<String>) =
        sqlx::query_as("SELECT exif_json, client_json FROM assets WHERE id = ?")
            .bind(asset_id)
            .fetch_one(&mut *tx)
            .await?;
    let mut edits = sqlx::query_as::<_, Edit>(
        "SELECT at, field, device_id, old_json, new_json FROM asset_edits \
         WHERE asset_id = ? ORDER BY id",
    )
    .bind(asset_id)
    .fetch_all(&mut *tx)
    .await?;
    for edit in &mut edits {
        let parse = |text: &Option<String>| {
            text.as_deref()
                .and_then(|t| serde_json::from_str(t).ok())
                .unwrap_or(Value::Null)
        };
        edit.old = parse(&edit.old_json);
        edit.new = parse(&edit.new_json);
    }
    let original = Original {
        taken_at: row.taken_at,
        tz_offset_min: row.tz_offset_min,
        taken_at_source: row.taken_at_source.clone(),
        location: row.original_location(),
    };
    let mut assets = assets::with_files(&mut *tx, vec![row]).await?;
    tx.commit().await?;
    let parse = |text: Option<String>| {
        text.and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null)
    };
    Ok(Some(AssetDetail {
        asset: assets.remove(0),
        original,
        exif: parse(exif),
        client: parse(client),
        edits,
    }))
}

/// A place for a photo without one, taken from the nearest photo in time that has one.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Suggestion {
    pub latitude: f64,
    pub longitude: f64,
    pub from_asset_id: String,
    pub minutes_apart: i64,
}

macro_rules! concat_candidate {
    ($order:literal) => {
        concat!(
            "SELECT id, coalesce(edit_latitude, latitude), coalesce(edit_longitude, longitude), \
                 taken_at FROM assets \
             WHERE user_id = ?1 AND taken_at BETWEEN ?2 AND ?3 AND id <> ?4 \
               AND location_hidden = 0 AND deleted_at IS NULL \
               AND (edit_latitude IS NOT NULL OR latitude IS NOT NULL) ",
            $order
        )
    };
}

/// The nearest photo in time (before or after, within `window_ms`) that has a location.
/// Two lookups on the `(user_id, taken_at)` index.
pub async fn suggest(
    db: &Db,
    user_id: &str,
    asset_id: &str,
    taken_at: i64,
    window_ms: i64,
) -> Result<Option<Suggestion>, sqlx::Error> {
    let before: Option<(String, f64, f64, i64)> =
        sqlx::query_as(concat_candidate!("ORDER BY taken_at DESC LIMIT 1"))
            .bind(user_id)
            .bind(taken_at - window_ms)
            .bind(taken_at)
            .bind(asset_id)
            .fetch_optional(db.read())
            .await?;
    let after: Option<(String, f64, f64, i64)> =
        sqlx::query_as(concat_candidate!("ORDER BY taken_at ASC LIMIT 1"))
            .bind(user_id)
            .bind(taken_at)
            .bind(taken_at + window_ms)
            .bind(asset_id)
            .fetch_optional(db.read())
            .await?;
    let nearest = [before, after]
        .into_iter()
        .flatten()
        .min_by_key(|(_, _, _, at)| (at - taken_at).abs());
    Ok(nearest.map(|(from, latitude, longitude, at)| Suggestion {
        latitude,
        longitude,
        from_asset_id: from,
        minutes_apart: (at - taken_at).abs() / 60_000,
    }))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WithoutLocation {
    #[serde(flatten)]
    pub asset: Asset,
    pub suggestion: Option<Suggestion>,
}

/// Photos without a location (newest first, before `before` if given), each with a suggestion.
pub async fn without_location(
    db: &Db,
    user_id: &str,
    before: Option<i64>,
    limit: u32,
    window_ms: i64,
) -> Result<Vec<WithoutLocation>, sqlx::Error> {
    let rows = sqlx::query_as::<_, AssetRow>(concat!(
        "SELECT ",
        asset_columns!(),
        " FROM assets a WHERE a.user_id = ?1 AND a.trashed_at IS NULL AND a.deleted_at IS NULL \
           AND (a.location_hidden = 1 OR (a.edit_latitude IS NULL AND a.latitude IS NULL)) \
           AND (?2 IS NULL OR a.taken_at < ?2) \
         ORDER BY a.taken_at DESC LIMIT ?3"
    ))
    .bind(user_id)
    .bind(before)
    .bind(i64::from(limit.clamp(1, 1000)))
    .fetch_all(db.read())
    .await?;
    let times: Vec<(String, i64)> = rows.iter().map(|r| (r.id.clone(), r.taken_at)).collect();
    let assets = assets::with_files(db.read(), rows).await?;
    let mut out = Vec::with_capacity(assets.len());
    for (asset, (id, taken_at)) in assets.into_iter().zip(times) {
        let suggestion = suggest(db, user_id, &id, taken_at, window_ms).await?;
        out.push(WithoutLocation { asset, suggestion });
    }
    Ok(out)
}
