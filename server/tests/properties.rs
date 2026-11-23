//! Random inputs by the thousand (proptest): the parsers never panic and never let a path leave
//! its folder; uploads arrive intact however they are cut up and interrupted; and a model test
//! of the whole library: random sequences of uploads, duplicates, corrections, trash, restore
//! and deleting, after which every device, whenever it last synced, ends up with exactly the
//! server's state.

mod common;

use std::{
    collections::{BTreeMap, HashSet},
    path::{Path, PathBuf},
};

use chrono::{DateTime, FixedOffset, TimeZone};
use common::{Api, LUCAS_PASSWORD, iphone, sha_hex};
use halden::{
    accounts::Role,
    files::{RangeRequest, parse_range},
    library::paths::{PathTemplate, first_free, resolve},
};
use proptest::prelude::*;
use reqwest::Method;
use serde_json::json;
use uuid::Uuid;

/// How many random cases: `base`, times `HALDEN_TEST_SCALE` (the nightly run uses more).
fn cases(base: u32) -> ProptestConfig {
    let scale = std::env::var("HALDEN_TEST_SCALE")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(1)
        .max(1);
    ProptestConfig::with_cases(base * scale)
}

proptest! {
    #![proptest_config(cases(5000))]

    /// Whatever arrives as `Range`, the answer is a range inside the file or the whole file.
    #[test]
    fn ranges_stay_inside_the_file(header in ".{0,40}", size in 0u64..10_000_000) {
        match parse_range(&header, size) {
            RangeRequest::Partial(range) => {
                prop_assert!(range.start <= range.end, "{header:?} {size}");
                prop_assert!(range.end < size, "{header:?} {size}");
            }
            RangeRequest::Full | RangeRequest::Unsatisfiable => {}
        }
    }

    #[test]
    fn well_formed_ranges_are_honoured(size in 1u64..10_000_000, a in 0u64..10_000_000, length in 0u64..1_000_000) {
        let start = a % size;
        let end = (start + length).min(size - 1);
        prop_assert_eq!(
            parse_range(&format!("bytes={start}-{end}"), size),
            RangeRequest::Partial(halden::files::ByteRange { start, end })
        );
        let suffix = length % size + 1;
        prop_assert_eq!(
            parse_range(&format!("bytes=-{suffix}"), size),
            RangeRequest::Partial(halden::files::ByteRange { start: size - suffix, end: size - 1 })
        );
    }

    /// Any template that is accepted makes, for any user and any moment in any time zone, a
    /// path that stays inside the library: no empty folders, no `.` or `..`, no hidden names.
    #[test]
    fn templates_never_leave_the_library(
        template in "[a-z{}/ ._-]{0,12}(\\{(user|year|month|day|date|time|hour|minute|second)\\}[a-z/ ._-]{0,4}){0,6}",
        user in "[a-z0-9][a-z0-9._-]{0,31}",
        seconds in -2_208_988_800i64..4_102_444_800i64,
        offset_minutes in -720i32..=840,
    ) {
        let Ok(template) = PathTemplate::parse(&template) else {
            return Ok(());
        };
        let offset = FixedOffset::east_opt(offset_minutes * 60).unwrap();
        let time: DateTime<FixedOffset> = offset.timestamp_opt(seconds, 0).unwrap();
        let path = template.render(&user, time);
        let text = path.to_string_lossy();
        prop_assert!(!text.is_empty());
        for segment in text.split('/') {
            prop_assert!(!segment.is_empty(), "{template:?} → {text:?}");
            prop_assert!(segment != "." && segment != "..", "{text:?}");
            prop_assert!(!segment.starts_with('.'), "{text:?}");
        }
        let root = Path::new("/library");
        let full = resolve(root, &text).expect("a made path always resolves");
        prop_assert!(full.starts_with(root));
    }

    /// `resolve` is the last line of defence: whatever is stored, it never points outside.
    #[test]
    fn resolve_never_leaves_its_root(relative in "(\\.\\.|\\.|/|[a-z]{1,3}|%2e|\\\\){0,8}") {
        let root = Path::new("/library");
        if let Some(full) = resolve(root, &relative) {
            prop_assert!(full.starts_with(root));
            prop_assert!(!full.components().any(|c| matches!(c, std::path::Component::ParentDir)));
        }
    }

    /// The next free name is never one that is taken, and is the lowest free number.
    #[test]
    fn free_names_are_free(taken in proptest::collection::hash_set(1u32..20, 0..15)) {
        let base = Path::new("lucas/2026/11/2026-11-23_15-22-10");
        let names: HashSet<PathBuf> = taken
            .iter()
            .map(|n| halden::library::paths::numbered(base, *n, "heic"))
            .collect();
        let free = first_free(base, "heic", |candidate| names.contains(candidate));
        prop_assert!(!names.contains(&free));
        let lowest = (1u32..).find(|n| !taken.contains(n)).unwrap();
        prop_assert_eq!(free, halden::library::paths::numbered(base, lowest, "heic"));
    }
}

