//! Backups against the real server: the mirror copies and checks every original, notices a
//! missing disk, follows deletions; the database is backed up at start and can be restored.

mod common;

use std::{path::Path, time::Duration};

use common::{Api, LUCAS_PASSWORD, iphone, random_bytes};
use halden::{
    accounts::{self, NewUser, Role},
    backup::{database, mirror},
    db::Db,
};
use serde_json::json;
use uuid::Uuid;

async fn owner(api: &Api) -> String {
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.token("lucas", LUCAS_PASSWORD, iphone()).await
}

async fn wait_for(path: &Path) {
    for _ in 0..300 {
        if path.exists() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("{} never appeared", path.display());
}

const TAKEN: i64 = 1_795_443_730_000;

#[tokio::test]
async fn without_a_mirror_the_apps_hear_there_is_only_one_copy() {
    let api = Api::start().await;
    let token = owner(&api).await;
    let me = api.get("/api/v1/me", &token).await;
    assert_eq!(me.body["backup"]["mirror"], "none");
    assert_eq!(me.body["backup"]["onlyOneCopy"], true);
    // A database backup was made when the server started.
    assert!(me.body["backup"]["lastDatabaseBackupAt"].is_i64());
    assert_eq!(database::list(&api.config).len(), 1);
    api.stop().await;
}

#[tokio::test]
async fn the_mirror_gets_a_checked_copy_of_every_original() {
    let mirror_dir = tempfile::tempdir().unwrap();
    let root = mirror::prepare(mirror_dir.path(), Path::new("/nonexistent")).unwrap();
    let mirror_root = root.clone();
    let api = Api::start_with(move |config| {
        config.mirror.path = Some(mirror_root);
        config.jobs.thumbnail_delay_minutes = 600;
    })
    .await;
    let token = owner(&api).await;

    let me = api.get("/api/v1/me", &token).await;
    assert_eq!(me.body["backup"]["mirror"], "ok");
    // Both folders are on the test machine's one disk, so it is still only one copy.
    assert_eq!(me.body["backup"]["mirrorOnSameDisk"], true);
    assert_eq!(me.body["backup"]["onlyOneCopy"], true);
    // The start-up database backup went to the mirror too.
    let backups = std::fs::read_dir(root.join(".halden/backups"))
        .unwrap()
        .count();
    assert_eq!(backups, 1);

    let data = random_bytes(200_000);
    let id = Uuid::new_v4().to_string();
    api.upload(
        &token,
        &id,
        &data,
        "image/heic",
        json!({ "takenAt": TAKEN, "timeZoneOffsetMinutes": 60 }),
    )
    .await;
    let copy = root.join("lucas/2026/11/2026-11-23_15-22-10.heic");
    wait_for(&copy).await;
    assert_eq!(std::fs::read(&copy).unwrap(), data);
    let db = Db::open(&api.config.db_path()).await.unwrap();
    for _ in 0..100 {
        if mirror::waiting(&db).await.unwrap() == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(mirror::waiting(&db).await.unwrap(), 0);

    // Deleting for good removes the copy as well.
    api.post("/api/v1/assets/trash", Some(&token), json!({ "ids": [id] }))
        .await;
    api.post(
        "/api/v1/assets/delete",
        Some(&token),
        json!({ "ids": [id] }),
    )
    .await;
    assert!(!copy.exists());

    // An unplugged disk (no marker): nothing is written, the job waits and says why.
    std::fs::remove_file(root.join(mirror::MARKER)).unwrap();
    let later = Uuid::new_v4().to_string();
    api.upload(&token, &later, &random_bytes(1000), "image/heic", json!({}))
        .await;
    let mut error = None;
    for _ in 0..100 {
        let found: Option<(Option<String>,)> =
            sqlx::query_as("SELECT last_error FROM jobs WHERE kind = 'mirror' AND asset_id = ?")
                .bind(&later)
                .fetch_optional(db.read())
                .await
                .unwrap();
        if let Some((Some(message),)) = found {
            error = Some(message);
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(error.unwrap().contains("not reachable"));
    let status = mirror::compute_status(&db, &api.config).await;
    assert_eq!(status.mirror, mirror::MirrorState::Unreachable);
    assert_eq!(status.files_waiting, 1);
    db.close().await;
    api.stop().await;
}

#[tokio::test]
async fn a_backup_can_be_restored_once_the_server_is_stopped() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let config = api.config.clone();
    let db = Db::open(&config.db_path()).await.unwrap();
    let backup = database::make(&db, &config).await.unwrap();
    accounts::create_user(
        &db,
        NewUser {
            username: "later",
            display_name: None,
            role: Role::Member,
            password_hash: None,
        },
    )
    .await
    .unwrap();
    db.close().await;

    let refused = database::restore(&config, &backup.path).await.unwrap_err();
    assert!(format!("{refused:#}").contains("is running"), "{refused:#}");
    let _folders = api.stop_keeping_files().await;

    let aside = database::restore(&config, &backup.path).await.unwrap();
    assert!(aside.exists());
    let restored = Db::open(&config.db_path()).await.unwrap();
    assert!(
        accounts::user_by_name(&restored, "lucas")
            .await
            .unwrap()
            .is_some()
    );
    assert!(
        accounts::user_by_name(&restored, "later")
            .await
            .unwrap()
            .is_none(),
        "the restored database is the backup's"
    );
    restored.close().await;
    let before = Db::open(&aside).await.unwrap();
    assert!(
        accounts::user_by_name(&before, "later")
            .await
            .unwrap()
            .is_some()
    );
    before.close().await;
}
