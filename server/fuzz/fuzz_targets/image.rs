#![no_main]
//! Decoding pictures for thumbnails: broken files fail, huge ones are refused before memory is
//! reserved (libFuzzer's -rss_limit_mb catches anything that grows).
use image::DynamicImage;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let path = std::env::temp_dir().join(format!("halden-fuzz-image-{}", std::process::id()));
    if std::fs::write(&path, data).is_err() {
        return;
    }
    if let Ok(decoder) = halden::jobs::thumbnail::decoder_for(&path) {
        if let Ok(image) = DynamicImage::from_decoder(decoder) {
            let _ = halden::jobs::thumbnail::shrink(&image, 64, 80);
        }
    }
});
