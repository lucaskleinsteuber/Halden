//! Receiving the bytes of an upload: straight from the network into the partial file, with the
//! SHA-256 computed on the way, so the finished file never has to be read again.
//!
//! The network side and the disk side are decoupled by a small bounded channel. The disk side
//! runs on a blocking thread and writes through a 1 MiB buffer: few, large writes instead of
//! one per network frame. When the disk is slower than the network, the channel fills up and the
//! network side simply waits (back pressure), so memory use stays flat even for a 10 GB video.

use std::{
    fs::{File, OpenOptions},
    io::{self, BufWriter, Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};

use axum::body::Body;
use bytes::Bytes;
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

const WRITE_BUFFER: usize = 1024 * 1024;
const READ_BUFFER: usize = 1024 * 1024;
/// Network frames waiting for the disk. With HTTP/2 frames of up to 256 KiB that is at most a
/// few MiB per upload.
const QUEUE_FRAMES: usize = 16;
/// An upload that sends nothing for this long is cut off; what arrived so far is kept.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(60);

/// The state of one upload between requests: how much is on disk, and the hash of exactly that.
pub struct Slot {
    pub received: u64,
    /// `None` until the hash was rebuilt from the file (after a restart or a write error).
    pub hasher: Option<Sha256>,
}

/// How a request body ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BodyEnd {
    /// Everything the client sent arrived.
    Complete,
    /// The connection broke or went quiet. The bytes that arrived are kept.
    Interrupted,
    /// The client sent more than the upload's size. The extra bytes were dropped.
    TooLong,
}

pub struct Appended {
    pub written: u64,
    /// `None` if writing failed; the hash must then be rebuilt from the file.
    pub hasher: Option<Sha256>,
    pub end: BodyEnd,
    pub error: Option<io::Error>,
}

/// Appends a request body to `part`, at most `limit` bytes, updating `hasher` as it goes.
pub async fn append(part: PathBuf, hasher: Sha256, body: Body, limit: u64) -> Appended {
    let (frames, mut queue) = mpsc::channel::<Bytes>(QUEUE_FRAMES);
    let writer = tokio::task::spawn_blocking(move || -> (Sha256, u64, io::Result<()>) {
        let mut hasher = hasher;
        let mut written = 0u64;
        let result = (|| {
            let file = OpenOptions::new().append(true).open(&part)?;
            let mut out = BufWriter::with_capacity(WRITE_BUFFER, file);
            while let Some(frame) = queue.blocking_recv() {
                out.write_all(&frame)?;
                hasher.update(&frame);
                written += frame.len() as u64;
            }
            out.flush()
        })();
        (hasher, written, result)
    });

    let mut stream = body.into_data_stream();
    let mut sent = 0u64;
    let end = loop {
        match tokio::time::timeout(IDLE_TIMEOUT, stream.next()).await {
            Ok(Some(Ok(frame))) => {
                let room = limit - sent;
                let (frame, too_long) = if frame.len() as u64 > room {
                    (frame.slice(..room as usize), true)
                } else {
                    (frame, false)
                };
                sent += frame.len() as u64;
                if !frame.is_empty() && frames.send(frame).await.is_err() {
                    // The writer stopped: the disk failed. Its error is reported below.
                    break BodyEnd::Interrupted;
                }
                if too_long {
                    break BodyEnd::TooLong;
                }
            }
            Ok(Some(Err(_))) | Err(_) => break BodyEnd::Interrupted,
            Ok(None) => break BodyEnd::Complete,
        }
    };
    drop(frames);

    match writer.await {
        Ok((hasher, written, Ok(()))) => Appended {
            written,
            hasher: Some(hasher),
            end,
            error: None,
        },
        Ok((_, written, Err(error))) => Appended {
            // Some of the counted bytes may still have been in the buffer: trust only the file.
            written,
            hasher: None,
            end,
            error: Some(error),
        },
        Err(join) => Appended {
            written: 0,
            hasher: None,
            end,
            error: Some(io::Error::other(join.to_string())),
        },
    }
}

/// Rebuilds the hash of a partial file and returns it with the file's length.
pub async fn rehash(part: PathBuf) -> io::Result<(Sha256, u64)> {
    tokio::task::spawn_blocking(move || {
        let mut file = File::open(&part)?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; READ_BUFFER];
        let mut length = 0u64;
        loop {
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            length += read as u64;
        }
        Ok((hasher, length))
    })
    .await
    .map_err(|join| io::Error::other(join.to_string()))?
}

/// Creates an empty partial file that only the server can read.
pub fn create_part(part: &Path) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(part)
        .map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(chunks: Vec<&'static [u8]>) -> Body {
        let stream = futures_util::stream::iter(
            chunks
                .into_iter()
                .map(|c| Ok::<_, io::Error>(Bytes::from_static(c))),
        );
        Body::from_stream(stream)
    }

    #[tokio::test]
    async fn appends_and_hashes_across_requests() {
        let dir = tempfile::tempdir().unwrap();
        let part = dir.path().join("u.part");
        create_part(&part).unwrap();

        let first = append(
            part.clone(),
            Sha256::new(),
            body(vec![b"hello ", b"wor"]),
            11,
        )
        .await;
        assert_eq!((first.written, first.end), (9, BodyEnd::Complete));
        let second = append(part.clone(), first.hasher.unwrap(), body(vec![b"ld!!!"]), 2).await;
        assert_eq!((second.written, second.end), (2, BodyEnd::TooLong));

        assert_eq!(std::fs::read(&part).unwrap(), b"hello world");
        let expected: [u8; 32] = Sha256::digest(b"hello world").into();
        let streamed: [u8; 32] = second.hasher.unwrap().finalize().into();
        assert_eq!(streamed, expected);

        let (rebuilt, length) = rehash(part).await.unwrap();
        assert_eq!(length, 11);
        let rebuilt: [u8; 32] = rebuilt.finalize().into();
        assert_eq!(rebuilt, expected);
    }

    #[tokio::test]
    async fn a_broken_connection_keeps_what_arrived() {
        let dir = tempfile::tempdir().unwrap();
        let part = dir.path().join("u.part");
        create_part(&part).unwrap();
        let stream = futures_util::stream::iter(vec![
            Ok(Bytes::from_static(b"abc")),
            Err(io::Error::other("connection reset")),
        ]);
        let appended = append(part.clone(), Sha256::new(), Body::from_stream(stream), 100).await;
        assert_eq!((appended.written, appended.end), (3, BodyEnd::Interrupted));
        assert_eq!(std::fs::read(&part).unwrap(), b"abc");
    }
}
