//! Where files go. Every path is made by the server from the account name, the capture time
//! and the file type; nothing a device sends ever becomes part of a path, so a device can't
//! write outside the library (no `../`, no absolute paths, no odd characters).

use std::{
    fmt::Write as _,
    path::{Path, PathBuf},
};

use chrono::{DateTime, Datelike, FixedOffset, Timelike};

pub const DEFAULT_TEMPLATE: &str = "{user}/{year}/{month}/{date}_{time}";

/// What a file is, decided by its MIME type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaType {
    pub mime: &'static str,
    pub extension: &'static str,
    pub kind: MediaKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Photo,
    Video,
}

impl MediaKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Photo => "photo",
            Self::Video => "video",
        }
    }
}

const MEDIA_TYPES: &[MediaType] = &[
    photo("image/heic", "heic"),
    photo("image/heif", "heif"),
    photo("image/jpeg", "jpg"),
    photo("image/png", "png"),
    photo("image/tiff", "tiff"),
    photo("image/webp", "webp"),
    photo("image/gif", "gif"),
    photo("image/avif", "avif"),
    photo("image/x-adobe-dng", "dng"),
    photo("image/dng", "dng"),
    photo("image/x-canon-cr3", "cr3"),
    photo("image/x-fuji-raf", "raf"),
    video("video/quicktime", "mov"),
    video("video/mp4", "mp4"),
    video("video/x-matroska", "mkv"),
    video("video/webm", "webm"),
];

const fn photo(mime: &'static str, extension: &'static str) -> MediaType {
    MediaType {
        mime,
        extension,
        kind: MediaKind::Photo,
    }
}

const fn video(mime: &'static str, extension: &'static str) -> MediaType {
    MediaType {
        mime,
        extension,
        kind: MediaKind::Video,
    }
}

impl MediaType {
    /// The known type for a MIME string (case and parameters like `; charset` don't matter).
    pub fn from_mime(mime: &str) -> Option<Self> {
        let mime = mime.split(';').next()?.trim().to_ascii_lowercase();
        MEDIA_TYPES.iter().find(|t| t.mime == mime).copied()
    }

    pub fn from_extension(extension: &str) -> Option<Self> {
        let extension = extension.to_ascii_lowercase();
        MEDIA_TYPES
            .iter()
            .find(|t| t.extension == extension)
            .copied()
    }

    /// The types thumbnails and previews may have.
    pub fn is_derived_image(&self) -> bool {
        matches!(
            self.mime,
            "image/jpeg" | "image/heic" | "image/png" | "image/webp"
        )
    }
}

/// A parsed `storage.path_template`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathTemplate {
    parts: Vec<Part>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Part {
    Text(String),
    User,
    Year,
    Month,
    Day,
    Date,
    Time,
    Hour,
    Minute,
    Second,
}

impl PathTemplate {
    pub fn parse(template: &str) -> Result<Self, String> {
        let mut parts = Vec::new();
        let mut rest = template.trim();
        if rest.is_empty() {
            return Err("must not be empty".into());
        }
        while !rest.is_empty() {
            if let Some(after) = rest.strip_prefix('{') {
                let end = after
                    .find('}')
                    .ok_or_else(|| format!("{{ without }} in {template:?}"))?;
                parts.push(match &after[..end] {
                    "user" => Part::User,
                    "year" => Part::Year,
                    "month" => Part::Month,
                    "day" => Part::Day,
                    "date" => Part::Date,
                    "time" => Part::Time,
                    "hour" => Part::Hour,
                    "minute" => Part::Minute,
                    "second" => Part::Second,
                    other => return Err(format!("unknown placeholder {{{other}}}")),
                });
                rest = &after[end + 1..];
            } else {
                let end = rest.find('{').unwrap_or(rest.len());
                let text = &rest[..end];
                if !text
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | ' ' | '.'))
                {
                    return Err(format!(
                        "{text:?} may only contain letters, digits, / - _ . and spaces"
                    ));
                }
                parts.push(Part::Text(text.to_string()));
                rest = &rest[end..];
            }
        }
        let template = Self { parts };
        // Render a sample to catch empty folder names, `..`, a leading slash and the like.
        let sample = template.render_raw("user", sample_time());
        for segment in sample.split('/') {
            if segment.is_empty() || segment == "." || segment == ".." || segment.starts_with('.') {
                return Err(format!(
                    "makes the path {sample:?}; folders must not be empty or start with a dot"
                ));
            }
        }
        if !template.parts.iter().any(|p| {
            matches!(
                p,
                Part::Time | Part::Second | Part::Date | Part::Day | Part::Minute
            )
        }) {
            return Err(
                "needs at least {date} or {time}, or nearly every photo would clash".into(),
            );
        }
        Ok(template)
    }

    fn render_raw(&self, user: &str, time: DateTime<FixedOffset>) -> String {
        let mut out = String::new();
        for part in &self.parts {
            let _ = match part {
                Part::Text(text) => write!(out, "{text}"),
                Part::User => write!(out, "{user}"),
                Part::Year => write!(out, "{:04}", time.year()),
                Part::Month => write!(out, "{:02}", time.month()),
                Part::Day => write!(out, "{:02}", time.day()),
                Part::Date => write!(
                    out,
                    "{:04}-{:02}-{:02}",
                    time.year(),
                    time.month(),
                    time.day()
                ),
                Part::Time => write!(
                    out,
                    "{:02}-{:02}-{:02}",
                    time.hour(),
                    time.minute(),
                    time.second()
                ),
                Part::Hour => write!(out, "{:02}", time.hour()),
                Part::Minute => write!(out, "{:02}", time.minute()),
                Part::Second => write!(out, "{:02}", time.second()),
            };
        }
        out
    }

    /// The path inside the library, without extension, for a photo taken at `time` (local time
    /// where it was taken) by `user`.
    pub fn render(&self, user: &str, time: DateTime<FixedOffset>) -> PathBuf {
        PathBuf::from(self.render_raw(user, time))
    }
}

