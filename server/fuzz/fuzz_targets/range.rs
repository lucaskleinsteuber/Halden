#![no_main]
//! `Range` headers: any answer is a range inside the file, or the whole file.
use halden::files::{RangeRequest, parse_range};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: (&str, u64)| {
    let (header, size) = input;
    if let RangeRequest::Partial(range) = parse_range(header, size) {
        assert!(range.start <= range.end && range.end < size);
    }
});
