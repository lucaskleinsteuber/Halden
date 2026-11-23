//! Halden server.
//!
//! The `halden` program is both the server (`halden serve`) and the tool that sets it up and
//! looks after it (`halden setup`, `halden status`, ...). Everything lives in this library so the
//! integration tests can drive the real code; `main.rs` only calls [`cli::main`].

pub mod accounts;
pub mod api;
pub mod auth;
pub mod cli;
pub mod config;
pub mod db;
pub mod fsutil;
pub mod net;
pub mod seclog;
pub mod server;
pub mod setup;
pub mod tls;

/// Version of this build of the server.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Version of the HTTP API that the apps talk to. Raised only for breaking changes.
pub const API_VERSION: u32 = 1;
