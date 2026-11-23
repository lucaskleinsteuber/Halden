#![no_main]
//! EXIF and QuickTime metadata from any file: never a crash, never a hang (libFuzzer's timeout
//! catches loops).
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let dir = std::env::temp_dir().join(format!("halden-fuzz-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    for name in ["photo.jpg", "photo.heic", "video.mov"] {
        let path = dir.join(name);
        if std::fs::write(&path, data).is_ok() {
            let _ = halden::library::metadata::read(&path);
        }
    }
});
