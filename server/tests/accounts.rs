//! Accounts, sign-in, pairing and devices, against the real server over pinned TLS 1.3.

mod common;

use common::{ANNA_PASSWORD, Api, LUCAS_PASSWORD, client, device, iphone, mac, start_server, url};
use halden::accounts::{self, Role};
use reqwest::Method;
use serde_json::{Value, json};

#[tokio::test]
async fn login_gives_a_token_that_opens_me() {
    let api = Api::start().await;
    api.add_user("Lucas", LUCAS_PASSWORD, Role::Owner).await;

    let reply = api.login("lucas", LUCAS_PASSWORD, iphone()).await;
    assert_eq!(reply.status, 200, "{}", reply.body);
    let token = reply.body["token"].as_str().unwrap().to_string();
    assert!(token.starts_with("hd1_"));
    assert_eq!(reply.body["user"]["role"], "owner");
    assert_eq!(
        reply.body["device"]["confirmed"], true,
        "a first device needs no confirmation"
    );
    assert!(reply.body["device"].get("installationId").is_none());

    let me = api.get("/api/v1/me", &token).await;
    assert_eq!(me.status, 200);
    assert_eq!(me.body["user"]["username"], "Lucas");
    assert_eq!(me.body["device"]["name"], "Lucas' iPhone");
    assert_eq!(me.body["unconfirmedDevices"], 0);

    let anonymous = api.call(Method::GET, "/api/v1/me", None, None).await;
    assert_eq!((anonymous.status, anonymous.error()), (401, "unauthorized"));
    let garbage = api
        .get(
            "/api/v1/me",
            "hd1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        )
        .await;
    assert_eq!((garbage.status, garbage.error()), (401, "unauthorized"));

    // A second device signed in with the password shows up as new on the first one.
    let mac = api.login("lucas", LUCAS_PASSWORD, mac()).await;
    assert_eq!(mac.body["device"]["confirmed"], false);
    let mac_token = mac.body["token"].as_str().unwrap();
    let mac_id = mac.body["device"]["id"].as_str().unwrap();
    assert_eq!(
        api.get("/api/v1/me", &token).await.body["unconfirmedDevices"],
        1
    );

    let itself = api
        .post(
            &format!("/api/v1/devices/{mac_id}/confirm"),
            Some(mac_token),
            json!({}),
        )
        .await;
    assert_eq!((itself.status, itself.error()), (403, "forbidden"));
    let confirmed = api
        .post(
            &format!("/api/v1/devices/{mac_id}/confirm"),
            Some(&token),
            json!({}),
        )
        .await;
    assert_eq!(confirmed.status, 204);
    assert_eq!(
        api.get("/api/v1/me", &token).await.body["unconfirmedDevices"],
        0
    );

    let unknown_route = api.get("/api/v1/nope", &token).await;
    assert_eq!(
        (unknown_route.status, unknown_route.error()),
        (404, "not_found")
    );
    api.stop().await;
}

#[tokio::test]
async fn wrong_password_and_unknown_user_look_the_same_and_get_slowed_down() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;

    let wrong = api.login("lucas", "not the password", iphone()).await;
    let unknown = api.login("nobody", "not the password", iphone()).await;
    assert_eq!(wrong.status, 401);
    assert_eq!(wrong.error(), "invalid_credentials");
    assert_eq!(wrong.body, unknown.body);
    assert_eq!(unknown.status, 401);

    for _ in 0..4 {
        assert_eq!(
            api.login("lucas", "still wrong", iphone()).await.status,
            401
        );
    }
    // After five failures even the right password has to wait.
    let throttled = api.login("lucas", LUCAS_PASSWORD, iphone()).await;
    assert_eq!((throttled.status, throttled.error()), (429, "rate_limited"));
    assert_eq!(throttled.retry_after.as_deref(), Some("30"));

    // Malformed requests get JSON errors too.
    let broken = api
        .post("/api/v1/auth/login", None, json!({ "username": "lucas" }))
        .await;
    assert_eq!(broken.error(), "validation_failed");
    api.stop().await;
}

