//! Background jobs: thumbnails the phone didn't send, format conversions, mirroring.
//!
//! The queue is a table in SQLite, so jobs survive restarts. Workers take the oldest due job,
//! run it, and delete it when done. A failed job is tried again later (after 1, 5 and 30
//! minutes, 2 and 12 hours), then left as failed with its error. Workers never compete with
//! uploads: there are few of them (`[jobs] workers`, default 1), heavy work runs on
//! lowest-priority threads, and external tools run with `nice`/`ionice`.

mod lowprio;
pub mod thumbnail;
pub mod tools;

use std::{path::PathBuf, sync::Arc, time::Duration};

use sqlx::SqliteConnection;
use tokio::{sync::Notify, task::JoinHandle};

pub use self::{lowprio::LowPriority, tools::Tools};
use crate::{
    config::Config,
    db::{Db, now_ms},
};

/// Waits after the 1st, 2nd, … failure.
const RETRY_AFTER_MS: [i64; 5] = [60_000, 300_000, 1_800_000, 7_200_000, 43_200_000];
/// An idle worker looks for due jobs at least this often (jobs with a delay become due without
/// anyone waking the worker).
const IDLE_CHECK: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobKind {
    Thumbnail,
}

impl JobKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Thumbnail => "thumbnail",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "thumbnail" => Some(Self::Thumbnail),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct Job {
    pub id: i64,
    pub kind: String,
    pub asset_id: String,
    pub user_id: String,
    pub attempts: i64,
}

/// Adds a job (inside the caller's transaction), unless the same job is waiting already. A job
/// that failed for good is given a fresh start.
pub async fn enqueue(
    tx: &mut SqliteConnection,
    kind: JobKind,
    asset_id: &str,
    user_id: &str,
    delay_ms: i64,
) -> Result<(), sqlx::Error> {
    let now = now_ms();
    sqlx::query(
        "INSERT INTO jobs (kind, asset_id, user_id, state, run_after, created_at, updated_at) \
         VALUES (?1, ?2, ?3, 'queued', ?4, ?5, ?5) \
         ON CONFLICT (kind, asset_id) DO UPDATE SET state = 'queued', attempts = 0, \
             run_after = excluded.run_after, last_error = NULL, updated_at = excluded.updated_at \
         WHERE jobs.state = 'failed'",
    )
    .bind(kind.as_str())
    .bind(asset_id)
    .bind(user_id)
    .bind(now + delay_ms.max(0))
    .bind(now)
    .execute(&mut *tx)
    .await?;
    Ok(())
}

/// Everything a job needs.
pub struct JobContext {
    pub db: Db,
    pub library: PathBuf,
    pub derived: PathBuf,
    pub scratch_dir: PathBuf,
    pub tools: Tools,
    pub background: Arc<LowPriority>,
    pub external_timeout: Duration,
}

impl JobContext {
    /// A folder for temporary files of external tools, on the fast disk.
    pub fn scratch(&self) -> &std::path::Path {
        &self.scratch_dir
    }
}

/// The running workers. Dropping or [`Workers::stop`] ends them; external tools they started
/// are killed.
pub struct Workers {
    wake: Arc<Notify>,
    tasks: Vec<JoinHandle<()>>,
}

