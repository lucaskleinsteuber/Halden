#![no_main]
//! Config files and changes to them: a file is either valid or refused, and a change keeps the
//! file valid or is refused.
use halden::config::{Config, edit, keys};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: (&str, u8, &str)| {
    let (text, which, value) = input;
    if let Ok(config) = toml::from_str::<Config>(text) {
        let _ = config.validate();
    }
    let key = &keys::KEYS[usize::from(which) % keys::KEYS.len()];
    if let Ok(change) = edit::from_text(key, value) {
        if let Ok((new_text, config)) = edit::apply(text, &[(key, change)]) {
            config.validate().expect("apply only returns valid configs");
            let again: Config = toml::from_str(&new_text).expect("the written file parses");
            assert_eq!(again, config);
        }
    }
});
