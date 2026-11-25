//! Bringing a photo library from elsewhere (Google Takeout, Immich) into an account.
//!
//! The import talks to the running server like a phone does: over HTTPS to this computer, with
//! the server's own certificate pinned, as a device of its own ("Import (Google Takeout)"), so
//! everything an upload does happens here too: duplicates are found by their content, files
//! get their names and folders, thumbnails and small copies are made in the background. What
//! the files don't say themselves (the time and place Google kept, descriptions) is set as a
//! correction afterwards; folders and albums become albums.
//!
//! An import can be stopped and started again: a journal next to the database remembers what
//! went in, and a file interrupted halfway continues where it stopped.

pub mod immich;
pub mod takeout;

use std::{
    collections::HashMap,
    io::Write,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;

use crate::{accounts, config::Config, tls};

/// One photo or video to bring in.
#[derive(Debug, Clone, Default)]
pub struct Item {
    /// Where it comes from, the same every time (for the journal).
    pub key: String,
    pub file_name: String,
    pub mime: String,
    /// When it was taken (UTC milliseconds), if the source knows; used only when the file
    /// itself doesn't say.
    pub taken_at: Option<i64>,
    /// Where (latitude, longitude, altitude), if the source knows; used only when the file
    /// doesn't say.
    pub location: Option<(f64, f64, Option<f64>)>,
    pub description: Option<String>,
    /// The albums it is in.
    pub albums: Vec<String>,
    /// A Live Photo's video: its key, file name and type.
    pub paired: Option<(String, String)>,
}

/// Getting an item's file (and its Live Photo video) onto the disk.
pub trait Fetch {
    /// Writes the file of `key` to `path`.
    fn fetch(&mut self, key: &str, path: &Path) -> impl Future<Output = Result<()>> + Send;
}

/// What happened to one item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Brought in.
    Added,
    /// It was in the library already (the same content).
    AlreadyThere,
    /// Brought in by an earlier run.
    DoneBefore,
}

/// The type of a file, by its name, for what Halden takes.
pub fn mime_of(name: &str) -> Option<&'static str> {
    let extension = Path::new(name).extension()?.to_str()?.to_ascii_lowercase();
    Some(match extension.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "tif" | "tiff" => "image/tiff",
        "avif" => "image/avif",
        "dng" => "image/x-adobe-dng",
        "cr3" => "image/x-canon-cr3",
        "raf" => "image/x-fuji-raf",
        "mov" => "video/quicktime",
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        _ => return None,
    })
}

/// Remembers what went in: one line per item (`key`, the asset id, done or started), so a new
/// run skips what is done and continues what was started with the same asset id.
struct Journal {
    file: std::fs::File,
    entries: HashMap<String, (String, bool)>,
}

#[derive(Serialize, Deserialize)]
struct JournalLine {
    key: String,
    asset: String,
    done: bool,
}

impl Journal {
    fn open(path: &Path) -> Result<Self> {
        let mut entries = HashMap::new();
        if let Ok(text) = std::fs::read_to_string(path) {
            for line in text.lines() {
                if let Ok(entry) = serde_json::from_str::<JournalLine>(line) {
                    entries.insert(entry.key, (entry.asset, entry.done));
                }
            }
        }
        if let Some(folder) = path.parent() {
            std::fs::create_dir_all(folder)?;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .with_context(|| format!("could not open the import journal {}", path.display()))?;
        Ok(Self { file, entries })
    }

    fn note(&mut self, key: &str, asset: &str, done: bool) -> Result<()> {
        let line = serde_json::to_string(&JournalLine {
            key: key.into(),
            asset: asset.into(),
            done,
        })?;
        writeln!(self.file, "{line}")?;
        self.file.flush()?;
        self.entries.insert(key.into(), (asset.into(), done));
        Ok(())
    }
}

/// The connection to the running server, as the import's own device.
pub struct Importer {
    http: reqwest::Client,
    base: String,
    token: String,
    journal: Journal,
    scratch: PathBuf,
    albums: HashMap<String, String>,
    pub dry_run: bool,
}

impl Importer {
    /// Signs in to the server on this computer as a device of `username`'s account, named after
    /// `source` ("Google Takeout"). The journal is kept as `journal_name` in the data folder.
    pub async fn connect(
        config: &Config,
        pool: &crate::db::Db,
        username: &str,
        source: &str,
        journal_name: &str,
        dry_run: bool,
    ) -> Result<Self> {
        let port = config.server.port;
        if !crate::cli::is_listening(port) {
            bail!("the server isn't running; start it first (sudo systemctl start halden)");
        }
        let user = crate::cli::user::find(pool, username).await?;
        if user.disabled {
            bail!("the account {username} is disabled");
        }
        let fingerprint = tls::identity_fingerprint(config)
            .context("could not read the certificate (try with sudo)")?;
        let http = tls::pinned_client_for_transfers(fingerprint)?;
        let base = format!("https://127.0.0.1:{port}/api/v1");
        let code = accounts::create_pairing_code(pool, &user.id, None).await?;
        let paired: Value = http
            .post(format!("{base}/auth/pair"))
            .json(&json!({
                "code": code.code,
                "device": { "name": format!("Import ({source})"), "platform": "cli",
                            "installationId": format!("import-{journal_name}") }
            }))
            .send()
            .await
            .context("the server didn't answer")?
            .error_for_status()
            .context("the server didn't let the import in")?
            .json()
            .await?;
        let token = paired["token"]
            .as_str()
            .context("the server gave no token")?
            .to_string();
        let journal = Journal::open(
            &config
                .storage
                .data_dir
                .join("imports")
                .join(format!("{journal_name}.jsonl")),
        )?;
        let scratch = config.storage.data_dir.join("tmp");
        std::fs::create_dir_all(&scratch)?;
        let mut importer = Self {
            http,
            base,
            token,
            journal,
            scratch,
            albums: HashMap::new(),
            dry_run,
        };
        importer.load_albums().await?;
        Ok(importer)
    }

