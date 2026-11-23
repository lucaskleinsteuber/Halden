//! Sending files to devices: originals with Range (seeking in videos), thumbnails in bulk.
//!
//! Every file is identified by its SHA-256, which is also its ETag. Because content and name
//! belong together, a device can cache a file forever and never has to ask twice
//! (`Cache-Control: immutable`, `304 Not Modified` for `If-None-Match`). Files are read in
//! 256 KiB pieces instead of the usual 4–8 KiB: fewer system calls, fewer HTTP/2 frames.

use std::{
    io::{Read, SeekFrom},
    path::{Path, PathBuf},
};

use axum::{
    body::Body,
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use bytes::{Bytes, BytesMut};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;
use uuid::Uuid;

const READ_CHUNK: usize = 256 * 1024;
/// Files up to this size are read in one go instead of streamed.
const SMALL_FILE: u64 = 1024 * 1024;
/// Thumbnails are packed into frames of about this size for the bulk answer.
const BULK_FRAME: usize = 256 * 1024;

/// How long a device may keep a file without asking again.
pub enum Caching {
    /// The URL names the content (`/files/{sha256}`): keep it forever.
    Immutable,
    /// The URL names a role that may get new content (a replaced thumbnail): ask again, the
    /// answer is a cheap `304` while nothing changed.
    Revalidate,
}

pub struct FileToSend {
    pub path: PathBuf,
    pub mime: String,
    pub sha256_hex: String,
    pub size: u64,
    /// For `Content-Disposition`; shown when the file is saved.
    pub download_name: Option<String>,
    pub caching: Caching,
}

/// A single byte range, already checked against the file size. `end` is inclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum RangeRequest {
    /// No (usable) Range header: send everything.
    Full,
    Partial(ByteRange),
    /// The range lies outside the file.
    Unsatisfiable,
}

/// Parses `Range: bytes=…` for one range: `a-b`, `a-` or `-n` (the last n bytes). Several
/// ranges or other units are answered with the whole file, which the standard allows.
pub fn parse_range(header: &str, size: u64) -> RangeRequest {
    let Some(spec) = header.trim().strip_prefix("bytes=") else {
        return RangeRequest::Full;
    };
    if spec.contains(',') {
        return RangeRequest::Full;
    }
    let Some((start, end)) = spec.trim().split_once('-') else {
        return RangeRequest::Full;
    };
    let (start, end) = (start.trim(), end.trim());
    let range = match (start.is_empty(), end.is_empty()) {
        (true, true) => return RangeRequest::Full,
        (true, false) => {
            let Ok(suffix) = end.parse::<u64>() else {
                return RangeRequest::Full;
            };
            if suffix == 0 || size == 0 {
                return RangeRequest::Unsatisfiable;
            }
            ByteRange {
                start: size.saturating_sub(suffix),
                end: size - 1,
            }
        }
        (false, _) => {
            let Ok(start) = start.parse::<u64>() else {
                return RangeRequest::Full;
            };
            let end = if end.is_empty() {
                size.saturating_sub(1)
            } else {
                match end.parse::<u64>() {
                    Ok(end) if end >= start => end.min(size.saturating_sub(1)),
                    _ => return RangeRequest::Full,
                }
            };
            if start >= size {
                return RangeRequest::Unsatisfiable;
            }
            ByteRange { start, end }
        }
    };
    RangeRequest::Partial(range)
}

fn etag(sha256_hex: &str) -> String {
    format!("\"{sha256_hex}\"")
}

/// Does `If-None-Match` list this ETag (or `*`)?
fn matches_etag(headers: &HeaderMap, etag: &str) -> bool {
    headers
        .get_all(header::IF_NONE_MATCH)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .map(|v| v.trim().trim_start_matches("W/"))
        .any(|v| v == etag || v == "*")
}

