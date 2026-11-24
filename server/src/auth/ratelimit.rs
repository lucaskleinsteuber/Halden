//! Brakes against guessing passwords and pairing codes. Kept in memory: a restart forgets them,
//! which is fine because guessing still has to start over against Argon2 and 50-bit codes.
//!
//! - Per IP address: at most 20 sign-in or pairing attempts per minute.
//! - Per username: from the 5th failure in a row, a wait of 30 seconds that doubles with every
//!   further failure, up to 15 minutes. A success clears it.
//! - Pairing: after 100 wrong codes in total, every open code is cancelled.

use std::{
    collections::HashMap,
    net::IpAddr,
    sync::Mutex,
    time::{Duration, Instant},
};

pub const IP_ATTEMPTS_PER_WINDOW: u32 = 20;
pub const IP_WINDOW: Duration = Duration::from_secs(60);
pub const FREE_FAILURES: u32 = 5;
pub const FIRST_WAIT: Duration = Duration::from_secs(30);
pub const MAX_WAIT: Duration = Duration::from_secs(15 * 60);
/// Failures older than this are forgotten.
const FORGET_AFTER: Duration = Duration::from_secs(24 * 60 * 60);
/// Above this many remembered entries, stale ones are dropped.
const MAX_ENTRIES: usize = 10_000;

#[derive(Default)]
pub struct RateLimiter {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    ips: HashMap<IpAddr, Window>,
    users: HashMap<String, Failures>,
    pairing_failures: u32,
}

struct Window {
    started: Instant,
    count: u32,
}

struct Failures {
    count: u32,
    last: Instant,
    locked_until: Option<Instant>,
}

/// The time to wait before trying again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryAfter(pub Duration);

impl RetryAfter {
    /// Whole seconds for the `Retry-After` header, at least 1.
    pub fn seconds(self) -> u64 {
        (self.0.as_secs() + u64::from(self.0.subsec_nanos() > 0)).max(1)
    }
}

impl RateLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        // A panic while holding the lock leaves only counters behind; keep using them.
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Counts one attempt from `ip`. Refuses it once the address used up its minute.
    pub fn attempt_from(&self, ip: IpAddr, now: Instant) -> Result<(), RetryAfter> {
        let mut state = self.state();
        if state.ips.len() >= MAX_ENTRIES {
            state
                .ips
                .retain(|_, window| now.duration_since(window.started) < IP_WINDOW);
        }
        let window = state.ips.entry(ip.to_canonical()).or_insert(Window {
            started: now,
            count: 0,
        });
        if now.duration_since(window.started) >= IP_WINDOW {
            window.started = now;
            window.count = 0;
        }
        if window.count >= IP_ATTEMPTS_PER_WINDOW {
            return Err(RetryAfter(
                (window.started + IP_WINDOW).saturating_duration_since(now),
            ));
        }
        window.count += 1;
        Ok(())
    }

    /// Is this username waiting after too many failures?
    pub fn check_user(&self, username: &str, now: Instant) -> Result<(), RetryAfter> {
        let state = self.state();
        match state
            .users
            .get(&key(username))
            .and_then(|failures| failures.locked_until)
        {
            Some(until) if until > now => Err(RetryAfter(until - now)),
            _ => Ok(()),
        }
    }

    /// Notes a wrong password for this username (also for usernames that don't exist, so the
    /// brakes don't tell which ones do).
    pub fn user_failed(&self, username: &str, now: Instant) {
        let mut state = self.state();
        if state.users.len() >= MAX_ENTRIES {
            state.users.retain(|_, failures| {
                failures.locked_until.is_some_and(|until| until > now)
                    || now.duration_since(failures.last) < FORGET_AFTER
            });
        }
        let failures = state.users.entry(key(username)).or_insert(Failures {
            count: 0,
            last: now,
            locked_until: None,
        });
        if now.duration_since(failures.last) >= FORGET_AFTER {
            failures.count = 0;
        }
        failures.count += 1;
        failures.last = now;
        failures.locked_until = wait_after(failures.count).map(|wait| now + wait);
    }

    pub fn user_succeeded(&self, username: &str) {
        self.state().users.remove(&key(username));
    }

    /// Notes a wrong pairing code. Returns true when the limit was reached: then every open
    /// code must be cancelled (and the count starts over).
    pub fn pairing_failed(&self) -> bool {
        let mut state = self.state();
        state.pairing_failures += 1;
        if state.pairing_failures >= crate::auth::pairing::MAX_FAILURES {
            state.pairing_failures = 0;
            true
        } else {
            false
        }
    }
}

fn key(username: &str) -> String {
    username.trim().to_lowercase()
}

