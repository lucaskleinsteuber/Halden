//! The SQLite database: metadata about photos, accounts and devices. Original files never go
//! in here; they stay in the library folders.

use std::{os::unix::fs::PermissionsExt, path::Path, time::Duration};

use anyhow::{Context, Result};
use sqlx::{
    SqlitePool,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
};
use uuid::Uuid;

/// Opens (and if needed creates) the database and brings its tables up to date.
///
/// WAL lets the library be read while uploads are written. `synchronous = FULL` makes every
/// committed change survive a power cut, because "backed up" must really mean backed up.
pub async fn open(path: &Path) -> Result<SqlitePool> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .synchronous(SqliteSynchronous::Full)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(5));
    let pool = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await
        .with_context(|| format!("could not open the database {}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("could not protect the database {}", path.display()))?;
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .context("could not update the database tables")?;
    Ok(pool)
}

/// The server's permanent identity. Apps use it to recognise the server at any address.
pub async fn server_id(pool: &SqlitePool) -> Result<Uuid> {
    const SELECT: &str = "SELECT value FROM server_meta WHERE key = 'server_id'";
    if let Some((value,)) = sqlx::query_as::<_, (String,)>(SELECT)
        .fetch_optional(pool)
        .await?
    {
        return Uuid::parse_str(&value).context("the stored server id is damaged");
    }
    sqlx::query(
        "INSERT INTO server_meta (key, value) VALUES ('server_id', ?) ON CONFLICT(key) DO NOTHING",
    )
    .bind(Uuid::new_v4().to_string())
    .execute(pool)
    .await?;
    let (value,) = sqlx::query_as::<_, (String,)>(SELECT)
        .fetch_one(pool)
        .await?;
    Uuid::parse_str(&value).context("the stored server id is damaged")
}

/// A cheap query that proves the database answers.
pub async fn ping(pool: &SqlitePool) -> Result<()> {
    sqlx::query("SELECT 1").execute(pool).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn server_id_is_created_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("halden.db");
        let pool = open(&path).await.unwrap();
        let first = server_id(&pool).await.unwrap();
        pool.close().await;

        let pool = open(&path).await.unwrap();
        assert_eq!(server_id(&pool).await.unwrap(), first);
        ping(&pool).await.unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