impl Workers {
    pub async fn start(config: &Config, db: Db, wake: Arc<Notify>) -> anyhow::Result<Self> {
        // Jobs that were running when the server stopped start over.
        sqlx::query("UPDATE jobs SET state = 'queued' WHERE state = 'running'")
            .execute(db.write())
            .await?;
        let scratch_dir = config.storage.data_dir.join("tmp");
        crate::fsutil::create_dir(&scratch_dir, 0o700)?;
        if let Ok(entries) = std::fs::read_dir(&scratch_dir) {
            for entry in entries.flatten() {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        let workers = config.jobs.workers.clamp(1, 16) as usize;
        let context = Arc::new(JobContext {
            db,
            library: config.storage.library_dir.clone(),
            derived: config.derived_dir(),
            scratch_dir,
            tools: Tools::find(),
            background: Arc::new(LowPriority::new(workers)),
            external_timeout: Duration::from_secs(
                u64::from(config.jobs.external_timeout_minutes.max(1)) * 60,
            ),
        });
        let tasks = (0..workers)
            .map(|_| tokio::spawn(work(context.clone(), wake.clone())))
            .collect();
        Ok(Self { wake, tasks })
    }

    /// Tells idle workers to look for new jobs now.
    pub fn wake(&self) {
        self.wake.notify_waiters();
    }

    pub fn stop(&self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl Drop for Workers {
    fn drop(&mut self) {
        self.stop();
    }
}

async fn work(ctx: Arc<JobContext>, wake: Arc<Notify>) {
    loop {
        let job = match claim(&ctx.db).await {
            Ok(job) => job,
            Err(error) => {
                tracing::error!(%error, "could not read the job queue");
                tokio::time::sleep(IDLE_CHECK).await;
                continue;
            }
        };
        let Some(job) = job else {
            // Sleep until the next job is due (a thumbnail waiting for its 10 minutes), or
            // until new work arrives, but look again at least every half minute.
            let notified = wake.notified();
            let pause = next_due(&ctx.db)
                .await
                .ok()
                .flatten()
                .map_or(IDLE_CHECK, |due| {
                    Duration::from_millis(u64::try_from(due - now_ms()).unwrap_or(0))
                        .min(IDLE_CHECK)
                });
            tokio::select! {
                () = notified => {}
                () = tokio::time::sleep(pause) => {}
            }
            continue;
        };
        let result = match JobKind::parse(&job.kind) {
            Some(JobKind::Thumbnail) => thumbnail::run(&ctx, &job).await,
            None => Err(format!("unknown job kind {}", job.kind)),
        };
        if let Err(error) = finish(&ctx.db, &job, result).await {
            tracing::error!(%error, "could not record a finished job");
        }
    }
}

async fn next_due(db: &Db) -> Result<Option<i64>, sqlx::Error> {
    let (due,): (Option<i64>,) =
        sqlx::query_as("SELECT min(run_after) FROM jobs WHERE state = 'queued'")
            .fetch_one(db.read())
            .await?;
    Ok(due)
}

/// Takes the oldest due job and marks it running.
async fn claim(db: &Db) -> Result<Option<Job>, sqlx::Error> {
    let now = now_ms();
    sqlx::query_as::<_, Job>(
        "UPDATE jobs SET state = 'running', attempts = attempts + 1, updated_at = ?1 \
         WHERE id = (SELECT id FROM jobs WHERE state = 'queued' AND run_after <= ?1 \
                     ORDER BY run_after, id LIMIT 1) \
         RETURNING id, kind, asset_id, user_id, attempts",
    )
    .bind(now)
    .fetch_optional(db.write())
    .await
}

async fn finish(db: &Db, job: &Job, result: Result<(), String>) -> Result<(), sqlx::Error> {
    match result {
        Ok(()) => {
            sqlx::query("DELETE FROM jobs WHERE id = ?")
                .bind(job.id)
                .execute(db.write())
                .await?;
        }
        Err(error) => {
            let retry = usize::try_from(job.attempts - 1)
                .ok()
                .and_then(|n| RETRY_AFTER_MS.get(n));
            tracing::warn!(kind = %job.kind, asset = %job.asset_id, %error, "a background job failed");
            match retry {
                Some(wait) => {
                    sqlx::query(
                        "UPDATE jobs SET state = 'queued', run_after = ?, last_error = ?, \
                             updated_at = ? WHERE id = ?",
                    )
                    .bind(now_ms() + wait)
                    .bind(&error)
                    .bind(now_ms())
                    .bind(job.id)
                    .execute(db.write())
                    .await?;
                }
                None => {
                    sqlx::query(
                        "UPDATE jobs SET state = 'failed', last_error = ?, updated_at = ? \
                         WHERE id = ?",
                    )
                    .bind(&error)
                    .bind(now_ms())
                    .bind(job.id)
                    .execute(db.write())
                    .await?;
                }
            }
        }
    }
    Ok(())
}

/// Numbers for `halden status`.
#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct QueueStats {
    pub waiting: i64,
    pub failed: i64,
}

pub async fn stats(db: &Db) -> Result<QueueStats, sqlx::Error> {
    let (waiting, failed): (i64, i64) = sqlx::query_as(
        "SELECT coalesce(sum(state <> 'failed'), 0), coalesce(sum(state = 'failed'), 0) FROM jobs",
    )
    .fetch_one(db.read())
    .await?;
    Ok(QueueStats { waiting, failed })
}
