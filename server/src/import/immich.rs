//! Immich: the photos of one Immich account, through Immich's own API with an API key
//! (Account Settings › API Keys in Immich). Originals as they were uploaded, Live Photos with
//! their video, descriptions, places and times, albums, and the favourites as an album. What is
//! in Immich's trash stays there.

use std::{collections::HashMap, path::Path};

use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;

use super::{Fetch, Item, mime_of};

/// The album the favourites go into.
pub const FAVOURITES: &str = "Favourites (Immich)";

pub struct Immich {
    http: reqwest::Client,
    base: String,
    key: String,
}

impl Immich {
    /// `url` is the address of the Immich server, as in the browser.
    pub fn new(url: &str, key: &str) -> Result<Self> {
        let base = format!("{}/api", url.trim_end_matches('/').trim_end_matches("/api"));
        let http = crate::update::client().context("could not set up the connection to Immich")?;
        Ok(Self {
            http,
            base,
            key: key.to_string(),
        })
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value> {
        let mut request = self
            .http
            .request(method, format!("{}/{path}", self.base))
            .header("x-api-key", &self.key)
            .header("accept", "application/json");
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request
            .send()
            .await
            .context("Immich doesn't answer at that address")?;
        if response.status() == reqwest::StatusCode::UNAUTHORIZED {
            bail!("Immich doesn't accept this API key");
        }
        Ok(response.error_for_status()?.json().await?)
    }

    /// Every photo and video of the account, with its albums.
    pub async fn items(&self) -> Result<Vec<Item>> {
        // Which album each asset is in.
        let mut albums: HashMap<String, Vec<String>> = HashMap::new();
        let list = self.call(reqwest::Method::GET, "albums", None).await?;
        for album in list.as_array().into_iter().flatten() {
            let (Some(id), Some(name)) = (album["id"].as_str(), album["albumName"].as_str()) else {
                continue;
            };
            let full = self
                .call(reqwest::Method::GET, &format!("albums/{id}"), None)
                .await?;
            for asset in full["assets"].as_array().into_iter().flatten() {
                if let Some(asset) = asset["id"].as_str() {
                    albums
                        .entry(asset.to_string())
                        .or_default()
                        .push(name.to_string());
                }
            }
        }

        let mut assets = Vec::new();
        let mut page = json!(1);
        loop {
            let found = self
                .call(
                    reqwest::Method::POST,
                    "search/metadata",
                    Some(json!({ "page": page, "size": 250, "withExif": true })),
                )
                .await?;
            assets.extend(
                found["assets"]["items"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .cloned(),
            );
            match &found["assets"]["nextPage"] {
                Value::Null => break,
                next => {
                    page = next
                        .as_str()
                        .map_or(next.clone(), |n| json!(n.parse::<u64>().unwrap_or(0)))
                }
            }
            if page == json!(0) {
                break;
            }
        }
        // The video halves of Live Photos come with their photo.
        let live_videos: std::collections::HashSet<String> = assets
            .iter()
            .filter_map(|a| a["livePhotoVideoId"].as_str().map(str::to_string))
            .collect();
        let names: HashMap<String, String> = assets
            .iter()
            .filter_map(|a| {
                Some((
                    a["id"].as_str()?.to_string(),
                    a["originalFileName"].as_str()?.to_string(),
                ))
            })
            .collect();

        let mut items = Vec::new();
        for asset in &assets {
            let Some(id) = asset["id"].as_str() else {
                continue;
            };
            if live_videos.contains(id) || asset["isTrashed"] == true {
                continue;
            }
            let name = asset["originalFileName"]
                .as_str()
                .unwrap_or("photo")
                .to_string();
            let Some(mime) = asset["originalMimeType"]
                .as_str()
                .filter(|m| {
                    mime_of(&format!("x.{}", extension(m))).is_some() || mime_of(&name).is_some()
                })
                .map(str::to_string)
                .or_else(|| mime_of(&name).map(str::to_string))
            else {
                continue;
            };
            let exif = &asset["exifInfo"];
            let mut item = Item {
                key: format!("immich:{id}"),
                file_name: name,
                mime,
                taken_at: asset["fileCreatedAt"]
                    .as_str()
                    .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
                    .map(|t| t.timestamp_millis()),
                location: match (exif["latitude"].as_f64(), exif["longitude"].as_f64()) {
                    (Some(latitude), Some(longitude)) => Some((latitude, longitude, None)),
                    _ => None,
                },
                description: exif["description"].as_str().map(str::to_string),
                albums: albums.get(id).cloned().unwrap_or_default(),
                paired: asset["livePhotoVideoId"].as_str().map(|video| {
                    (
                        format!("immich:{video}"),
                        names
                            .get(video)
                            .cloned()
                            .unwrap_or_else(|| "live.mov".into()),
                    )
                }),
            };
            if asset["isFavorite"] == true {
                item.albums.push(FAVOURITES.to_string());
            }
            items.push(item);
        }
        Ok(items)
    }
}

/// The usual file extension of a MIME type, to recognise what Halden takes.
fn extension(mime: &str) -> &str {
    match mime {
        "image/jpeg" => "jpg",
        "image/heic" => "heic",
        "image/heif" => "heif",
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/tiff" => "tiff",
        "image/avif" => "avif",
        "image/x-adobe-dng" | "image/dng" => "dng",
        "video/quicktime" => "mov",
        "video/mp4" => "mp4",
        "video/x-matroska" => "mkv",
        "video/webm" => "webm",
        _ => "",
    }
}

impl Fetch for Immich {
    async fn fetch(&mut self, key: &str, path: &Path) -> Result<()> {
        let id = key.strip_prefix("immich:").unwrap_or(key);
        let response = self
            .http
            .get(format!("{}/assets/{id}/original", self.base))
            .header("x-api-key", &self.key)
            .send()
            .await?
            .error_for_status()?;
        let mut file = tokio::fs::File::create(path).await?;
        let mut body = response.bytes_stream();
        while let Some(chunk) = body.next().await {
            file.write_all(&chunk?).await?;
        }
        file.sync_all().await?;
        Ok(())
    }
}
