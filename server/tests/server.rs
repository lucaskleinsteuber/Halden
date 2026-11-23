//! Starts the real server on a free port and talks to it the way the apps will: over TLS 1.3,
//! trusting only the pinned certificate fingerprint.

mod common;

use common::{client, start_server, url};
use halden::{
    server,
    setup::{self, SetupOptions},
};
use serde_json::Value;

#[tokio::test]
async fn health_and_server_info_over_pinned_tls13() {
    let dir = tempfile::tempdir().unwrap();
    let (server, config) = start_server(dir.path()).await;
    let pin = *server.fingerprint.as_bytes();
    let http = client(pin, &[&rustls::version::TLS13]);

    let health = http
        .get(url(&server, "/api/v1/health"))
        .send()
        .await
        .unwrap();
    assert_eq!(health.status(), 200);
    assert_eq!(
        health.version(),
        reqwest::Version::HTTP_2,
        "HTTP/2 must be negotiated"
    );
    let body: Value = health.json().await.unwrap();
    assert_eq!(body["status"], "ok");

    let info: Value = http
        .get(url(&server, "/api/v1/server"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(info["name"], "testbox");
    assert_eq!(info["apiVersion"], 1);
    assert_eq!(info["fingerprint"], server.fingerprint.hex());
    assert_eq!(
        info["fingerprint"],
        halden::tls::identity_fingerprint(&config).unwrap().hex()
    );
    assert!(info["serverId"].as_str().unwrap().len() == 36);

    let missing = http.get(url(&server, "/nope")).send().await.unwrap();
    assert_eq!(missing.status(), 404);

    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn wrong_fingerprint_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (server, _) = start_server(dir.path()).await;
    let http = client([0; 32], &[&rustls::version::TLS13]);
    assert!(
        http.get(url(&server, "/api/v1/health"))
            .send()
            .await
            .is_err()
    );
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn tls12_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (server, _) = start_server(dir.path()).await;
    let http = client(*server.fingerprint.as_bytes(), &[&rustls::version::TLS12]);
    assert!(
        http.get(url(&server, "/api/v1/health"))
            .send()
            .await
            .is_err()
    );
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn setup_twice_keeps_identity() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.toml");
    let options = SetupOptions {
        data_dir: Some(dir.path().join("data")),
        library_dir: Some(dir.path().join("library")),
        ..SetupOptions::default()
    };
    let first = setup::run(&config_path, options.clone()).await.unwrap();
    assert!(first.config_created && first.identity_created);

    let second = setup::run(&config_path, SetupOptions::default())
        .await
        .unwrap();
    assert!(!second.config_created && !second.identity_created);
    assert_eq!(first.server_id, second.server_id);
    assert_eq!(first.fingerprint, second.fingerprint);

    // Changing settings through setup on an existing config is refused, not silently ignored.
    assert!(setup::run(&config_path, options).await.is_err());

    for folder in [
        "library/.halden/incoming",
        "library/.halden/backups",
        "data/tls",
    ] {
        assert!(dir.path().join(folder).is_dir(), "{folder} missing");
    }
}

#[tokio::test]
async fn port_in_use_is_reported() {
    let dir = tempfile::tempdir().unwrap();
    let (server, _) = start_server(dir.path()).await;
    // Another server with its own folders, on the same port.
    let other = tempfile::tempdir().unwrap();
    let (second, mut config) = start_server(other.path()).await;
    second.shutdown().await.unwrap();
    config.server.port = server.addr.port();
    let error = server::start(&config)
        .await
        .err()
        .expect("second start must fail");
    assert!(format!("{error:#}").contains("already in use"), "{error:#}");
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn two_servers_never_share_a_data_folder() {
    let dir = tempfile::tempdir().unwrap();
    let (server, mut config) = start_server(dir.path()).await;
    config.server.port = 0;
    let error = server::start(&config)
        .await
        .err()
        .expect("a second server on the same folders must not start");
    assert!(format!("{error:#}").contains("is running"), "{error:#}");
    server.shutdown().await.unwrap();
    // Once the first is gone, the folder is free again.
    let again = server::start(&config).await.unwrap();
    again.shutdown().await.unwrap();
}

/// The server announces itself in the home network and an app finds it, with the facts it needs
/// to recognise it. Needs a network interface with a home-network address (skipped without).
#[tokio::test]
async fn the_server_is_found_in_the_home_network() {
    use halden::bonjour;
    if !halden::net::local_addresses()
        .into_iter()
        .any(bonjour::announce_on)
    {
        eprintln!("no home-network interface here; skipping");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let (server, config) = common::start_server_with(dir.path(), |config| {
        config.network.bonjour = true;
    })
    .await;
    let pool = halden::db::Db::open(&config.db_path()).await.unwrap();
    let id = halden::db::server_id(&pool).await.unwrap().to_string();
    pool.close().await;

    let browser = mdns_sd::ServiceDaemon::new().unwrap();
    let events = browser.browse(bonjour::SERVICE_TYPE).unwrap();
    let found = tokio::task::spawn_blocking(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) {
            if let Ok(mdns_sd::ServiceEvent::ServiceResolved(service)) = events.recv_timeout(left)
                && service.get_property_val_str("id") == Some(id.as_str())
            {
                return Some(service);
            }
        }
        None
    })
    .await
    .unwrap()
    .expect("the server was not found");
    assert_eq!(
        found.get_property_val_str("fp"),
        Some(server.fingerprint.hex().as_str())
    );
    assert_eq!(found.get_property_val_str("name"), Some("testbox"));
    assert_eq!(found.get_property_val_str("api"), Some("1"));
    assert_eq!(found.get_port(), server.addr.port());
    let _ = browser.shutdown();
    server.shutdown().await.unwrap();
}
