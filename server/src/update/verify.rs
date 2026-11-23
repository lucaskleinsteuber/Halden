//! Checking a release: the checksum list must carry the owner's minisign signature, and every
//! download must match its line in that list.

use anyhow::{Result, bail};
use minisign_verify::{PublicKey, Signature};

/// Is `signature` (the `.minisig` file) a valid signature of `sums` by `key`?
pub fn signature(sums: &[u8], signature: &str, key: &str) -> Result<()> {
    let key = PublicKey::from_base64(key.trim())
        .map_err(|e| anyhow::anyhow!("the release key in this build is not valid: {e}"))?;
    let signature = Signature::decode(signature)
        .map_err(|e| anyhow::anyhow!("the release's signature can't be read: {e}"))?;
    // Only the prehashed form minisign makes today; the legacy one is refused.
    if key.verify(sums, &signature, false).is_err() {
        bail!("the release is not signed with Halden's key; it is not installed");
    }
    Ok(())
}

/// The SHA-256 the checksum list gives for `file` (`<hex>  <name>`, as `sha256sum` writes it).
pub fn expected_hash(sums: &str, file: &str) -> Option<[u8; 32]> {
    sums.lines().find_map(|line| {
        let (hex, name) = line.split_once(char::is_whitespace)?;
        let name = name.trim_start().trim_start_matches('*');
        if name != file {
            return None;
        }
        let mut hash = [0u8; 32];
        hex::decode_to_slice(hex, &mut hash).ok()?;
        Some(hash)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_lines() {
        let sums = format!(
            "{}  halden-0.2.0-x86_64-linux.tar.gz\n{} *other.tar.gz\n",
            "ab".repeat(32),
            "cd".repeat(32)
        );
        assert_eq!(
            expected_hash(&sums, "halden-0.2.0-x86_64-linux.tar.gz"),
            Some([0xab; 32])
        );
        assert_eq!(expected_hash(&sums, "other.tar.gz"), Some([0xcd; 32]));
        assert_eq!(expected_hash(&sums, "missing.tar.gz"), None);
        assert_eq!(expected_hash("zz  x\n", "x"), None);
    }
}
