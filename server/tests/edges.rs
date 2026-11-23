//! Unusual but real: photos from 1900 and 2100, a leap day, the farthest time zones, a burst of
//! photos in the same second, names with emoji.

mod common;

use common::{Api, LUCAS_PASSWORD, device, iphone, random_bytes};
use halden::accounts::Role;
use serde_json::json;
use uuid::Uuid;

fn library_names(api: &Api) -> Vec<String> {
    let mut names = Vec::new();
    let mut folders = vec![api.config.storage.library_dir.clone()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(folder).unwrap().flatten() {
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                folders.push(entry.path());
            } else {
                names.push(
                    entry
                        .path()
                        .strip_prefix(&api.config.storage.library_dir)
                        .unwrap()
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
    }
    names.sort();
    names
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn photos_from_any_time_and_place_get_the_right_name() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    for (taken_at, offset, expected) in [
        // 1 January 1900, midnight in London.
        (
            -2_208_988_800_000i64,
            0,
            "lucas/1900/01/1900-01-01_00-00-00.heic",
        ),
        // The last second of 2100 on Baker Island (UTC−12).
        (
            4_133_980_799_000 + 12 * 3_600_000,
            -720,
            "lucas/2100/12/2100-12-31_23-59-59.heic",
        ),
        // A leap day, noon in Kiribati (UTC+14).
        (
            1_835_438_400_000 - 14 * 3_600_000,
            840,
            "lucas/2028/02/2028-02-29_12-00-00.heic",
        ),
        // The night the clocks go forward in Germany: 01:59:59 in winter time, then …
        (
            1_774_745_999_000,
            60,
            "lucas/2026/03/2026-03-29_01-59-59.heic",
        ),
        // … one second later it is 03:00:00 in summer time.
        (
            1_774_746_000_000,
            120,
            "lucas/2026/03/2026-03-29_03-00-00.heic",
        ),
    ] {
        let asset = api
            .upload(
                &token,
                &Uuid::new_v4().to_string(),
                &random_bytes(1000),
                "image/heic",
                json!({ "takenAt": taken_at, "timeZoneOffsetMinutes": offset }),
            )
            .await;
        assert_eq!(asset["takenAt"], taken_at, "{expected}");
        assert_eq!(asset["timeZoneOffsetMinutes"], offset, "{expected}");
        assert!(
            library_names(&api).contains(&expected.to_string()),
            "{expected} not in {:?}",
            library_names(&api)
        );
    }
    api.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_in_one_second_gets_numbered_names() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let same_second = json!({ "takenAt": 1_795_443_730_000i64, "timeZoneOffsetMinutes": 60 });
    // Ten photos at once, from parallel requests.
    let mut uploads = Vec::new();
    for _ in 0..10 {
        let api_ref = &api;
        let token = token.clone();
        let metadata = same_second.clone();
        uploads.push(async move {
            api_ref
                .upload(
                    &token,
                    &Uuid::new_v4().to_string(),
                    &random_bytes(2000),
                    "image/heic",
                    metadata,
                )
                .await
        });
    }
    futures_util::future::join_all(uploads).await;
    let names = library_names(&api);
    assert_eq!(names.len(), 10, "{names:?}");
    assert!(names.contains(&"lucas/2026/11/2026-11-23_15-22-10.heic".to_string()));
    for n in 2..=10 {
        let name = format!("lucas/2026/11/2026-11-23_15-22-10_{n}.heic");
        assert!(names.contains(&name), "{name} missing in {names:?}");
    }
    api.stop().await;
}

#[tokio::test]
async fn names_with_emoji_and_their_limits() {
    let api = Api::start().await;
    let owner = api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api
        .token(
            "lucas",
            LUCAS_PASSWORD,
            device("📷 Lucas’ iPhone 15 – Küche", "install-emoji"),
        )
        .await;
    let me = api.get("/api/v1/me", &token).await;
    assert_eq!(me.body["device"]["name"], "📷 Lucas’ iPhone 15 – Küche");
    let longest = "é".repeat(64);
    let fine = api
        .call(
            reqwest::Method::PATCH,
            &format!("/api/v1/admin/users/{}", owner.id),
            Some(&token),
            Some(json!({ "displayName": longest })),
        )
        .await;
    assert_eq!(fine.status, 200, "{}", fine.body);
    let too_long = api
        .call(
            reqwest::Method::PATCH,
            &format!("/api/v1/admin/users/{}", owner.id),
            Some(&token),
            Some(json!({ "displayName": "é".repeat(65) })),
        )
        .await;
    assert_eq!(too_long.status, 422, "{}", too_long.body);
    let control = api
        .call(
            reqwest::Method::PATCH,
            &format!("/api/v1/admin/users/{}", owner.id),
            Some(&token),
            Some(json!({ "displayName": "Lucas\u{0}\u{1b}[31m" })),
        )
        .await;
    assert_eq!(
        control.status, 422,
        "no control characters (terminal tricks): {}",
        control.body
    );
    // Usernames become folder names, so they stay plain.
    let refused = api
        .post(
            "/api/v1/admin/users",
            Some(&token),
            json!({ "username": "lücas", "currentPassword": LUCAS_PASSWORD }),
        )
        .await;
    assert_eq!(refused.status, 422);
    api.stop().await;
}