/// Answers a GET (or HEAD) for a file: `304`, `206` with a range, `416`, or `200`.
pub async fn send(file: FileToSend, headers: &HeaderMap) -> Response {
    let etag = etag(&file.sha256_hex);
    let cache_control = match file.caching {
        Caching::Immutable => "private, max-age=31536000, immutable",
        Caching::Revalidate => "private, no-cache",
    };
    let mut common = HeaderMap::new();
    if let Ok(value) = HeaderValue::from_str(&etag) {
        common.insert(header::ETAG, value);
    }
    common.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static(cache_control),
    );
    common.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));

    if matches_etag(headers, &etag) {
        return (StatusCode::NOT_MODIFIED, common).into_response();
    }

    // `If-Range` with another ETag: the device's partial copy is of other content.
    let range_allowed = headers
        .get(header::IF_RANGE)
        .and_then(|v| v.to_str().ok())
        .is_none_or(|v| v.trim() == etag);
    let range = match headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
        Some(value) if range_allowed => parse_range(value, file.size),
        _ => RangeRequest::Full,
    };

    let mut opened = match tokio::fs::File::open(&file.path).await {
        Ok(opened) => opened,
        Err(error) => {
            tracing::error!(%error, "a recorded file is missing on disk");
            return crate::api::ApiError::not_found().into_response();
        }
    };

    if let Ok(mime) = HeaderValue::from_str(&file.mime) {
        common.insert(header::CONTENT_TYPE, mime);
    }
    if let Some(name) = &file.download_name
        && let Ok(value) = HeaderValue::from_str(&format!("inline; filename=\"{name}\""))
    {
        common.insert(header::CONTENT_DISPOSITION, value);
    }

    let (status, start, length) = match range {
        RangeRequest::Unsatisfiable => {
            if let Ok(value) = HeaderValue::from_str(&format!("bytes */{}", file.size)) {
                common.insert(header::CONTENT_RANGE, value);
            }
            return (StatusCode::RANGE_NOT_SATISFIABLE, common).into_response();
        }
        RangeRequest::Full => (StatusCode::OK, 0, file.size),
        RangeRequest::Partial(range) => {
            if let Ok(value) = HeaderValue::from_str(&format!(
                "bytes {}-{}/{}",
                range.start, range.end, file.size
            )) {
                common.insert(header::CONTENT_RANGE, value);
            }
            (
                StatusCode::PARTIAL_CONTENT,
                range.start,
                range.end - range.start + 1,
            )
        }
    };
    common.insert(header::CONTENT_LENGTH, HeaderValue::from(length));
    // Thumbnails and other small files: one read on one blocking thread, sent in one piece.
    if length <= SMALL_FILE {
        drop(opened);
        let path = file.path.clone();
        let read = tokio::task::spawn_blocking(move || -> std::io::Result<Vec<u8>> {
            let mut file = std::fs::File::open(path)?;
            std::io::Seek::seek(&mut file, SeekFrom::Start(start))?;
            let mut data = Vec::with_capacity(length as usize);
            file.take(length).read_to_end(&mut data)?;
            Ok(data)
        })
        .await;
        return match read {
            Ok(Ok(data)) if data.len() as u64 == length => {
                (status, common, Body::from(data)).into_response()
            }
            _ => crate::api::ApiError::internal().into_response(),
        };
    }
    if start > 0 && opened.seek(SeekFrom::Start(start)).await.is_err() {
        return crate::api::ApiError::internal().into_response();
    }
    let body = Body::from_stream(ReaderStream::with_capacity(opened.take(length), READ_CHUNK));
    (status, common, body).into_response()
}

/// One entry of the bulk answer: which asset, and where its file is.
pub struct BulkItem {
    pub asset_id: Uuid,
    pub path: Option<PathBuf>,
}

/// Streams many small files as one binary answer. For each requested asset, in order:
/// 16 bytes asset UUID, 4 bytes big-endian length, then that many bytes of the file. A length of
/// 0 means "no such file". Small files are packed together into frames of about 256 KiB, and
/// the first bytes leave before the last file is read.
pub fn bulk(items: Vec<BulkItem>) -> Response {
    let (frames, queue) = tokio::sync::mpsc::channel::<Bytes>(8);
    tokio::task::spawn_blocking(move || {
        let mut frame = BytesMut::with_capacity(BULK_FRAME * 2);
        for item in items {
            let data = item.path.as_deref().and_then(read_small);
            frame.extend_from_slice(item.asset_id.as_bytes());
            let length = data.as_ref().map_or(0, |d| d.len() as u32);
            frame.extend_from_slice(&length.to_be_bytes());
            if let Some(data) = data {
                frame.extend_from_slice(&data);
            }
            if frame.len() >= BULK_FRAME && frames.blocking_send(frame.split().freeze()).is_err() {
                return;
            }
        }
        if !frame.is_empty() {
            let _ = frames.blocking_send(frame.freeze());
        }
    });
    let stream = futures_util::stream::unfold(queue, |mut queue| async move {
        queue
            .recv()
            .await
            .map(|frame| (Ok::<_, std::io::Error>(frame), queue))
    });
    let mut response = Body::from_stream(stream).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/vnd.halden.files"),
    );
    response
}

/// Reads a whole small file; `None` if it can't be read.
fn read_small(path: &Path) -> Option<Vec<u8>> {
    let mut file = std::fs::File::open(path).ok()?;
    let size = file.metadata().ok()?.len();
    if size > crate::library::derived::MAX_BYTES as u64 {
        return None;
    }
    let mut data = Vec::with_capacity(size as usize);
    file.read_to_end(&mut data).ok()?;
    Some(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges() {
        let r = |start, end| RangeRequest::Partial(ByteRange { start, end });
        assert_eq!(parse_range("bytes=0-99", 1000), r(0, 99));
        assert_eq!(parse_range("bytes=500-", 1000), r(500, 999));
        assert_eq!(parse_range("bytes=-100", 1000), r(900, 999));
        assert_eq!(parse_range("bytes=-5000", 1000), r(0, 999));
        assert_eq!(parse_range("bytes=900-5000", 1000), r(900, 999));
        assert_eq!(
            parse_range("bytes=1000-", 1000),
            RangeRequest::Unsatisfiable
        );
        assert_eq!(parse_range("bytes=-0", 1000), RangeRequest::Unsatisfiable);
        assert_eq!(parse_range("bytes=0-1,5-6", 1000), RangeRequest::Full);
        assert_eq!(parse_range("items=0-1", 1000), RangeRequest::Full);
        assert_eq!(parse_range("bytes=9-3", 1000), RangeRequest::Full);
        assert_eq!(parse_range("bytes=x-", 1000), RangeRequest::Full);
    }

    #[test]
    fn etags_match_with_and_without_weak_prefix() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::IF_NONE_MATCH,
            HeaderValue::from_static("\"a\", W/\"abc\""),
        );
        assert!(matches_etag(&headers, "\"abc\""));
        assert!(!matches_etag(&headers, "\"abd\""));
        headers.insert(header::IF_NONE_MATCH, HeaderValue::from_static("*"));
        assert!(matches_etag(&headers, "\"x\""));
    }
}