#[tokio::test]
async fn a_pairing_code_works_once() {
    let api = Api::start().await;
    let lucas = api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let token = api.token("lucas", LUCAS_PASSWORD, iphone()).await;

    let created = api
        .post("/api/v1/pairing-codes", Some(&token), json!({}))
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    let code = created.body["code"].as_str().unwrap().to_string();
    assert_eq!(code.len(), 11);
    assert_eq!(&code[5..6], "-");
    assert_eq!(created.body["userId"], lucas.id.as_str());
    let link = created.body["url"].as_str().unwrap();
    assert!(link.starts_with("halden://pair?v=1&id="), "{link}");
    assert!(link.contains(&format!("&fp={}", api.server.fingerprint.hex())));
    assert!(link.contains(&format!("&port={}", api.server.addr.port())));
    assert!(link.contains(&format!("&code={}", code.replace('-', ""))));

    // Typed in lower case and without the dash still works.
    let typed = code.replace('-', "").to_lowercase();
    let paired = api
        .post(
            "/api/v1/auth/pair",
            None,
            json!({ "code": typed, "device": mac() }),
        )
        .await;
    assert_eq!(paired.status, 200, "{}", paired.body);
    assert_eq!(paired.body["device"]["confirmed"], true);
    let mac_token = paired.body["token"].as_str().unwrap();
    assert_eq!(
        api.get("/api/v1/me", mac_token).await.body["user"]["username"],
        "lucas"
    );

    let again = api
        .post(
            "/api/v1/auth/pair",
            None,
            json!({ "code": code, "device": mac() }),
        )
        .await;
    assert_eq!((again.status, again.error()), (401, "invalid_credentials"));
    for wrong in ["AAAAA-AAAAA", "x"] {
        let reply = api
            .post(
                "/api/v1/auth/pair",
                None,
                json!({ "code": wrong, "device": mac() }),
            )
            .await;
        assert_eq!((reply.status, reply.error()), (401, "invalid_credentials"));
    }

    // An expired code is refused.
    let late = api
        .post("/api/v1/pairing-codes", Some(&token), json!({}))
        .await;
    let pool = api.pool().await;
    sqlx::query("UPDATE pairing_codes SET expires_at = 0 WHERE used_at IS NULL")
        .execute(pool.write())
        .await
        .unwrap();
    pool.close().await;
    let expired = api
        .post(
            "/api/v1/auth/pair",
            None,
            json!({ "code": late.body["code"], "device": mac() }),
        )
        .await;
    assert_eq!(
        (expired.status, expired.error()),
        (401, "invalid_credentials")
    );
    api.stop().await;
}

#[tokio::test]
async fn signed_out_blocked_and_disabled_stay_out() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let anna = api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let owner = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let annas_phone = || device("Anna's iPhone", "install-anna-1");

    // Signing out.
    let first = api.token("anna", ANNA_PASSWORD, annas_phone()).await;
    let logout = api
        .post("/api/v1/auth/logout", Some(&first), json!({}))
        .await;
    assert_eq!(logout.status, 204);
    assert_eq!(api.get("/api/v1/me", &first).await.status, 401);

    // Blocking.
    let second = api.token("anna", ANNA_PASSWORD, annas_phone()).await;
    let devices = api.get("/api/v1/devices", &owner).await;
    let annas = devices.body["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["userId"] == anna.id.as_str())
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let block = api
        .post(
            &format!("/api/v1/devices/{annas}/block"),
            Some(&owner),
            json!({}),
        )
        .await;
    assert_eq!(block.status, 204);
    assert_eq!(api.get("/api/v1/me", &second).await.status, 401);
    let refused = api.login("anna", ANNA_PASSWORD, annas_phone()).await;
    assert_eq!((refused.status, refused.error()), (403, "device_blocked"));
    // A fresh installation gets in with the password: the password is the real protection.
    let third = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-2"),
        )
        .await;

    // Disabling the account.
    let disable = api
        .call(
            Method::PATCH,
            &format!("/api/v1/admin/users/{}", anna.id),
            Some(&owner),
            Some(json!({ "disabled": true })),
        )
        .await;
    assert_eq!(disable.status, 200, "{}", disable.body);
    assert_eq!(disable.body["disabled"], true);
    assert_eq!(api.get("/api/v1/me", &third).await.status, 401);
    let disabled = api
        .login(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-3"),
        )
        .await;
    assert_eq!((disabled.status, disabled.error()), (403, "forbidden"));
    api.stop().await;
}

