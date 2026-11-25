//! Google Takeout (Google Photos): folders or the ZIP files Google sends, as they are.
//!
//! Every photo has a JSON file next to it with what Google knew (when it was taken, where,
//! the description); its name is the photo's, sometimes cut short or with a number moved
//! (`IMG_1234(1).jpg` → `IMG_1234.jpg(1).json`). A folder with a `metadata.json` is an album;
//! the year folders ("Photos from 2019", "Fotos von 2019", …) are not. A photo and a video with
//! the same name are a Live Photo. Copies Google edited (`-edited`, `-bearbeitet`, …) are left
//! out: the original is what counts. Several ZIP parts of one export are read as one.

use std::{
    collections::{HashMap, HashSet},
    io::Read,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use serde_json::Value;

use super::{Fetch, Item, mime_of};

/// Endings of the copies Google edited, in the languages Takeout is made in.
const EDITED: &[&str] = &[
    "-edited",
    "-bearbeitet",
    "-modifié",
    "-editado",
    "-modificato",
    "-bewerkt",
    "-redigerad",
];

/// Where a file is: on the disk, or inside a ZIP (archive number and entry name).
#[derive(Debug, Clone)]
enum Place {
    Disk(PathBuf),
    Zip(usize, String),
}

/// A Takeout export: the files of all its folders and ZIP parts.
pub struct Takeout {
    archives: Vec<PathBuf>,
    /// By path inside the export ("Takeout/Google Photos/Rome/IMG_1.jpg").
    files: HashMap<String, Place>,
}

impl Takeout {
    /// Reads what is in the folders and ZIP files (only the list, and the small JSON files).
    pub fn open(inputs: &[PathBuf]) -> Result<Self> {
        let mut takeout = Self {
            archives: Vec::new(),
            files: HashMap::new(),
        };
        for input in inputs {
            if input.is_dir() {
                takeout.walk(input, input)?;
            } else {
                let file = std::fs::File::open(input)
                    .with_context(|| format!("could not open {}", input.display()))?;
                let archive = zip::ZipArchive::new(file)
                    .with_context(|| format!("{} is no ZIP file", input.display()))?;
                let index = takeout.archives.len();
                takeout.archives.push(input.clone());
                let names = archive
                    .file_names()
                    .map(|name| name.map(|name| name.to_string()))
                    .collect::<Result<Vec<_>, _>>()
                    .with_context(|| format!("{} can't be read", input.display()))?;
                for name in names {
                    if !name.ends_with('/') {
                        takeout.files.insert(normal(&name), Place::Zip(index, name));
                    }
                }
            }
        }
        Ok(takeout)
    }

    fn walk(&mut self, root: &Path, folder: &Path) -> Result<()> {
        for entry in std::fs::read_dir(folder)? {
            let path = entry?.path();
            if path.is_dir() {
                self.walk(root, &path)?;
            } else if let Ok(relative) = path.strip_prefix(root) {
                self.files.insert(
                    normal(&relative.to_string_lossy()),
                    Place::Disk(path.clone()),
                );
            }
        }
        Ok(())
    }

    fn read(&self, place: &Place, limit: u64) -> Result<Vec<u8>> {
        match place {
            Place::Disk(path) => Ok(std::fs::read(path)?),
            Place::Zip(index, name) => {
                let mut archive =
                    zip::ZipArchive::new(std::fs::File::open(&self.archives[*index])?)?;
                let mut entry = archive.by_name(name)?;
                let mut bytes = Vec::new();
                (&mut entry).take(limit).read_to_end(&mut bytes)?;
                Ok(bytes)
            }
        }
    }

    fn json(&self, path: &str) -> Option<Value> {
        let place = self.files.get(path)?;
        serde_json::from_slice(&self.read(place, 1 << 20).ok()?).ok()
    }

    /// Every photo and video, with what Google knew about it.
    pub fn items(&self) -> Vec<Item> {
        let mut paths: Vec<&String> = self.files.keys().collect();
        paths.sort();
        let mut by_folder: HashMap<&str, Vec<&str>> = HashMap::new();
        for path in &paths {
            let (folder, name) = split(path);
            by_folder.entry(folder).or_default().push(name);
        }
        let mut items = Vec::new();
        for (folder, names) in &by_folder {
            let album = self
                .json(&join(folder, "metadata.json"))
                .and_then(|meta| meta["title"].as_str().map(str::to_string))
                .filter(|title| !title.trim().is_empty());
            let present: HashSet<&str> = names.iter().copied().collect();
            // Videos that are the moving part of a Live Photo: not on their own.
            let mut paired_videos = HashSet::new();
            let mut pairs: HashMap<&str, &str> = HashMap::new();
            for name in names {
                let Some(mime) = mime_of(name) else { continue };
                if !mime.starts_with("image/") {
                    continue;
                }
                let stem = stem(name);
                for video in names {
                    if stem.eq_ignore_ascii_case(self::stem(video))
                        && mime_of(video).is_some_and(|m| m.starts_with("video/"))
                    {
                        paired_videos.insert(*video);
                        pairs.insert(name, video);
                    }
                }
            }
            for name in names {
                let Some(mime) = mime_of(name) else { continue };
                if paired_videos.contains(name) || edited(name) {
                    continue;
                }
                let path = join(folder, name);
                let sidecar =
                    sidecar_for(name, &present).and_then(|json| self.json(&join(folder, &json)));
                let mut item = Item {
                    key: format!("takeout:{path}"),
                    file_name: name.to_string(),
                    mime: mime.to_string(),
                    albums: album.iter().cloned().collect(),
                    paired: pairs.get(name).map(|video| {
                        (
                            format!("takeout:{}", join(folder, video)),
                            video.to_string(),
                        )
                    }),
                    ..Item::default()
                };
                if let Some(meta) = sidecar {
                    read_sidecar(&meta, &mut item);
                }
                items.push(item);
            }
        }
        items.sort_by(|a, b| a.key.cmp(&b.key));
        items
    }
}

impl Fetch for Takeout {
    async fn fetch(&mut self, key: &str, path: &Path) -> Result<()> {
        let inside = key.strip_prefix("takeout:").unwrap_or(key);
        let place = self.files.get(inside).context("the file is gone")?.clone();
        match place {
            Place::Disk(source) => {
                tokio::fs::copy(&source, path).await?;
            }
            Place::Zip(index, name) => {
                let archive = self.archives[index].clone();
                let target = path.to_path_buf();
                tokio::task::spawn_blocking(move || -> Result<()> {
                    let mut archive = zip::ZipArchive::new(std::fs::File::open(archive)?)?;
                    let mut entry = archive.by_name(&name)?;
                    let mut out = std::fs::File::create(&target)?;
                    std::io::copy(&mut entry, &mut out)?;
                    out.sync_all()?;
                    Ok(())
                })
                .await??;
            }
        }
        Ok(())
    }
}

/// Paths with forward slashes, as inside a ZIP.
fn normal(path: &str) -> String {
    path.replace('\\', "/")
}

fn split(path: &str) -> (&str, &str) {
    match path.rfind('/') {
        Some(at) => (&path[..at], &path[at + 1..]),
        None => ("", path),
    }
}

fn join(folder: &str, name: &str) -> String {
    if folder.is_empty() {
        name.to_string()
    } else {
        format!("{folder}/{name}")
    }
}

fn stem(name: &str) -> &str {
    match name.rfind('.') {
        Some(at) if at > 0 => &name[..at],
        _ => name,
    }
}

fn edited(name: &str) -> bool {
    let stem = stem(name).to_lowercase();
    // "IMG_1-edited(1)" too.
    let stem = match stem.rfind('(') {
        Some(at) if stem.ends_with(')') => stem[..at].to_string(),
        _ => stem,
    };
    EDITED.iter().any(|ending| stem.ends_with(ending))
}

/// The JSON file Google wrote for `name`, among the files in its folder.
pub(crate) fn sidecar_for(name: &str, present: &HashSet<&str>) -> Option<String> {
    // "IMG_1234(1).jpg": Google writes "IMG_1234.jpg(1).json".
    let (base, number) = match (name.rfind('('), name.rfind(')')) {
        (Some(open), Some(close)) if close > open && name[close + 1..].starts_with('.') => (
            format!("{}{}", &name[..open], &name[close + 1..]),
            Some(name[open..=close].to_string()),
        ),
        _ => (name.to_string(), None),
    };
    let suffix = number.clone().unwrap_or_default();
    let mut candidates = vec![
        format!("{base}.supplemental-metadata{suffix}.json"),
        format!("{base}{suffix}.json"),
        format!("{}{suffix}.json", stem(&base)),
    ];
    if number.is_none() {
        candidates.push(format!("{name}.json"));
    }
    for candidate in &candidates {
        if present.contains(candidate.as_str()) {
            return Some(candidate.clone());
        }
    }
    // Long names are cut short (to 51 characters with ".json"), also inside
    // "supplemental-metadata".
    let wanted = format!("{base}.supplemental-metadata").to_lowercase();
    present
        .iter()
        .filter(|json| {
            json.to_lowercase()
                .ends_with(&format!("{}.json", suffix.to_lowercase()))
        })
        .filter(|json| json.len() >= 30)
        .find(|json| {
            let cut = json.to_lowercase();
            let cut = cut.trim_end_matches(".json");
            let cut = cut
                .trim_end_matches(&suffix.to_lowercase())
                .trim_end_matches('.');
            !cut.is_empty() && wanted.starts_with(cut)
        })
        .map(|json| json.to_string())
}

/// When, where and the description, from Google's JSON.
pub(crate) fn read_sidecar(meta: &Value, item: &mut Item) {
    let seconds = |value: &Value| -> Option<i64> {
        value["timestamp"]
            .as_str()
            .and_then(|s| s.parse::<i64>().ok())
            .or_else(|| value["timestamp"].as_i64())
    };
    item.taken_at = seconds(&meta["photoTakenTime"])
        .filter(|s| *s > 0)
        .map(|s| s * 1000);
    let place = |geo: &Value| -> Option<(f64, f64, Option<f64>)> {
        let latitude = geo["latitude"].as_f64()?;
        let longitude = geo["longitude"].as_f64()?;
        // Google writes 0, 0 for "no place".
        if latitude == 0.0 && longitude == 0.0 {
            return None;
        }
        Some((
            latitude,
            longitude,
            geo["altitude"].as_f64().filter(|a| *a != 0.0),
        ))
    };
    item.location = place(&meta["geoData"]).or_else(|| place(&meta["geoDataExif"]));
    item.description = meta["description"]
        .as_str()
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(str::to_string);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecars_are_found_however_google_named_them() {
        let present: HashSet<&str> = [
            "IMG_1.jpg.supplemental-metadata.json",
            "IMG_2.JPG.json",
            "IMG_3.jpg(1).json",
            "PXL_20230101_123456789.MP.jpg.supplemental-metad.json",
            "Screenshot_20240101-101010_A_very_long_app_n.json",
        ]
        .into_iter()
        .collect();
        assert_eq!(
            sidecar_for("IMG_1.jpg", &present).as_deref(),
            Some("IMG_1.jpg.supplemental-metadata.json")
        );
        assert_eq!(
            sidecar_for("IMG_2.JPG", &present).as_deref(),
            Some("IMG_2.JPG.json")
        );
        assert_eq!(
            sidecar_for("IMG_3(1).jpg", &present).as_deref(),
            Some("IMG_3.jpg(1).json")
        );
        assert_eq!(
            sidecar_for("PXL_20230101_123456789.MP.jpg", &present).as_deref(),
            Some("PXL_20230101_123456789.MP.jpg.supplemental-metad.json")
        );
        assert_eq!(sidecar_for("IMG_9.jpg", &present), None);
    }

    #[test]
    fn edited_copies_are_left_out() {
        assert!(edited("IMG_1-edited.jpg"));
        assert!(edited("IMG_1-bearbeitet.JPG"));
        assert!(edited("IMG_1-edited(1).jpg"));
        assert!(!edited("IMG_1.jpg"));
        assert!(!edited("edited.jpg"));
    }

    #[test]
    fn the_json_gives_time_place_and_description() {
        let mut item = Item::default();
        read_sidecar(
            &serde_json::json!({
                "photoTakenTime": { "timestamp": "1621234567" },
                "geoData": { "latitude": 0.0, "longitude": 0.0, "altitude": 0.0 },
                "geoDataExif": { "latitude": 41.9, "longitude": 12.5, "altitude": 21.0 },
                "description": "  Trevi  "
            }),
            &mut item,
        );
        assert_eq!(item.taken_at, Some(1_621_234_567_000));
        assert_eq!(item.location, Some((41.9, 12.5, Some(21.0))));
        assert_eq!(item.description.as_deref(), Some("Trevi"));
    }
}