fn sample_time() -> DateTime<FixedOffset> {
    DateTime::parse_from_rfc3339("2026-11-23T15:22:10+01:00").expect("valid sample time")
}

/// The first free name: `base.ext`, then `base_2.ext`, `base_3.ext`, … `taken` says whether a
/// relative path is already used (on disk or in the database).
pub fn first_free(base: &Path, extension: &str, taken: impl Fn(&Path) -> bool) -> PathBuf {
    let mut number = 1;
    loop {
        let candidate = numbered(base, number, extension);
        if !taken(&candidate) {
            return candidate;
        }
        number += 1;
    }
}

/// `base.ext` for 1, `base_2.ext` for 2, and so on.
pub fn numbered(base: &Path, number: u32, extension: &str) -> PathBuf {
    let mut name = base.as_os_str().to_owned();
    if number > 1 {
        name.push(format!("_{number}"));
    }
    name.push(".");
    name.push(extension);
    PathBuf::from(name)
}

/// Where a thumbnail or preview with this hash lives inside the derived folder:
/// `ab/cd/abcd….jpg`. Two levels of folders keep each folder small.
pub fn derived_path(sha256_hex: &str, extension: &str) -> PathBuf {
    let mut path = PathBuf::new();
    path.push(&sha256_hex[..2]);
    path.push(&sha256_hex[2..4]);
    path.push(format!("{sha256_hex}.{extension}"));
    path
}

/// Joins a relative path the server made to a root, refusing anything that could leave the root.
/// The database only ever holds paths made here, so this is a second line of defence.
pub fn resolve(root: &Path, relative: &str) -> Option<PathBuf> {
    let relative = Path::new(relative);
    let safe = relative
        .components()
        .all(|c| matches!(c, std::path::Component::Normal(_)));
    (safe && !relative.as_os_str().is_empty()).then(|| root.join(relative))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn templates_render_local_time() {
        let template = PathTemplate::parse(DEFAULT_TEMPLATE).unwrap();
        let time = DateTime::parse_from_rfc3339("2026-01-05T07:08:09-05:00").unwrap();
        assert_eq!(
            template.render("lucas", time),
            PathBuf::from("lucas/2026/01/2026-01-05_07-08-09")
        );
        let flat =
            PathTemplate::parse("{user}/{year}-{month}-{day} {hour}.{minute}.{second}").unwrap();
        assert_eq!(
            flat.render("anna", time),
            PathBuf::from("anna/2026-01-05 07.08.09")
        );
    }

    #[test]
    fn bad_templates_are_refused() {
        for bad in [
            "",
            "/{user}/{date}",
            "{user}/../{date}",
            "{user}//{date}",
            "{user}/.hidden/{date}",
            "{user}/{nope}",
            "{user}/{date",
            "{user}/{year}",
            "{user}/$HOME/{date}",
            "{user}\\{date}",
        ] {
            assert!(
                PathTemplate::parse(bad).is_err(),
                "{bad:?} should be refused"
            );
        }
    }

    #[test]
    fn clashing_names_get_numbers() {
        let base = Path::new("lucas/2026/11/2026-11-23_15-22-10");
        let used = [
            PathBuf::from("lucas/2026/11/2026-11-23_15-22-10.heic"),
            PathBuf::from("lucas/2026/11/2026-11-23_15-22-10_2.heic"),
        ];
        assert_eq!(
            first_free(base, "heic", |p| used.iter().any(|u| u == p)),
            PathBuf::from("lucas/2026/11/2026-11-23_15-22-10_3.heic")
        );
        assert_eq!(
            first_free(base, "mov", |p| used.iter().any(|u| u == p)),
            PathBuf::from("lucas/2026/11/2026-11-23_15-22-10.mov")
        );
    }

    #[test]
    fn media_types_come_from_mime() {
        let heic = MediaType::from_mime("image/HEIC").unwrap();
        assert_eq!((heic.extension, heic.kind), ("heic", MediaKind::Photo));
        let mov = MediaType::from_mime("video/quicktime; codecs=hvc1").unwrap();
        assert_eq!((mov.extension, mov.kind), ("mov", MediaKind::Video));
        assert!(MediaType::from_mime("application/x-sh").is_none());
        assert!(
            MediaType::from_mime("image/jpeg")
                .unwrap()
                .is_derived_image()
        );
        assert!(
            !MediaType::from_mime("video/mp4")
                .unwrap()
                .is_derived_image()
        );
    }

    #[test]
    fn paths_stay_inside_their_root() {
        let root = Path::new("/srv/library");
        assert_eq!(
            resolve(root, "lucas/2026/a.heic"),
            Some(PathBuf::from("/srv/library/lucas/2026/a.heic"))
        );
        for bad in ["", "/etc/passwd", "../x", "lucas/../../x", "./x"] {
            assert_eq!(resolve(root, bad), None, "{bad:?}");
        }
        assert_eq!(
            derived_path("abcdef0123", "jpg"),
            PathBuf::from("ab/cd/abcdef0123.jpg")
        );
    }
}
