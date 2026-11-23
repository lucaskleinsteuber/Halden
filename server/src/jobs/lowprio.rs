//! A few threads at the lowest scheduling priority for heavy background work (decoding and
//! resizing photos). The operating system runs them only when nothing more important wants the
//! CPU, so uploads and the library stay fast while thumbnails are being made.

use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{Arc, Mutex, mpsc},
};

use thread_priority::{ThreadPriority, set_current_thread_priority};

type Work = Box<dyn FnOnce() + Send>;

pub struct LowPriority {
    queue: Mutex<mpsc::Sender<Work>>,
    activity: crate::activity::Activity,
}

impl LowPriority {
    /// Work counts as busy in `activity` until it is done, even if whoever waited for it gave up.
    pub fn new(threads: usize, activity: crate::activity::Activity) -> Self {
        let (sender, receiver) = mpsc::channel::<Work>();
        let receiver = Arc::new(Mutex::new(receiver));
        for n in 0..threads.max(1) {
            let receiver = receiver.clone();
            let spawned = std::thread::Builder::new()
                .name(format!("halden-background-{n}"))
                .spawn(move || {
                    if let Err(error) = set_current_thread_priority(ThreadPriority::Min) {
                        tracing::debug!(?error, "could not lower the background thread's priority");
                    }
                    loop {
                        let next = match receiver.lock() {
                            Ok(receiver) => receiver.recv(),
                            Err(_) => return,
                        };
                        match next {
                            // A panic in one piece of work must not take the thread with it.
                            Ok(work) => {
                                let _ = catch_unwind(AssertUnwindSafe(work));
                            }
                            Err(_) => return,
                        }
                    }
                });
            if let Err(error) = spawned {
                tracing::error!(%error, "could not start a background thread");
            }
        }
        Self {
            queue: Mutex::new(sender),
            activity,
        }
    }

    /// Runs `work` on a low-priority thread and waits for its result. `None` if it panicked.
    pub async fn run<R: Send + 'static>(
        &self,
        work: impl FnOnce() -> R + Send + 'static,
    ) -> Option<R> {
        let (done, result) = tokio::sync::oneshot::channel();
        let busy = self.activity.busy();
        let job: Work = Box::new(move || {
            let _busy = busy;
            let _ = done.send(work());
        });
        self.queue.lock().ok()?.send(job).ok()?;
        result.await.ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn runs_work_and_survives_panics() {
        let activity = crate::activity::Activity::default();
        let pool = LowPriority::new(2, activity.clone());
        assert_eq!(pool.run(|| 6 * 7).await, Some(42));
        assert_eq!(pool.run(|| -> u8 { panic!("broken photo") }).await, None);
        assert_eq!(pool.run(|| "still here").await, Some("still here"));
        assert_eq!(activity.count(), 0);
    }
}