/// The wait after the `count`-th failure in a row: none for the first four, then 30 s, 60 s,
/// 120 s, … up to 15 minutes.
pub fn wait_after(count: u32) -> Option<Duration> {
    let extra = count.checked_sub(FREE_FAILURES)?;
    let factor = 1u32.checked_shl(extra.min(16)).unwrap_or(u32::MAX);
    Some(FIRST_WAIT.saturating_mul(factor).min(MAX_WAIT))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Thousands of addresses (a scan) can't make the limiter grow without end: once it is full,
    /// addresses whose minute is over are dropped, and those still counting are kept.
    #[test]
    fn many_addresses_dont_fill_memory() {
        let limiter = RateLimiter::new();
        let start = Instant::now();
        for i in 0..MAX_ENTRIES as u32 {
            limiter
                .attempt_from(IpAddr::from((0x0a00_0000 + i).to_be_bytes()), start)
                .unwrap();
        }
        let soon = start + Duration::from_secs(30);
        limiter
            .attempt_from("192.168.1.1".parse().unwrap(), soon)
            .unwrap();
        assert_eq!(
            limiter.state().ips.len(),
            MAX_ENTRIES + 1,
            "all still counting"
        );
        let later = start + IP_WINDOW + Duration::from_secs(1);
        limiter
            .attempt_from("192.168.1.2".parse().unwrap(), later)
            .unwrap();
        assert_eq!(limiter.state().ips.len(), 2, "only the two recent ones");
    }

    /// The same for usernames: when full, only names with a recent failure or a running wait stay.
    #[test]
    fn many_usernames_dont_fill_memory() {
        let limiter = RateLimiter::new();
        let start = Instant::now();
        for i in 0..MAX_ENTRIES {
            limiter.user_failed(&format!("user{i}"), start);
        }
        // Locked once, long ago: its wait is over, so it can go.
        for _ in 0..FREE_FAILURES + 1 {
            limiter.user_failed("long ago", start);
        }
        let recent = start + FORGET_AFTER - Duration::from_secs(60 * 60);
        limiter.user_failed("recent", recent);
        let now = start + FORGET_AFTER + Duration::from_secs(60);
        limiter.user_failed("new", now);
        let state = limiter.state();
        let mut left: Vec<&String> = state.users.keys().collect();
        left.sort();
        assert_eq!(left, ["new", "recent"]);
    }

    /// Failures are remembered for a day: five wrong passwords in the morning and one more in the
    /// afternoon still mean a wait.
    #[test]
    fn failures_are_remembered_for_a_day() {
        let limiter = RateLimiter::new();
        let morning = Instant::now();
        for _ in 0..FREE_FAILURES {
            limiter.user_failed("lucas", morning);
        }
        let afternoon = morning + Duration::from_secs(5 * 60 * 60);
        assert!(limiter.check_user("lucas", afternoon).is_ok());
        limiter.user_failed("lucas", afternoon);
        assert!(limiter.check_user("lucas", afternoon).is_err());
        // A day after the last one, a fresh start.
        let tomorrow = afternoon + FORGET_AFTER;
        limiter.user_failed("lucas", tomorrow);
        assert!(limiter.check_user("lucas", tomorrow).is_ok());
    }

    #[test]
    fn waits_double_up_to_fifteen_minutes() {
        assert_eq!(wait_after(1), None);
        assert_eq!(wait_after(4), None);
        assert_eq!(wait_after(5), Some(Duration::from_secs(30)));
        assert_eq!(wait_after(6), Some(Duration::from_secs(60)));
        assert_eq!(wait_after(7), Some(Duration::from_secs(120)));
        assert_eq!(wait_after(10), Some(Duration::from_secs(900)));
        assert_eq!(wait_after(1000), Some(MAX_WAIT));
    }

    #[test]
    fn ip_window_allows_twenty_a_minute() {
        let limiter = RateLimiter::new();
        let ip: IpAddr = "192.168.1.5".parse().unwrap();
        let start = Instant::now();
        for _ in 0..IP_ATTEMPTS_PER_WINDOW {
            limiter.attempt_from(ip, start).unwrap();
        }
        let wait = limiter
            .attempt_from(ip, start + Duration::from_secs(10))
            .unwrap_err();
        assert_eq!(wait.0, Duration::from_secs(50));
        assert_eq!(wait.seconds(), 50);
        // Another address is not affected; the same one works again after the minute.
        limiter
            .attempt_from("192.168.1.6".parse().unwrap(), start)
            .unwrap();
        limiter.attempt_from(ip, start + IP_WINDOW).unwrap();
        // IPv4 arriving as IPv6 counts as the same address.
        let mapped: IpAddr = "::ffff:192.168.1.6".parse().unwrap();
        for _ in 1..IP_ATTEMPTS_PER_WINDOW {
            limiter.attempt_from(mapped, start).unwrap();
        }
        assert!(limiter.attempt_from(mapped, start).is_err());
    }

    #[test]
    fn usernames_wait_after_five_failures() {
        let limiter = RateLimiter::new();
        let now = Instant::now();
        for _ in 0..4 {
            limiter.user_failed("Lucas", now);
        }
        limiter.check_user("lucas", now).unwrap();
        limiter.user_failed("lucas", now);
        assert_eq!(
            limiter.check_user("LUCAS", now),
            Err(RetryAfter(Duration::from_secs(30)))
        );
        let later = now + Duration::from_secs(30);
        limiter.check_user("lucas", later).unwrap();
        limiter.user_failed("lucas", later);
        assert_eq!(
            limiter.check_user("lucas", later),
            Err(RetryAfter(Duration::from_secs(60)))
        );
        limiter.user_succeeded("lucas");
        limiter.check_user("lucas", later).unwrap();
        // Old failures are forgotten.
        for _ in 0..4 {
            limiter.user_failed("anna", now);
        }
        limiter.user_failed("anna", now + FORGET_AFTER);
        limiter.check_user("anna", now + FORGET_AFTER).unwrap();
    }

    #[test]
    fn many_wrong_codes_cancel_all() {
        let limiter = RateLimiter::new();
        for _ in 1..crate::auth::pairing::MAX_FAILURES {
            assert!(!limiter.pairing_failed());
        }
        assert!(limiter.pairing_failed());
        assert!(!limiter.pairing_failed(), "the count starts over");
    }

    #[test]
    fn retry_after_rounds_up() {
        assert_eq!(RetryAfter(Duration::from_millis(1500)).seconds(), 2);
        assert_eq!(RetryAfter(Duration::from_secs(3)).seconds(), 3);
        assert_eq!(RetryAfter(Duration::ZERO).seconds(), 1);
    }
}
