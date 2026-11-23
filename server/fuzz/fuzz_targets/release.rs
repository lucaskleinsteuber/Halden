#![no_main]
//! What the updater reads from the internet: the release list, the checksum list and the
//! signature. Nothing may crash, and nothing unsigned may pass.
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: (&[u8], &str, &str)| {
    let (json, sums, signature) = input;
    if let Ok(releases) = halden::update::release::parse(json) {
        let current = semver::Version::new(0, 1, 0);
        if let Some(found) = halden::update::release::choose(&releases, &current, true, "x86_64") {
            assert!(found.version > current);
        }
    }
    let _ = halden::update::verify::expected_hash(sums, "halden-0.2.0-x86_64-linux.tar.gz");
    // A fixed key: random input is never a valid signature by it.
    let key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
    assert!(halden::update::verify::signature(sums.as_bytes(), signature, key).is_err());
});