/// Runs async code inside a proptest case.
fn block_on<T>(work: impl std::future::Future<Output = T>) -> T {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap()
        .block_on(work)
}

#[derive(Debug, Clone)]
enum Piece {
    /// Send this many bytes in one request.
    Whole(usize),
    /// Send this many, then break the connection after `arrived` of them.
    Broken { length: usize, arrived: usize },
}

fn pieces() -> impl Strategy<Value = Vec<Piece>> {
    proptest::collection::vec(
        prop_oneof![
            (1usize..400_000).prop_map(Piece::Whole),
            (2usize..400_000)
                .prop_flat_map(|length| (Just(length), 1..length))
                .prop_map(|(length, arrived)| Piece::Broken { length, arrived }),
        ],
        1..8,
    )
}

proptest! {
    #![proptest_config(cases(24))]

    /// However the phone cuts a file up, and wherever connections break, the server keeps
    /// exactly what arrived, tells the right offset, and the finished file has the right hash.
    #[test]
    fn uploads_arrive_intact_however_they_are_sent(size in 1usize..1_500_000, plan in pieces()) {
        block_on(async move {
            let api = Api::start().await;
            api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
            let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
            let data = common::random_bytes(size);
            let created = api
                .post(
                    "/api/v1/uploads",
                    Some(&token),
                    json!({ "assetId": Uuid::new_v4(), "size": size, "sha256": sha_hex(&data),
                            "mimeType": "video/quicktime" }),
                )
                .await;
            let id = created.body["uploadId"].as_str().unwrap().to_string();
            let url = api.url(&format!("/api/v1/uploads/{id}"));
            let mut plan = plan.into_iter();
            let mut finished = false;
            for _ in 0..200 {
                let state = api.get(&format!("/api/v1/uploads/{id}"), &token).await;
                if state.body["state"] == "completed" {
                    finished = true;
                    break;
                }
                let offset = state.body["offset"].as_u64().unwrap() as usize;
                let piece = plan.next().unwrap_or(Piece::Whole(size));
                let (length, arrived) = match piece {
                    Piece::Whole(n) => (n, None),
                    Piece::Broken { length, arrived } => (length, Some(arrived)),
                };
                let end = (offset + length).min(size);
                let chunk = data[offset..end].to_vec();
                let body = match arrived {
                    None => reqwest::Body::from(chunk),
                    Some(arrived) => {
                        let arrived = arrived.min(chunk.len());
                        let parts: Vec<Result<Vec<u8>, std::io::Error>> = vec![
                            Ok(chunk[..arrived].to_vec()),
                            Err(std::io::Error::other("the train went into a tunnel")),
                        ];
                        reqwest::Body::wrap_stream(futures_util::stream::iter(parts))
                    }
                };
                let _ = api
                    .http
                    .patch(&url)
                    .bearer_auth(&token)
                    .header("upload-offset", offset.to_string())
                    .body(body)
                    .send()
                    .await;
                // The answer may be lost with the broken connection; the next round asks.
                tokio::time::sleep(std::time::Duration::from_millis(30)).await;
            }
            assert!(finished, "the upload never finished");
            let files = std::fs::read_dir(api.config.incoming_dir()).unwrap().count();
            assert_eq!(files, 0, "no partial file is left");
            let sync = api.get("/api/v1/sync", &token).await;
            assert_eq!(sync.body["assets"][0]["files"][0]["sha256"], sha_hex(&data));
            api.stop().await;
        });
    }
}

