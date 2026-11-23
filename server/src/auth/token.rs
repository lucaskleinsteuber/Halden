//! Device tokens: what an app sends with every request after it signed in.
//!
//! A token is `hd1_` followed by 32 random bytes in base64url. The prefix lets secret scanners
//! (GitHub and others) recognise a leaked Halden token. The server stores only its SHA-256, so a
//! copy of the database contains no usable tokens.

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};

pub const PREFIX: &str = "hd1_";
const RANDOM_BYTES: usize = 32;
/// Length of 32 bytes in base64 without padding.
const ENCODED_LEN: usize = 43;

pub struct NewToken {
    /// Handed to the app once, never stored.
    pub token: String,
    pub hash: [u8; 32],
}

pub fn generate() -> NewToken {
    let mut bytes = [0u8; RANDOM_BYTES];
    rand::fill(&mut bytes);
    let token = format!("{PREFIX}{}", URL_SAFE_NO_PAD.encode(bytes));
    let hash = hash(&token);
    NewToken { token, hash }
}

pub fn hash(token: &str) -> [u8; 32] {
    Sha256::digest(token.as_bytes()).into()
}

/// Does this look like a token at all? Saves a database lookup for garbage.
pub fn is_well_formed(token: &str) -> bool {
    token.strip_prefix(PREFIX).is_some_and(|rest| {
        rest.len() == ENCODED_LEN
            && rest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_have_the_expected_shape() {
        let first = generate();
        let second = generate();
        assert!(first.token.starts_with("hd1_"));
        assert_eq!(first.token.len(), 4 + 43);
        assert!(is_well_formed(&first.token));
        assert_ne!(first.token, second.token);
        assert_eq!(first.hash, hash(&first.token));
        assert_ne!(first.hash, second.hash);
    }

    #[test]
    fn garbage_is_not_a_token() {
        assert!(!is_well_formed(""));
        assert!(!is_well_formed("hd1_"));
        assert!(!is_well_formed(
            "hd2_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ));
        assert!(!is_well_formed(
            "hd1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        ));
        assert!(is_well_formed(
            "hd1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ));
    }
}
