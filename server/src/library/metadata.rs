//! Reading what the camera wrote into a file: EXIF for photos, QuickTime/MP4 metadata for
//! videos. Only the header is read, never the whole file. Broken or unusual files simply give
//! less metadata; reading never fails an upload.

use std::path::Path;

use chrono::{DateTime, FixedOffset, NaiveDateTime};
use nom_exif::{
    EntryValue, Exif, ExifDateTime, ExifTag, MediaKind as ParsedKind, MediaParser, MediaSource,
    TrackInfo, TrackInfoTag,
};
use serde_json::{Map, Value, json};

/// What the file itself says. Every field may be missing.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct FileMetadata {
    /// Capture time; `offset` is known only if the file recorded one.
    pub taken_at: Option<NaiveDateTime>,
    pub offset_minutes: Option<i32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub altitude: Option<f64>,
    /// Selected fields for the info view.
    pub fields: Map<String, Value>,
}

impl FileMetadata {
    /// The capture time as a point in time, if the file says when and where (offset).
    pub fn taken_at_utc(&self) -> Option<DateTime<FixedOffset>> {
        let offset = FixedOffset::east_opt(self.offset_minutes? * 60)?;
        self.taken_at?.and_local_timezone(offset).single()
    }
}

/// Reads the metadata of the file at `path`.
pub fn read(path: &Path) -> FileMetadata {
    match try_read(path) {
        Ok(metadata) => metadata,
        Err(error) => {
            tracing::debug!(%error, "no metadata in the file");
            FileMetadata::default()
        }
    }
}

fn try_read(path: &Path) -> nom_exif::Result<FileMetadata> {
    let source = MediaSource::open(path)?;
    let mut parser = MediaParser::new();
    match source.kind() {
        ParsedKind::Image => {
            let exif: Exif = parser.parse_exif(source)?.into();
            Ok(from_exif(&exif))
        }
        ParsedKind::Track => Ok(from_track(&parser.parse_track(source)?)),
    }
}

fn text(value: Option<&EntryValue>) -> Option<String> {
    value
        .and_then(EntryValue::as_str)
        .map(|s| s.trim_matches(char::from(0)).trim().to_string())
        .filter(|s| !s.is_empty() && s.len() <= 200)
}

fn number(value: Option<&EntryValue>) -> Option<u32> {
    let value = value?;
    value
        .as_u32()
        .or_else(|| value.as_u16().map(u32::from))
        .or_else(|| value.as_u64().and_then(|n| u32::try_from(n).ok()))
}

fn split_time(time: ExifDateTime) -> (NaiveDateTime, Option<i32>) {
    match time {
        ExifDateTime::Aware(time) => (
            time.naive_local(),
            Some(time.offset().local_minus_utc() / 60),
        ),
        ExifDateTime::Naive(time) => (time, None),
    }
}

fn from_exif(exif: &Exif) -> FileMetadata {
    let mut metadata = FileMetadata::default();
    let time = [
        ExifTag::DateTimeOriginal,
        ExifTag::CreateDate,
        ExifTag::ModifyDate,
    ]
    .into_iter()
    .find_map(|tag| exif.get(tag).and_then(EntryValue::as_datetime));
    if let Some(time) = time {
        let (local, offset) = split_time(time);
        metadata.taken_at = Some(local);
        metadata.offset_minutes = offset;
    }
    metadata.width =
        number(exif.get(ExifTag::ExifImageWidth)).or(number(exif.get(ExifTag::ImageWidth)));
    metadata.height =
        number(exif.get(ExifTag::ExifImageHeight)).or(number(exif.get(ExifTag::ImageHeight)));
    metadata.make = text(exif.get(ExifTag::Make));
    metadata.model = text(exif.get(ExifTag::Model));
    metadata.lens = text(exif.get(ExifTag::LensModel));
    if let Some(gps) = exif.gps_info() {
        metadata.latitude = gps.latitude_decimal().filter(|v| v.is_finite());
        metadata.longitude = gps.longitude_decimal().filter(|v| v.is_finite());
        metadata.altitude = gps.altitude_meters().filter(|v| v.is_finite());
    }

    let mut fields = Map::new();
    for (name, tag) in [
        ("exposureTime", ExifTag::ExposureTime),
        ("fNumber", ExifTag::FNumber),
        ("iso", ExifTag::ISOSpeedRatings),
        ("focalLength", ExifTag::FocalLength),
        ("focalLength35mm", ExifTag::FocalLengthIn35mmFilm),
        ("flash", ExifTag::Flash),
        ("orientation", ExifTag::Orientation),
        ("software", ExifTag::Software),
        ("lensMake", ExifTag::LensMake),
    ] {
        if let Some(value) = exif.get(tag) {
            fields.insert(name.into(), json!(value.to_string()));
        }
    }
    metadata.fields = fields;
    metadata
}

fn from_track(track: &TrackInfo) -> FileMetadata {
    let mut metadata = FileMetadata::default();
    if let Some(time) = track
        .get(TrackInfoTag::CreateDate)
        .and_then(EntryValue::as_datetime)
    {
        let (local, offset) = split_time(time);
        metadata.taken_at = Some(local);
        metadata.offset_minutes = offset;
    }
    metadata.width = number(track.get(TrackInfoTag::Width));
    metadata.height = number(track.get(TrackInfoTag::Height));
    metadata.duration_ms = track
        .get(TrackInfoTag::DurationMs)
        .and_then(EntryValue::as_u64);
    metadata.make = text(track.get(TrackInfoTag::Make));
    metadata.model = text(track.get(TrackInfoTag::Model));
    if let Some(gps) = track.gps_info() {
        metadata.latitude = gps.latitude_decimal().filter(|v| v.is_finite());
        metadata.longitude = gps.longitude_decimal().filter(|v| v.is_finite());
        metadata.altitude = gps.altitude_meters().filter(|v| v.is_finite());
    }
    if let Some(software) = text(track.get(TrackInfoTag::Software)) {
        metadata.fields.insert("software".into(), json!(software));
    }
    metadata
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn garbage_gives_empty_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.heic");
        std::fs::write(&path, b"definitely not a photo").unwrap();
        assert_eq!(read(&path), FileMetadata::default());
        assert_eq!(
            read(&dir.path().join("missing.jpg")),
            FileMetadata::default()
        );
    }

    #[test]
    fn utc_time_needs_an_offset() {
        let mut metadata = FileMetadata {
            taken_at: NaiveDateTime::parse_from_str("2026-11-23 15:22:10", "%Y-%m-%d %H:%M:%S")
                .ok(),
            ..FileMetadata::default()
        };
        assert_eq!(metadata.taken_at_utc(), None);
        metadata.offset_minutes = Some(60);
        assert_eq!(
            metadata.taken_at_utc().unwrap().to_rfc3339(),
            "2026-11-23T15:22:10+01:00"
        );
    }
}
