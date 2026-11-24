//! Passwords: the rules for new ones, and Argon2id hashing.
//!
//! Argon2id with 19 MiB, two passes and one lane is the OWASP recommendation. Hashing takes
//! real time and memory on purpose, so it runs on the blocking thread pool (the server keeps
//! answering other requests) and only a few hashes run at once (guessing can't eat the RAM).

use std::sync::OnceLock;

use anyhow::{Context, Result, anyhow};
use argon2::{
    Algorithm, Argon2, Params, Version,
    password_hash::{PasswordHasher, PasswordVerifier, phc::PasswordHash},
};
use tokio::sync::Semaphore;

pub const MIN_CHARS: usize = 8;
/// Longer input is refused so nobody can make the server hash megabytes.
pub const MAX_BYTES: usize = 1024;

const MEMORY_KIB: u32 = 19 * 1024;
const PASSES: u32 = 2;
const LANES: u32 = 1;

/// At most this many hashes at the same time (each needs 19 MiB).
static PERMITS: Semaphore = Semaphore::const_new(4);

fn argon2() -> Argon2<'static> {
    let params =
        Params::new(MEMORY_KIB, PASSES, LANES, None).expect("the Argon2 parameters are valid");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

/// Checks a new password against the rules. The error is a sentence for the person.
pub fn check_new(password: &str, username: &str) -> Result<(), String> {
    if password.chars().count() < MIN_CHARS {
        return Err(format!(
            "The password needs at least {MIN_CHARS} characters."
        ));
    }
    if password.len() > MAX_BYTES {
        return Err(format!("The password may have at most {MAX_BYTES} bytes."));
    }
    if password.trim().to_lowercase() == username.trim().to_lowercase() {
        return Err("The password must not be the username.".into());
    }
    Ok(())
}

fn hash_blocking(password: &str) -> Result<String> {
    let hash: PasswordHash = argon2()
        .hash_password(password.as_bytes())
        .map_err(|error| anyhow!("could not hash the password: {error}"))?;
    Ok(hash.to_string())
}

fn verify_blocking(password: &str, phc: &str) -> bool {
    argon2().verify_password(password.as_bytes(), phc).is_ok()
}

/// Hashes a password into a PHC string (`$argon2id$v=19$m=19456,t=2,p=1$…`) with a fresh salt.
pub async fn hash(password: String) -> Result<String> {
    let _permit = PERMITS
        .acquire()
        .await
        .context("the password hasher is closed")?;
    tokio::task::spawn_blocking(move || hash_blocking(&password))
        .await
        .context("the password hasher stopped")?
}

/// Checks a password against a stored hash.
///
/// Without a hash (unknown username, or an account that only pairs) a stand-in hash is checked
/// all the same and the answer is "no", so the response time does not tell which usernames exist.
pub async fn verify(password: String, phc: Option<String>) -> bool {
    if password.len() > MAX_BYTES {
        return false;
    }
    let Ok(_permit) = PERMITS.acquire().await else {
        return false;
    };
    tokio::task::spawn_blocking(move || match phc {
        Some(phc) => verify_blocking(&password, &phc),
        None => {
            let _ = verify_blocking(&password, stand_in_hash());
            false
        }
    })
    .await
    .unwrap_or(false)
}

/// Prepares the stand-in hash, so even the first check of an unknown username takes the usual
/// time. Called when the server starts.
pub async fn warm_up() {
    let _ = tokio::task::spawn_blocking(stand_in_hash).await;
}

fn stand_in_hash() -> &'static str {
    static STAND_IN: OnceLock<String> = OnceLock::new();
    STAND_IN.get_or_init(|| hash_blocking("stand-in password, never matches").unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rules_for_new_passwords() {
        assert!(check_new("short", "lucas").is_err());
        assert!(check_new("Lucas123", "lucas123").is_err());
        assert!(check_new(&"x".repeat(MAX_BYTES + 1), "lucas").is_err());
        assert!(
            check_new(&"x".repeat(MAX_BYTES), "lucas").is_ok(),
            "the limit itself is fine"
        );
        assert!(check_new("correct horse", "lucas").is_ok());
        // Characters count, not bytes: eight umlauts are eight characters.
        assert!(check_new("ääääääää", "lucas").is_ok());
    }

    #[tokio::test]
    async fn hashes_verify_and_differ() {
        let first = hash("correct horse".into()).await.unwrap();
        let second = hash("correct horse".into()).await.unwrap();
        assert!(
            first.starts_with("$argon2id$v=19$m=19456,t=2,p=1$"),
            "{first}"
        );
        assert_ne!(first, second, "every hash gets its own salt");
        assert!(verify("correct horse".into(), Some(first.clone())).await);
        assert!(!verify("correct horsf".into(), Some(first)).await);
        assert!(!verify("correct horse".into(), None).await);
        assert!(!verify("anything".into(), Some("not a hash".into())).await);
    }

    /// The longest allowed password works; the stand-in hash for unknown users is a real hash
    /// with the same cost, so checking it takes as long as checking a real one.
    #[tokio::test]
    async fn the_longest_password_works_and_the_stand_in_costs_the_same() {
        let longest = "y".repeat(MAX_BYTES);
        let stored = hash(longest.clone()).await.unwrap();
        assert!(verify(longest, Some(stored.clone())).await);
        assert!(!verify("y".repeat(MAX_BYTES + 1), Some(stored.clone())).await);
        let params = format!("m={MEMORY_KIB},t={PASSES},p={LANES}");
        assert!(stored.contains(&params), "{stored}");
        let stand_in = argon2::PasswordHash::new(stand_in_hash()).expect("a valid hash");
        assert!(stand_in.to_string().contains(&params), "{stand_in}");
    }
}
