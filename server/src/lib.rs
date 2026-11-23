//! Halden server.
//!
//! The `halden` program is both the server (`halden serve`) and the tool that sets it up and
//! looks after it (`halden setup`, `halden status`, ...). Everything lives in this library so the
//! integration tests can drive the real code; `main.rs` only calls [`cli::main`].

pub mod accounts;
pub mod activity;
pub mod api;
pub mod auth;
pub mod backup;
pub mod bonjour;
pub mod cli;
pub mod config;
pub mod db;
pub mod doctor;
pub mod files;
pub mod fsutil;
pub mod jobs;
pub mod library;
pub mod net;
pub mod seclog;
pub mod server;
pub mod setup;
pub mod tls;
pub mod update;
pub mod upload;

/// Version of this build of the server. Release builds get it from their tag
/// (`HALDEN_BUILD_VERSION`, set by the release workflow); otherwise it is Cargo's.
pub const VERSION: &str = match option_env!("HALDEN_BUILD_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};

/// Version of the HTTP API that the apps talk to. Raised only for breaking changes.
pub const API_VERSION: u32 = 1;
