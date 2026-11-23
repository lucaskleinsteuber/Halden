//! The SQLite database: metadata about photos, accounts and devices. Original files never go
//! in here; they stay in the library folders.
//!
//! There is exactly one connection that writes and a handful that only read. With WAL, readers
//! never wait for the writer, and because all writes in this process queue up for the same
//! connection, two of them can never trip over each other's locks (`SQLITE_BUSY`).

use std::{os::unix::fs::PermissionsExt, path::Path, time::Duration};

use anyhow::{Context, Result};
use sqlx::{
    Sqlite, SqlitePool, Transaction,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
};
use uuid::Uuid;

/// Page cache per connection, in KiB (negative numbers mean KiB to SQLite). Reads mostly go
/// through the memory map below, which the operating system shares between all connections, so
/// a modest private cache per connection keeps memory flat even after a full sync.
const CACHE_KIB: &str = "-16384";
/// Memory-mapped reading, in bytes.
const MMAP_BYTES: &str = "268435456";
const MAX_READERS: u32 = 8;

/// The database: one writing connection, several reading ones.
#[derive(Clone, Debug)]
pub struct Db {
    read: SqlitePool,
    write: SqlitePool,
    path: std::path::PathBuf,
}

impl Db {
    /// Opens (and if needed creates) the database and brings its tables up to date.
    ///
    /// WAL lets the library be read while uploads are written. `synchronous = FULL` makes every
    /// committed change survive a power cut, because "backed up" must really mean backed up.
    pub async fn open(path: &Path) -> Result<Self> {
        let base = SqliteConnectOptions::new()
            .filename(path)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Full)
            .foreign_keys(true)
            .busy_timeout(Duration::from_secs(5))
            .pragma("cache_size", CACHE_KIB)
            .pragma("mmap_size", MMAP_BYTES)
            .pragma("temp_store", "memory")
            .analysis_limit(400);

        let write = SqlitePoolOptions::new()
            .max_connections(1)
            .min_connections(1)
            .connect_with(base.clone().create_if_missing(true))
            .await
            .with_context(|| format!("could not open the database {}", path.display()))?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("could not protect the database {}", path.display()))?;
        sqlx::migrate!("./migrations")
            .run(&write)
            .await
            .context("could not update the database tables")?;

        let readers = std::thread::available_parallelism()
            .map_or(4, |n| n.get() as u32)
            .clamp(2, MAX_READERS);
        let read = SqlitePoolOptions::new()
            .max_connections(readers)
            .connect_with(base.read_only(true))
            .await
            .with_context(|| format!("could not open the database {}", path.display()))?;
        Ok(Self {
            read,
            write,
            path: path.to_path_buf(),
        })
    }

    /// The database file.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// For queries that only read. They run in parallel.
    pub fn read(&self) -> &SqlitePool {
        &self.read
    }

    /// For anything that changes the database. Writes queue up for the one writing connection.
    pub fn write(&self) -> &SqlitePool {
        &self.write
    }

    /// A write transaction that takes the write lock right away. Taking it later (SQLite's
    /// default) can fail when another process wrote in between; this way it simply waits.
    pub async fn begin(&self) -> Result<Transaction<'static, Sqlite>, sqlx::Error> {
        self.write.begin_with("BEGIN IMMEDIATE").await
    }

    /// Lets SQLite update its statistics where they are out of date. Cheap; run at start and
    /// once a day so queries keep using the best index as the library grows.
    pub async fn optimize(&self) -> Result<()> {
        sqlx::query("PRAGMA optimize").execute(&self.write).await?;
        Ok(())
    }

    pub async fn close(&self) {
        self.read.close().await;
        self.write.close().await;
    }
}

/// The server's permanent identity. Apps use it to recognise the server at any address.
pub async fn server_id(db: &Db) -> Result<Uuid> {
    const SELECT: &str = "SELECT value FROM server_meta WHERE key = 'server_id'";
    if let Some((value,)) = sqlx::query_as::<_, (String,)>(SELECT)
        .fetch_optional(db.read())
        .await?
    {
        return Uuid::parse_str(&value).context("the stored server id is damaged");
    }
    sqlx::query(
        "INSERT INTO server_meta (key, value) VALUES ('server_id', ?) ON CONFLICT(key) DO NOTHING",
    )
    .bind(Uuid::new_v4().to_string())
    .execute(db.write())
    .await?;
    let (value,) = sqlx::query_as::<_, (String,)>(SELECT)
        .fetch_one(db.write())
        .await?;
    Uuid::parse_str(&value).context("the stored server id is damaged")
}

/// The current time as Unix milliseconds, the way the database stores times.
pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// A cheap query that proves the database answers.
pub async fn ping(db: &Db) -> Result<()> {
    sqlx::query("SELECT 1").execute(db.read()).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn server_id_is_created_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("halden.db");
        let db = Db::open(&path).await.unwrap();
        let first = server_id(&db).await.unwrap();
        db.close().await;

        let db = Db::open(&path).await.unwrap();
        assert_eq!(server_id(&db).await.unwrap(), first);
        ping(&db).await.unwrap();
        db.optimize().await.unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[tokio::test]
    async fn readers_cannot_write() {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("halden.db")).await.unwrap();
        let refused = sqlx::query("INSERT INTO server_meta (key, value) VALUES ('x', 'y')")
            .execute(db.read())
            .await;
        assert!(refused.is_err());
    }
}
