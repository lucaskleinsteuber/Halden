//! Counts work that runs on its own threads (upload writers, photo decoding, mirror copies), so
//! a server that stops or reloads its settings can wait until that work is done before the next
//! one starts on the same files.

use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use tokio::sync::Notify;

#[derive(Clone, Default)]
pub struct Activity(Arc<Inner>);

#[derive(Default)]
struct Inner {
    count: AtomicUsize,
    idle: Notify,
}

/// Held while a piece of work runs; dropping it marks the work as done.
pub struct Busy(Activity);

impl Activity {
    pub fn busy(&self) -> Busy {
        self.0.count.fetch_add(1, Ordering::SeqCst);
        Busy(self.clone())
    }

    pub fn count(&self) -> usize {
        self.0.count.load(Ordering::SeqCst)
    }

    /// Waits until no work runs, at most `max`. True when everything finished.
    pub async fn wait_idle(&self, max: Duration) -> bool {
        let deadline = tokio::time::Instant::now() + max;
        loop {
            let notified = self.0.idle.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.count() == 0 {
                return true;
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                return self.count() == 0;
            }
        }
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        if self.0.0.count.fetch_sub(1, Ordering::SeqCst) == 1 {
            self.0.0.idle.notify_waiters();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn waits_for_work_on_other_threads() {
        let activity = Activity::default();
        assert!(activity.wait_idle(Duration::from_millis(1)).await);
        let busy = activity.busy();
        let worker = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            drop(busy);
        });
        assert!(!activity.wait_idle(Duration::from_millis(10)).await);
        assert!(activity.wait_idle(Duration::from_secs(5)).await);
        worker.join().unwrap();
        assert_eq!(activity.count(), 0);
    }
}
