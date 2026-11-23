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

/// A database left at every earlier stage of the tables, with data in it, is brought up to date
/// without losing anything: what a server sees when it is updated after a long time.
#[cfg(test)]
mod upgrade_tests {
    use std::borrow::Cow;

    use sqlx::{ConnectOptions, Connection, sqlite::SqliteConnectOptions};

    use super::*;

    /// Creates a database at migration level `level` (1 = only the first) and fills it with what
    /// that level knows.
    async fn database_at(path: &Path, level: usize) {
        let mut migrator = sqlx::migrate!("./migrations");
        migrator.migrations = Cow::Owned(migrator.migrations[..level].to_vec());
        let mut connection = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .foreign_keys(true)
            .connect()
            .await
            .unwrap();
        migrator.run(&mut connection).await.unwrap();
        let statements: &[&str] = &[
            // 1
            "INSERT INTO server_meta (key, value) VALUES ('server_id', '11111111-2222-3333-4444-555555555555')",
            // 2
            "INSERT INTO users (id, username, display_name, role, password_hash, created_at) \
             VALUES ('u1', 'lucas', 'Lucas', 'owner', NULL, 1); \
             INSERT INTO devices (id, user_id, name, platform, token_hash, created_at, last_seen_at) \
             VALUES ('d1', 'u1', 'iPhone', 'ios', x'00', 1, 1)",
            // 3
            "INSERT INTO assets (id, user_id, kind, taken_at, taken_at_source, created_at, updated_at, seq) \
             VALUES ('a1', 'u1', 'photo', 1795443730000, 'client', 1, 1, 1); \
             UPDATE counters SET value = 1 WHERE name = 'asset_seq'; \
             INSERT INTO asset_files (asset_id, role, user_id, sha256, size, mime, storage, path, created_at) \
             VALUES ('a1', 'original', 'u1', x'01', 10, 'image/heic', 'library', 'lucas/a.heic', 1)",
            // 4
            "UPDATE assets SET title = 'Lake' WHERE id = 'a1'; \
             INSERT INTO jobs (kind, asset_id, user_id, state, run_after, created_at, updated_at) \
             VALUES ('thumbnail', 'a1', 'u1', 'queued', 0, 1, 1)",
            // 5
            "INSERT INTO user_settings (user_id, updated_at) VALUES ('u1', 1)",
            // 6
            "INSERT INTO mirror_files (asset_id, role, sha256, path, copied_at) \
             VALUES ('a1', 'original', x'01', 'lucas/a.heic', 1)",
            // 7
            "INSERT INTO file_journal (action, storage, path, created_at) \
             VALUES ('remove', 'derived', 'ab/cd/x.jpg', 1)",
        ];
        for statement in &statements[..level.min(statements.len())] {
            sqlx::raw_sql(*statement)
                .execute(&mut connection)
                .await
                .unwrap();
        }
        connection.close().await.unwrap();
    }

    #[tokio::test]
    async fn every_older_database_is_brought_up_to_date() {
        let all = sqlx::migrate!("./migrations").migrations.len();
        for level in 1..=all {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("halden.db");
            database_at(&path, level).await;
            let db = Db::open(&path).await.unwrap();
            assert_eq!(
                server_id(&db).await.unwrap().to_string(),
                "11111111-2222-3333-4444-555555555555",
                "level {level}"
            );
            if level >= 2 {
                let users = crate::accounts::list_users(&db).await.unwrap();
                assert_eq!(users.len(), 1, "level {level}");
                assert_eq!(users[0].devices, 1, "level {level}");
            }
            if level >= 3 {
                let asset = crate::library::assets::get(db.read(), "u1", "a1")
                    .await
                    .unwrap()
                    .expect("the photo is still there");
                assert_eq!(asset.files.len(), 1, "level {level}");
                let page = crate::library::sync::changes(&db, "u1", 0, 100)
                    .await
                    .unwrap();
                assert_eq!(page.assets.len(), 1, "level {level}");
                // New photos get the next number.
                let mut tx = db.begin().await.unwrap();
                assert_eq!(crate::library::assets::next_seq(&mut tx).await.unwrap(), 2);
                tx.rollback().await.unwrap();
            }
            if level >= 4 {
                assert_eq!(
                    crate::jobs::stats(&db).await.unwrap().waiting,
                    1,
                    "level {level}"
                );
            }
            sqlx::query("PRAGMA foreign_key_check")
                .fetch_all(db.read())
                .await
                .map(|rows| assert!(rows.is_empty(), "level {level}: broken references"))
                .unwrap();
            db.close().await;
        }
    }

    /// A backup made by an older version is restored and brought up to date.
    #[tokio::test]
    async fn an_old_backup_can_be_restored() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = crate::config::Config::default();
        config.storage.data_dir = dir.path().join("data");
        config.storage.library_dir = dir.path().join("library");
        std::fs::create_dir_all(&config.storage.data_dir).unwrap();
        let db = Db::open(&config.db_path()).await.unwrap();
        db.close().await;
        let old = dir.path().join("halden-2026-01-01_03-00-00.db");
        database_at(&old, 3).await;
        crate::backup::database::restore(&config, &old)
            .await
            .unwrap();
        let db = Db::open(&config.db_path()).await.unwrap();
        assert!(
            crate::library::assets::get(db.read(), "u1", "a1")
                .await
                .unwrap()
                .is_some()
        );
        db.close().await;
    }
}