    async fn load_albums(&mut self) -> Result<()> {
        let list: Value = self.get("albums").await?;
        for album in list["albums"].as_array().into_iter().flatten() {
            if let (Some(name), Some(id)) = (album["name"].as_str(), album["id"].as_str()) {
                self.albums.insert(name.to_string(), id.to_string());
            }
        }
        Ok(())
    }

    async fn get(&self, path: &str) -> Result<Value> {
        Ok(self
            .http
            .get(format!("{}/{path}", self.base))
            .bearer_auth(&self.token)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?)
    }

    async fn send(&self, method: reqwest::Method, path: &str, body: Value) -> Result<Value> {
        let response = self
            .http
            .request(method, format!("{}/{path}", self.base))
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await?;
        let status = response.status();
        let value: Value = response.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            bail!("the server said {status}: {}", value["message"]);
        }
        Ok(value)
    }

    /// Whether an earlier run brought this item in.
    pub fn done_before(&self, key: &str) -> bool {
        self.journal.entries.get(key).is_some_and(|(_, done)| *done)
    }

    /// Brings one item in: its file (and Live Photo video) up, then what the file doesn't say,
    /// then into its albums.
    pub async fn bring(&mut self, item: &Item, fetch: &mut impl Fetch) -> Result<Outcome> {
        if self.done_before(&item.key) {
            return Ok(Outcome::DoneBefore);
        }
        if self.dry_run {
            return Ok(Outcome::Added);
        }
        let asset_id = self
            .journal
            .entries
            .get(&item.key)
            .map(|(asset, _)| asset.clone())
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        self.journal.note(&item.key, &asset_id, false)?;

        let file = self.scratch.join(format!("import-{asset_id}"));
        fetch.fetch(&item.key, &file).await?;
        let metadata = json!({ "originalFilename": item.file_name, "source": "import" });
        let answer = self
            .upload(&asset_id, "original", &file, &item.mime, metadata)
            .await;
        let _ = tokio::fs::remove_file(&file).await;
        let (outcome, id) = match answer? {
            Uploaded::Stored => (Outcome::Added, asset_id.clone()),
            Uploaded::Duplicate(existing) => (Outcome::AlreadyThere, existing),
        };

        if outcome == Outcome::Added {
            if let Some((paired_key, paired_name)) = &item.paired
                && let Some(paired_mime) = mime_of(paired_name)
            {
                let video = self.scratch.join(format!("import-{asset_id}-live"));
                fetch.fetch(paired_key, &video).await?;
                let sent = self
                    .upload(&id, "paired_video", &video, paired_mime, json!({}))
                    .await;
                let _ = tokio::fs::remove_file(&video).await;
                // A Live Photo without its video is still the photo.
                if let Err(error) = sent {
                    eprintln!("  the video of {} didn't go in: {error:#}", item.file_name);
                }
            }
            self.correct(&id, item).await?;
        }
        for album in &item.albums {
            let album_id = self.album(album).await?;
            self.send(
                reqwest::Method::POST,
                &format!("albums/{album_id}/assets"),
                json!({ "assetIds": [id] }),
            )
            .await?;
        }
        self.journal.note(&item.key, &asset_id, true)?;
        Ok(outcome)
    }

    /// The time, place and description the source knew, where the file itself says nothing.
    async fn correct(&self, id: &str, item: &Item) -> Result<()> {
        let asset = self.get(&format!("assets/{id}")).await?;
        let mut correction = serde_json::Map::new();
        if asset["takenAtSource"] == "upload"
            && let Some(taken) = item.taken_at
        {
            correction.insert("takenAt".into(), json!(taken));
        }
        if asset["location"].is_null()
            && let Some((latitude, longitude, altitude)) = item.location
        {
            correction.insert(
                "location".into(),
                json!({ "latitude": latitude, "longitude": longitude, "altitude": altitude }),
            );
        }
        if let Some(description) = item.description.as_ref().filter(|d| !d.trim().is_empty()) {
            correction.insert("description".into(), json!(description));
        }
        if !correction.is_empty() {
            self.send(
                reqwest::Method::PATCH,
                &format!("assets/{id}"),
                Value::Object(correction),
            )
            .await?;
        }
        Ok(())
    }

