#![no_main]
//! Pairing codes and tokens as typed or sent: never a crash, normalised codes are stable.
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &str| {
    if let Some(code) = halden::auth::pairing::normalize(input) {
        assert_eq!(halden::auth::pairing::normalize(&code).as_deref(), Some(code.as_str()));
        let _ = halden::auth::pairing::display(&code);
    }
    let _ = halden::auth::token::is_well_formed(input);
    let _ = halden::accounts::check_username(input);
    let _ = input.parse::<halden::net::Cidr>();
});