#[tokio::test]
async fn only_owners_manage_accounts_and_must_confirm_with_their_password() {
    let api = Api::start().await;
    let lucas = api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let anna = api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let owner = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let member = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;

    let denied = api.get("/api/v1/admin/users", &member).await;
    assert_eq!((denied.status, denied.error()), (403, "forbidden"));
    let listed = api.get("/api/v1/admin/users", &owner).await;
    assert_eq!(listed.body["users"].as_array().unwrap().len(), 2);

    let ben = json!({ "username": "ben", "password": "ben's password!" });
    let no_password = api
        .post("/api/v1/admin/users", Some(&owner), ben.clone())
        .await;
    assert_eq!(
        (no_password.status, no_password.error()),
        (403, "password_required")
    );
    let mut wrong = ben.clone();
    wrong["currentPassword"] = json!("guess");
    let wrong = api.post("/api/v1/admin/users", Some(&owner), wrong).await;
    assert_eq!((wrong.status, wrong.error()), (403, "invalid_credentials"));
    let mut right = ben.clone();
    right["currentPassword"] = json!(LUCAS_PASSWORD);
    let created = api
        .post("/api/v1/admin/users", Some(&owner), right.clone())
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    assert_eq!(created.body["role"], "member");
    let taken = api.post("/api/v1/admin/users", Some(&owner), right).await;
    assert_eq!((taken.status, taken.error()), (409, "conflict"));
    assert_eq!(
        api.token("ben", "ben's password!", iphone()).await.len(),
        47
    );

    // The last owner can't be deleted or demoted.
    let lucas_path = format!("/api/v1/admin/users/{}", lucas.id);
    let delete_self = api
        .call(
            Method::DELETE,
            &lucas_path,
            Some(&owner),
            Some(json!({ "currentPassword": LUCAS_PASSWORD })),
        )
        .await;
    assert_eq!((delete_self.status, delete_self.error()), (409, "conflict"));
    let demote = api
        .call(
            Method::PATCH,
            &lucas_path,
            Some(&owner),
            Some(json!({ "role": "member", "currentPassword": LUCAS_PASSWORD })),
        )
        .await;
    assert_eq!((demote.status, demote.error()), (409, "conflict"));

    // Roles need the password; then anna is an owner and lucas may step down.
    let anna_path = format!("/api/v1/admin/users/{}", anna.id);
    let promote = api
        .call(
            Method::PATCH,
            &anna_path,
            Some(&owner),
            Some(json!({ "role": "owner" })),
        )
        .await;
    assert_eq!(promote.error(), "password_required");
    let promote = api
        .call(
            Method::PATCH,
            &anna_path,
            Some(&owner),
            Some(json!({ "role": "owner", "currentPassword": LUCAS_PASSWORD })),
        )
        .await;
    assert_eq!(promote.body["role"], "owner");
    assert_eq!(api.get("/api/v1/admin/users", &member).await.status, 200);

    let deleted = api
        .call(
            Method::DELETE,
            &format!(
                "/api/v1/admin/users/{}",
                created.body["id"].as_str().unwrap()
            ),
            Some(&owner),
            Some(json!({ "currentPassword": LUCAS_PASSWORD })),
        )
        .await;
    assert_eq!(deleted.status, 204);
    api.stop().await;
}

