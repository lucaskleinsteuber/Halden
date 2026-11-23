//! Pairing codes and the QR code that carries one.
//!
//! A code is 10 characters of Crockford base32 (about 50 bits), valid for 5 minutes and only
//! once. People can type it too: case, dashes and spaces don't matter, and the look-alikes
//! O, I and L are read as 0, 1 and 1. The server stores only its SHA-256.
//!
//! The QR code holds a `halden://pair?…` link with everything a new device needs: which server
//! this is, where to reach it, the certificate fingerprint to pin and the code.

use std::{fmt::Write as _, net::IpAddr};

use anyhow::{Result, anyhow};
use qrcode::{EcLevel, QrCode, render::unicode::Dense1x2};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub const CODE_LEN: usize = 10;
/// How long a code stays valid.
pub const CODE_TTL_MS: i64 = 5 * 60 * 1000;
/// After this many wrong codes in total, all open codes are cancelled and counting starts over.
pub const MAX_FAILURES: u32 = 100;

/// At most this many addresses go into the QR code, so it stays small enough for a terminal.
const MAX_ADDRESSES: usize = 4;

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// A new random code, normalised (10 characters, no dash).
pub fn generate_code() -> String {
    let mut bytes = [0u8; CODE_LEN];
    rand::fill(&mut bytes);
    // 256 is a multiple of 32, so taking the low five bits is unbiased.
    bytes
        .iter()
        .map(|b| char::from(ALPHABET[usize::from(b & 31)]))
        .collect()
}

/// Turns what someone typed or scanned into the normalised code, or `None` if it can't be one.
pub fn normalize(input: &str) -> Option<String> {
    let mut code = String::with_capacity(CODE_LEN);
    for c in input.trim().chars() {
        if c == '-' || c == ' ' {
            continue;
        }
        let c = match c.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            c => c,
        };
        if !c.is_ascii() || !ALPHABET.contains(&(c as u8)) || code.len() == CODE_LEN {
            return None;
        }
        code.push(c);
    }
    (code.len() == CODE_LEN).then_some(code)
}

/// `ABCDE-FGHJK`: easier to read out and type.
pub fn display(code: &str) -> String {
    match code.split_at_checked(CODE_LEN / 2) {
        Some((first, second)) => format!("{first}-{second}"),
        None => code.to_string(),
    }
}

pub fn hash(normalized: &str) -> [u8; 32] {
    Sha256::digest(normalized.as_bytes()).into()
}

/// Everything the QR code tells a new device.
#[derive(Clone, Copy)]
pub struct Invite<'a> {
    pub server_id: Uuid,
    pub server_name: &'a str,
    pub addresses: &'a [IpAddr],
    pub port: u16,
    /// Certificate fingerprint, lowercase hex.
    pub fingerprint: &'a str,
    /// Normalised code.
    pub code: &'a str,
}

impl Invite<'_> {
    /// `halden://pair?v=1&id=…&name=…&addr=192.168.178.72,100.64.1.2&port=47130&fp=…&code=…`
    pub fn url(&self) -> String {
        let addresses: Vec<String> = self
            .addresses
            .iter()
            .take(MAX_ADDRESSES)
            .map(|ip| encode_component(&ip.to_string()))
            .collect();
        format!(
            "halden://pair?v=1&id={}&name={}&addr={}&port={}&fp={}&code={}",
            self.server_id,
            encode_component(self.server_name),
            addresses.join(","),
            self.port,
            self.fingerprint,
            self.code
        )
    }
}

/// Percent-encodes everything except the characters URLs never need to escape.
fn encode_component(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            let _ = write!(out, "%{byte:02X}");
        }
    }
    out
}

/// Draws a QR code with block characters for a terminal. With `ansi`, the colours are set
/// explicitly (black on white), so it scans on dark and light terminals alike. The lowest error
/// correction keeps it small; a screen shows it without smudges.
pub fn render_qr(content: &str, ansi: bool) -> Result<String> {
    let code = QrCode::with_error_correction_level(content.as_bytes(), EcLevel::L)
        .map_err(|error| anyhow!("could not make a QR code: {error}"))?;
    let image = code
        .render::<Dense1x2>()
        .dark_color(Dense1x2::Dark)
        .light_color(Dense1x2::Light)
        .quiet_zone(true)
        .build();
    if !ansi {
        return Ok(image);
    }
    Ok(image
        .lines()
        .map(|line| format!("\x1b[38;5;16;48;5;231m{line}\x1b[0m"))
        .collect::<Vec<_>>()
        .join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_ten_crockford_characters() {
        for _ in 0..100 {
            let code = generate_code();
            assert_eq!(code.len(), CODE_LEN);
            assert_eq!(normalize(&code).as_deref(), Some(code.as_str()));
        }
        assert_ne!(generate_code(), generate_code());
    }

    #[test]
    fn typing_mistakes_are_forgiven() {
        assert_eq!(normalize("abcde-fghjk").as_deref(), Some("ABCDEFGHJK"));
        assert_eq!(normalize(" 0o1il 23456 ").as_deref(), Some("0011123456"));
        assert_eq!(normalize("ABCDE-FGHJ"), None, "too short");
        assert_eq!(normalize("ABCDE-FGHJKM"), None, "too long");
        assert_eq!(normalize("ABCDE-FGHJU"), None, "U is not in the alphabet");
        assert_eq!(normalize("ÄBCDE-FGHJK"), None);
        assert_eq!(display("ABCDEFGHJK"), "ABCDE-FGHJK");
    }

    #[test]
    fn invite_url_carries_everything() {
        let addresses: Vec<IpAddr> = vec![
            "192.168.178.72".parse().unwrap(),
            "fd7a:115c:a1e0::5".parse().unwrap(),
        ];
        let invite = Invite {
            server_id: Uuid::nil(),
            server_name: "Lucas' Server",
            addresses: &addresses,
            port: 47130,
            fingerprint: "ab12",
            code: "ABCDEFGHJK",
        };
        assert_eq!(
            invite.url(),
            "halden://pair?v=1&id=00000000-0000-0000-0000-000000000000\
             &name=Lucas%27%20Server&addr=192.168.178.72,fd7a%3A115c%3Aa1e0%3A%3A5\
             &port=47130&fp=ab12&code=ABCDEFGHJK"
        );
        let many: Vec<IpAddr> = (1..=6)
            .map(|n| format!("192.168.1.{n}").parse().unwrap())
            .collect();
        let crowded = Invite {
            addresses: &many,
            ..invite
        };
        assert!(
            crowded
                .url()
                .contains("addr=192.168.1.1,192.168.1.2,192.168.1.3,192.168.1.4&")
        );

        let qr = render_qr(&invite.url(), false).unwrap();
        assert!(qr.lines().count() > 10);
        assert!(render_qr(&invite.url(), true).unwrap().contains("\x1b[0m"));
    }
}