#[derive(Debug, Clone)]
enum Op {
    /// A new photo with new content.
    Upload,
    /// A new id, but the content of photo n (a duplicate).
    Duplicate(usize),
    Trash(Vec<usize>),
    Restore(Vec<usize>),
    Delete(Vec<usize>),
    Retitle(usize, u8),
    /// A device takes a snapshot of its sync position.
    Remember,
}

fn op() -> impl Strategy<Value = Op> {
    let some = || proptest::collection::vec(0usize..40, 1..4);
    prop_oneof![
        4 => Just(Op::Upload),
        1 => (0usize..40).prop_map(Op::Duplicate),
        2 => some().prop_map(Op::Trash),
        1 => some().prop_map(Op::Restore),
        1 => some().prop_map(Op::Delete),
        2 => (0usize..40, any::<u8>()).prop_map(|(n, t)| Op::Retitle(n, t)),
        1 => Just(Op::Remember),
    ]
}

#[derive(Debug, Clone, PartialEq)]
struct Seen {
    trashed: bool,
    deleted: bool,
    title: Option<String>,
    hash: Option<String>,
}

/// Brings a device's copy up to date from `since`, page by page, like the app does.
async fn sync_into(api: &Api, token: &str, since: i64, copy: &mut BTreeMap<String, Seen>) -> i64 {
    let mut since = since;
    loop {
        let page = api
            .get(&format!("/api/v1/sync?since={since}&limit=7"), token)
            .await
            .body;
        assert_ne!(page["resetRequired"], true);
        for asset in page["assets"].as_array().unwrap() {
            let id = asset["id"].as_str().unwrap().to_string();
            copy.insert(
                id,
                Seen {
                    trashed: !asset["trashedAt"].is_null(),
                    deleted: !asset["deletedAt"].is_null(),
                    title: asset["title"].as_str().map(str::to_string),
                    hash: asset["files"]
                        .as_array()
                        .and_then(|files| files.iter().find(|f| f["role"] == "original"))
                        .and_then(|f| f["sha256"].as_str())
                        .map(str::to_string),
                },
            );
        }
        since = page["nextSince"].as_i64().unwrap();
        if page["hasMore"] != true {
            return since;
        }
    }
}

