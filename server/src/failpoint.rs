//! Places where tests make the server stop dead on purpose, to prove that a crash at exactly
//! that moment loses nothing. Only debug builds look at `HALDEN_FAILPOINT`; release builds have
//! no failpoints at all.

/// Stops the process at once, like a power cut or `kill -9` (nothing is cleaned up), when
/// `HALDEN_FAILPOINT` names this point.
#[inline]
pub fn hit(name: &str) {
    #[cfg(debug_assertions)]
    if std::env::var("HALDEN_FAILPOINT").is_ok_and(|wanted| wanted == name) {
        eprintln!("failpoint {name}: stopping dead");
        std::process::abort();
    }
    #[cfg(not(debug_assertions))]
    let _ = name;
}
