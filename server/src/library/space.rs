//! Free space on the library disk. An upload is only accepted if it fits, counting the space
//! that uploads already in progress will still need, so a full disk is reported up front
//! instead of ending in half-written files.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
};

use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotEnoughSpace {
    pub needed: u64,
    pub available: u64,
}

/// Space promised to uploads in progress, by upload id.
pub struct SpaceBook {
    library: PathBuf,
    min_free: u64,
    reserved: Mutex<HashMap<Uuid, u64>>,
}

impl SpaceBook {
    pub fn new(library: &Path, min_free_bytes: u64) -> Self {
        Self {
            library: library.to_path_buf(),
            min_free: min_free_bytes,
            reserved: Mutex::new(HashMap::new()),
        }
    }

    fn reserved(&self) -> std::sync::MutexGuard<'_, HashMap<Uuid, u64>> {
        self.reserved
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Reserves `bytes` for an upload, or says how much is missing.
    pub fn reserve(&self, upload: Uuid, bytes: u64) -> Result<(), NotEnoughSpace> {
        let free = fs4::available_space(&self.library).unwrap_or(0);
        self.reserve_with_free(upload, bytes, free)
    }

    fn reserve_with_free(&self, upload: Uuid, bytes: u64, free: u64) -> Result<(), NotEnoughSpace> {
        let mut reserved = self.reserved();
        let promised: u64 = reserved
            .iter()
            .filter(|(id, _)| **id != upload)
            .map(|(_, bytes)| *bytes)
            .sum();
        let available = free.saturating_sub(promised).saturating_sub(self.min_free);
        if bytes > available {
            return Err(NotEnoughSpace {
                needed: bytes,
                available,
            });
        }
        reserved.insert(upload, bytes);
        Ok(())
    }

    /// Notes that an upload still needs `remaining` bytes (it shrinks as data arrives). Unlike
    /// [`Self::reserve`] this never refuses: the space was promised already.
    pub fn update(&self, upload: Uuid, remaining: u64) {
        self.reserved().insert(upload, remaining);
    }

    pub fn release(&self, upload: Uuid) {
        self.reserved().remove(&upload);
    }

    /// Bytes promised to uploads in progress.
    pub fn promised(&self) -> u64 {
        self.reserved().values().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uploads_in_progress_count_against_free_space() {
        let book = SpaceBook::new(Path::new("/"), 100);
        let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
        // 1000 free, 100 kept free: 900 can be promised.
        book.reserve_with_free(a, 600, 1000).unwrap();
        assert_eq!(
            book.reserve_with_free(b, 400, 1000),
            Err(NotEnoughSpace {
                needed: 400,
                available: 300
            })
        );
        book.reserve_with_free(b, 300, 1000).unwrap();
        assert_eq!(book.promised(), 900);
        // As `a` receives data, its remaining need shrinks.
        book.update(a, 100);
        book.reserve_with_free(b, 800, 1000).unwrap();
        book.release(a);
        book.release(b);
        assert_eq!(book.promised(), 0);
        // Re-reserving the same upload replaces its own promise instead of adding to it.
        book.reserve_with_free(a, 900, 1000).unwrap();
        book.reserve_with_free(a, 900, 1000).unwrap();
    }
}