proptest! {
    #![proptest_config(cases(32))]

    #[test]
    fn every_device_ends_with_the_servers_state(ops in proptest::collection::vec(op(), 1..40)) {
        block_on(async move {
            let api = Api::start().await;
            api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
            let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
            // What the server should hold: id → expected state.
            let mut model: BTreeMap<String, Seen> = BTreeMap::new();
            let mut ids: Vec<String> = Vec::new();
            let mut contents: Vec<Vec<u8>> = Vec::new();
            // Devices that synced at some point: (their copy, their position).
            let mut devices: Vec<(BTreeMap<String, Seen>, i64)> = vec![(BTreeMap::new(), 0)];
            let pick = |list: &[String], picks: &[usize]| -> Vec<String> {
                if list.is_empty() {
                    return Vec::new();
                }
                picks.iter().map(|n| list[n % list.len()].clone()).collect()
            };
            for op in ops {
                match op {
                    Op::Upload | Op::Duplicate(_) => {
                        let data = match op {
                            Op::Duplicate(n) if !contents.is_empty() => contents[n % contents.len()].clone(),
                            _ => common::random_bytes(500 + ids.len()),
                        };
                        let id = Uuid::new_v4().to_string();
                        let created = api
                            .post(
                                "/api/v1/uploads",
                                Some(&token),
                                json!({ "assetId": id, "size": data.len(), "sha256": sha_hex(&data),
                                        "mimeType": "image/heic" }),
                            )
                            .await;
                        match created.body["state"].as_str() {
                            // Same content as a photo already there: stored once, under the
                            // existing id.
                            Some("duplicate") => {}
                            _ => {
                                let upload = created.body["uploadId"].as_str().unwrap();
                                let done = Api::reply(
                                    api.http
                                        .patch(api.url(&format!("/api/v1/uploads/{upload}")))
                                        .bearer_auth(&token)
                                        .header("upload-offset", "0")
                                        .body(data.clone())
                                        .send()
                                        .await
                                        .unwrap(),
                                )
                                .await;
                                assert_eq!(done.body["state"], "completed", "{}", done.body);
                                model.insert(
                                    id.clone(),
                                    Seen { trashed: false, deleted: false, title: None, hash: Some(sha_hex(&data)) },
                                );
                                ids.push(id);
                                contents.push(data);
                            }
                        }
                    }
                    Op::Trash(picks) => {
                        let chosen = pick(&ids, &picks);
                        api.post("/api/v1/assets/trash", Some(&token), json!({ "ids": chosen })).await;
                        for id in chosen {
                            let seen = model.get_mut(&id).unwrap();
                            if !seen.deleted {
                                seen.trashed = true;
                            }
                        }
                    }
                    Op::Restore(picks) => {
                        let chosen = pick(&ids, &picks);
                        api.post("/api/v1/assets/restore", Some(&token), json!({ "ids": chosen })).await;
                        for id in chosen {
                            let seen = model.get_mut(&id).unwrap();
                            if !seen.deleted {
                                seen.trashed = false;
                            }
                        }
                    }
                    Op::Delete(picks) => {
                        let chosen = pick(&ids, &picks);
                        api.post("/api/v1/assets/delete", Some(&token), json!({ "ids": chosen })).await;
                        for id in chosen {
                            let seen = model.get_mut(&id).unwrap();
                            // Only from the trash.
                            if seen.trashed && !seen.deleted {
                                *seen = Seen { trashed: true, deleted: true, title: None, hash: None };
                            }
                        }
                    }
                    Op::Retitle(n, title) => {
                        if ids.is_empty() {
                            continue;
                        }
                        let id = ids[n % ids.len()].clone();
                        let title = format!("title {title}");
                        let reply = api
                            .call(
                                Method::PATCH,
                                &format!("/api/v1/assets/{id}"),
                                Some(&token),
                                Some(json!({ "title": title })),
                            )
                            .await;
                        let seen = model.get_mut(&id).unwrap();
                        if seen.deleted {
                            assert_eq!(reply.status, 404, "a tombstone can't be corrected");
                        } else {
                            assert_eq!(reply.status, 200, "{}", reply.body);
                            seen.title = Some(title);
                        }
                    }
                    Op::Remember => {
                        let (mut copy, since) = devices.last().cloned().unwrap();
                        let next = sync_into(&api, &token, since, &mut copy).await;
                        devices.push((copy, next));
                    }
                }
            }
            // Every device, from wherever it stopped, ends with exactly the server's state.
            for (mut copy, since) in devices {
                sync_into(&api, &token, since, &mut copy).await;
                assert_eq!(copy, model, "a device that last synced at {since}");
            }
            let mut fresh = BTreeMap::new();
            sync_into(&api, &token, 0, &mut fresh).await;
            assert_eq!(fresh, model, "a new device");
            api.stop().await;
        });
    }
}