#[tokio::test]
async fn members_see_only_their_own_devices_and_log() {
    let api = Api::start().await;
    let lucas = api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let anna = api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let owner_reply = api.login("lucas", LUCAS_PASSWORD, iphone()).await;
    let owner = owner_reply.body["token"].as_str().unwrap();
    let owner_device = owner_reply.body["device"]["id"].as_str().unwrap();
    let member = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;

    let mine = api.get("/api/v1/devices", &member).await;
    let mine = mine.body["devices"].as_array().unwrap();
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0]["current"], true);
    assert_eq!(mine[0]["username"], "anna");
    assert_eq!(
        api.get("/api/v1/devices", owner).await.body["devices"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let log = api.get("/api/v1/security-log", &member).await;
    let entries = log.body["entries"].as_array().unwrap();
    assert!(!entries.is_empty());
    assert!(entries.iter().all(|e| e["userId"] == anna.id.as_str()));
    let all = api.get("/api/v1/security-log", owner).await;
    assert!(
        all.body["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["userId"] == lucas.id.as_str())
    );
    let page = api.get("/api/v1/security-log?limit=1", owner).await;
    assert_eq!(page.body["entries"].as_array().unwrap().len(), 1);
    let before = page.body["nextBefore"].as_i64().unwrap();
    let next = api
        .get(
            &format!("/api/v1/security-log?limit=1&before={before}"),
            owner,
        )
        .await;
    assert!(next.body["entries"][0]["id"].as_i64().unwrap() < before);
    let bad = api.get("/api/v1/security-log?limit=lots", owner).await;
    assert_eq!(bad.error(), "validation_failed");

    // Someone else's device looks like it doesn't exist.
    let reach = api
        .call(
            Method::DELETE,
            &format!("/api/v1/devices/{owner_device}"),
            Some(&member),
            None,
        )
        .await;
    assert_eq!((reach.status, reach.error()), (404, "not_found"));
    let foreign_code = api
        .post(
            "/api/v1/pairing-codes",
            Some(&member),
            json!({ "userId": lucas.id }),
        )
        .await;
    assert_eq!(foreign_code.status, 403);

    // An owner can pair a device into anna's account, but it shows up as new for her.
    let for_anna = api
        .post(
            "/api/v1/pairing-codes",
            Some(owner),
            json!({ "userId": anna.id, "currentPassword": LUCAS_PASSWORD }),
        )
        .await;
    assert_eq!(for_anna.status, 201, "{}", for_anna.body);
    let paired = api
        .post(
            "/api/v1/auth/pair",
            None,
            json!({ "code": for_anna.body["code"], "device": device("iPad", "install-ipad") }),
        )
        .await;
    assert_eq!(paired.body["user"]["username"], "anna");
    assert_eq!(paired.body["device"]["confirmed"], false);
    assert_eq!(
        api.get("/api/v1/me", &member).await.body["unconfirmedDevices"],
        1
    );
    api.stop().await;
}

#[tokio::test]
async fn password_login_can_be_turned_off() {
    let api = Api::start_with(|config| config.auth.password_login = false).await;
    let lucas = api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;

    let reply = api.login("lucas", LUCAS_PASSWORD, iphone()).await;
    assert_eq!(
        (reply.status, reply.error()),
        (403, "password_login_disabled")
    );
    let info = api.call(Method::GET, "/api/v1/server", None, None).await;
    assert_eq!(info.body["passwordLogin"], false);

    // Pairing still works, e.g. with a code from `halden pair`.
    let pool = api.pool().await;
    let code = accounts::create_pairing_code(&pool, &lucas.id, None)
        .await
        .unwrap();
    pool.close().await;
    let paired = api
        .post(
            "/api/v1/auth/pair",
            None,
            json!({ "code": code.code, "device": iphone() }),
        )
        .await;
    assert_eq!(paired.status, 200, "{}", paired.body);
    api.stop().await;
}

#[tokio::test]
async fn changing_the_password_can_sign_out_the_other_devices() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let phone = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let mac = api.token("lucas", LUCAS_PASSWORD, mac()).await;
    let ipad = api
        .token("lucas", LUCAS_PASSWORD, device("iPad", "install-ipad"))
        .await;
    let change =
        |body: Value| api.call(Method::PUT, "/api/v1/me/password", Some(&phone), Some(body));

    let missing = change(json!({ "newPassword": "a new password" })).await;
    assert_eq!(
        (missing.status, missing.error()),
        (403, "password_required")
    );
    let wrong =
        change(json!({ "currentPassword": "guess", "newPassword": "a new password" })).await;
    assert_eq!((wrong.status, wrong.error()), (403, "invalid_credentials"));
    let short = change(json!({ "currentPassword": LUCAS_PASSWORD, "newPassword": "short" })).await;
    assert_eq!((short.status, short.error()), (422, "validation_failed"));

    let changed = change(json!({
        "currentPassword": LUCAS_PASSWORD,
        "newPassword": "a new password",
        "signOutOtherDevices": true
    }))
    .await;
    assert_eq!(changed.status, 200, "{}", changed.body);
    assert_eq!(changed.body["signedOutDevices"], 2);
    assert_eq!(api.get("/api/v1/me", &phone).await.status, 200);
    assert_eq!(api.get("/api/v1/me", &mac).await.status, 401);
    assert_eq!(api.get("/api/v1/me", &ipad).await.status, 401);
    assert_eq!(
        api.login("lucas", LUCAS_PASSWORD, iphone()).await.status,
        401
    );
    assert_eq!(
        api.login("lucas", "a new password", iphone()).await.status,
        200
    );
    api.stop().await;
}

#[tokio::test]
async fn server_info_and_setup_still_work_without_accounts() {
    let dir = tempfile::tempdir().unwrap();
    let (server, _) = start_server(dir.path()).await;
    let http = client(*server.fingerprint.as_bytes(), &[&rustls::version::TLS13]);
    let info: Value = http
        .get(url(&server, "/api/v1/server"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(info["passwordLogin"], true);
    server.shutdown().await.unwrap();
}

async fn device_id(api: &Api, token: &str) -> String {
    api.get("/api/v1/me", token).await.body["device"]["id"]
        .as_str()
        .unwrap()
        .to_string()
}

async fn last_seen(db: &halden::db::Db, device: &str) -> i64 {
    sqlx::query_scalar("SELECT last_seen_at FROM devices WHERE id = ?")
        .bind(device)
        .fetch_one(db.read())
        .await
        .unwrap()
}

async fn set_last_seen(db: &halden::db::Db, device: &str, at: i64) {
    sqlx::query("UPDATE devices SET last_seen_at = ? WHERE id = ?")
        .bind(at)
        .bind(device)
        .execute(db.write())
        .await
        .unwrap();
}

/// A device unused for longer than `auth.device_inactive_days` (365) is signed out at its next
/// request. "Last seen" is written at most once a minute, unless the address changed.
#[tokio::test]
async fn long_unused_devices_are_signed_out_and_last_seen_is_noted_sparingly() {
    const DAY: i64 = 24 * 60 * 60 * 1000;
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let old = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let recent = api.token("lucas", LUCAS_PASSWORD, mac()).await;
    let (old_id, recent_id) = (device_id(&api, &old).await, device_id(&api, &recent).await);
    let db = api.pool().await;
    let now = halden::db::now_ms();
    set_last_seen(&db, &old_id, now - 366 * DAY).await;
    set_last_seen(&db, &recent_id, now - 364 * DAY).await;

    let gone = api.get("/api/v1/me", &old).await;
    assert_eq!(gone.status, 401);
    assert!(gone.body["message"].as_str().unwrap().contains("long time"));
    assert_eq!(api.get("/api/v1/me", &recent).await.status, 200);
    let revoked: Option<i64> = sqlx::query_scalar("SELECT revoked_at FROM devices WHERE id = ?")
        .bind(&old_id)
        .fetch_one(db.read())
        .await
        .unwrap();
    assert!(revoked.is_some(), "signed out for good, not only refused");

    // Seen half a minute ago from the same address: not written again.
    let half_a_minute_ago = halden::db::now_ms() - 30_000;
    set_last_seen(&db, &recent_id, half_a_minute_ago).await;
    api.get("/api/v1/me", &recent).await;
    assert_eq!(last_seen(&db, &recent_id).await, half_a_minute_ago);
    // Two minutes ago: written.
    let before = halden::db::now_ms();
    set_last_seen(&db, &recent_id, before - 120_000).await;
    api.get("/api/v1/me", &recent).await;
    assert!(last_seen(&db, &recent_id).await >= before);
    db.close().await;
    api.stop().await;
}

#[tokio::test]
async fn device_names_and_installation_ids_are_checked_at_sign_in() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    for bad in [
        json!({ "name": "", "platform": "ios", "installationId": "install-ok-1" }),
        json!({ "name": "x".repeat(10_000), "platform": "ios", "installationId": "install-ok-1" }),
        json!({ "name": "iPhone", "platform": "ios", "installationId": "short" }),
        json!({ "name": "iPhone", "platform": "ios", "installationId": "with space 1" }),
    ] {
        let reply = api.login("lucas", LUCAS_PASSWORD, bad.clone()).await;
        assert_eq!(
            (reply.status, reply.error()),
            (422, "validation_failed"),
            "{bad}"
        );
    }
    api.stop().await;
}

/// Owners hear about new devices of every account; members only about their own.
#[tokio::test]
async fn new_devices_are_counted_for_the_right_people() {
    let api = Api::start().await;
    api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let owner = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    api.token("lucas", LUCAS_PASSWORD, mac()).await;
    let anna = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;
    api.token(
        "anna",
        ANNA_PASSWORD,
        device("Anna's iPad", "install-anna-2"),
    )
    .await;
    let count = |reply: common::Reply| reply.body["unconfirmedDevices"].as_i64().unwrap();
    assert_eq!(count(api.get("/api/v1/me", &anna).await), 1, "her iPad");
    assert_eq!(
        count(api.get("/api/v1/me", &owner).await),
        2,
        "his Mac and her iPad"
    );
    api.stop().await;
}

/// Anyone may make a pairing code for themselves; for someone else only an owner, with the
/// password, and the security log says who did it. A code is valid for five minutes.
#[tokio::test]
async fn pairing_codes_for_oneself_and_for_others() {
    let api = Api::start().await;
    let lucas = api.add_user("lucas", LUCAS_PASSWORD, Role::Owner).await;
    let anna = api.add_user("anna", ANNA_PASSWORD, Role::Member).await;
    let owner = api.token("lucas", LUCAS_PASSWORD, iphone()).await;
    let member = api
        .token(
            "anna",
            ANNA_PASSWORD,
            device("Anna's iPhone", "install-anna-1"),
        )
        .await;

    let before = halden::db::now_ms();
    let own = api
        .post(
            "/api/v1/pairing-codes",
            Some(&member),
            json!({ "userId": anna.id }),
        )
        .await;
    assert_eq!(
        own.status, 201,
        "naming oneself needs no password: {}",
        own.body
    );
    let expires = own.body["expiresAt"].as_i64().unwrap();
    assert!(
        (before + 295_000..=halden::db::now_ms() + 300_000).contains(&expires),
        "valid for five minutes: {}",
        expires - before
    );
    let other = api
        .post(
            "/api/v1/pairing-codes",
            Some(&member),
            json!({ "userId": lucas.id }),
        )
        .await;
    assert_eq!(other.status, 403);

    let for_anna = api
        .post(
            "/api/v1/pairing-codes",
            Some(&owner),
            json!({ "userId": anna.id, "currentPassword": LUCAS_PASSWORD }),
        )
        .await;
    assert_eq!(for_anna.status, 201, "{}", for_anna.body);
    assert_eq!(for_anna.body["userId"], anna.id.as_str());
    let log = api.get("/api/v1/security-log", &member).await;
    let entries = log.body["entries"].as_array().unwrap();
    let made: Vec<&Value> = entries
        .iter()
        .filter(|entry| entry["event"] == "pairing_code_created")
        .collect();
    assert_eq!(made.len(), 2, "{entries:?}");
    assert!(
        made.iter().any(|entry| entry["detail"] == "by lucas"),
        "{made:?}"
    );
    assert!(
        made.iter().any(|entry| entry["detail"].is_null()),
        "{made:?}"
    );
    api.stop().await;
}
