#![no_main]
//! Path templates and the paths they make: never outside the library.
use chrono::{FixedOffset, TimeZone};
use halden::library::paths::{PathTemplate, resolve};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: (&str, &str, i64, i32)| {
    let (template, user, seconds, offset) = input;
    if let Ok(template) = PathTemplate::parse(template) {
        let Some(offset) = FixedOffset::east_opt(offset % 86_400) else {
            return;
        };
        let Some(time) = offset.timestamp_opt(seconds % 32_503_680_000, 0).single() else {
            return;
        };
        // Usernames are checked before they get here: only plain ones.
        if halden::accounts::check_username(user).is_err() {
            return;
        }
        let path = template.render(user, time);
        let text = path.to_string_lossy();
        let full = resolve(std::path::Path::new("/library"), &text)
            .expect("an accepted template always makes a path inside the library");
        assert!(full.starts_with("/library"));
    }
    // And whatever is stored, resolving never leaves the root.
    if let Some(full) = resolve(std::path::Path::new("/library"), template) {
        assert!(full.starts_with("/library"));
    }
});
