//! The photo library: assets and their files, where files go, what files say about themselves,
//! and how much space is left.

pub mod albums;
pub mod assets;
pub mod derived;
pub mod edits;
pub mod journal;
pub mod metadata;
pub mod paths;
pub mod settings;
pub mod space;
pub mod sync;
pub mod trash;

/// The earliest time a photo can have been taken: 1 January 1900 (Unix milliseconds).
pub const EARLIEST_TAKEN_AT: i64 = -2_208_988_800_000;
/// The latest: 1 January 2200.
pub const LATEST_TAKEN_AT: i64 = 7_258_118_400_000;