    /// The album of that name, made the first time.
    async fn album(&mut self, name: &str) -> Result<String> {
        if let Some(id) = self.albums.get(name) {
            return Ok(id.clone());
        }
        let made = self
            .send(reqwest::Method::POST, "albums", json!({ "name": name }))
            .await?;
        let id = made["id"].as_str().context("no album id")?.to_string();
        self.albums.insert(name.to_string(), id.clone());
        Ok(id)
    }

    /// One file up, resumable: announced, then sent from where the server stands.
    async fn upload(
        &self,
        asset_id: &str,
        role: &str,
        file: &Path,
        mime: &str,
        metadata: Value,
    ) -> Result<Uploaded> {
        let (sha256, size) = hash(file).await?;
        let announced = self
            .send(
                reqwest::Method::POST,
                "uploads",
                json!({ "assetId": asset_id, "role": role, "size": size, "sha256": sha256,
                        "mimeType": mime, "metadata": metadata }),
            )
            .await?;
        match announced["state"].as_str() {
            Some("completed") => return Ok(Uploaded::Stored),
            Some("duplicate") => {
                let existing = announced["existingAssetId"]
                    .as_str()
                    .context("no existing asset id")?;
                return Ok(Uploaded::Duplicate(existing.to_string()));
            }
            _ => {}
        }
        let upload = announced["uploadId"]
            .as_str()
            .context("no upload id")?
            .to_string();
        let offset = announced["offset"].as_u64().unwrap_or(0);
        let mut reader = tokio::fs::File::open(file).await?;
        tokio::io::AsyncSeekExt::seek(&mut reader, std::io::SeekFrom::Start(offset)).await?;
        let body = reqwest::Body::wrap_stream(tokio_util::io::ReaderStream::new(reader));
        let sent = self
            .http
            .patch(format!("{}/uploads/{upload}", self.base))
            .bearer_auth(&self.token)
            .header("Upload-Offset", offset.to_string())
            .header("Content-Type", "application/offset+octet-stream")
            .header("Content-Length", (size - offset).to_string())
            .body(body)
            .send()
            .await?;
        let status = sent.status();
        let answer: Value = sent.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            bail!("the server said {status}: {}", answer["message"]);
        }
        if answer["state"] == "duplicate" {
            let existing = answer["existingAssetId"]
                .as_str()
                .context("no existing asset id")?;
            return Ok(Uploaded::Duplicate(existing.to_string()));
        }
        Ok(Uploaded::Stored)
    }
}

enum Uploaded {
    Stored,
    Duplicate(String),
}

async fn hash(path: &Path) -> Result<(String, u64)> {
    let mut file = tokio::fs::File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    let mut size = 0u64;
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        size += read as u64;
    }
    Ok((hex::encode(hasher.finalize()), size))
}

/// Progress in the terminal: how many, how many skipped, how long still.
pub struct Progress {
    total: usize,
    started: Instant,
    last: Instant,
    pub added: usize,
    pub already: usize,
    pub before: usize,
    pub failed: usize,
}

impl Progress {
    pub fn new(total: usize) -> Self {
        Self {
            total,
            started: Instant::now(),
            last: Instant::now() - Duration::from_secs(10),
            added: 0,
            already: 0,
            before: 0,
            failed: 0,
        }
    }

    pub fn count(&mut self, outcome: Result<Outcome>, name: &str) {
        match outcome {
            Ok(Outcome::Added) => self.added += 1,
            Ok(Outcome::AlreadyThere) => self.already += 1,
            Ok(Outcome::DoneBefore) => self.before += 1,
            Err(error) => {
                self.failed += 1;
                eprintln!("  {name}: {error:#}");
            }
        }
        if self.last.elapsed() >= Duration::from_secs(2) || self.handled() == self.total {
            self.last = Instant::now();
            println!("{}", self.line());
        }
    }

    fn handled(&self) -> usize {
        self.added + self.already + self.before + self.failed
    }

    pub fn line(&self) -> String {
        let handled = self.handled();
        let worked = (handled - self.before).max(1) as f64;
        let left = self.total.saturating_sub(handled) as f64;
        let rest = Duration::from_secs_f64(self.started.elapsed().as_secs_f64() / worked * left);
        format!(
            "{handled} of {} · {} new · {} were there already · {} from before · {} failed{}",
            self.total,
            self.added,
            self.already,
            self.before,
            self.failed,
            if left > 0.0 && handled > self.before {
                format!(" · about {} min left", rest.as_secs() / 60 + 1)
            } else {
                String::new()
            }
        )
    }
}
