# Testing the server

Halden's promise is that nothing is lost, so the server is tested from many sides. Every push
runs the fast checks; the slow and root-only ones run every night (and by hand) in
`.github/workflows/server-intensive.yml`.

## On every push (`server.yml`)

| What | How |
|---|---|
| Format, lints | `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` |
| Dependencies | `cargo deny check`: licences, known vulnerabilities, only crates.io |
| Unit and integration tests | `cargo test`: the real server on a free port, talked to over pinned TLS 1.3 like the app |
| Crash tests | the real `halden serve` killed with `kill -9` mid-upload, and stopped dead at failpoints (`HALDEN_FAILPOINT`, debug builds only) between moving a file and recording it, after recording, while deleting for good; `halden doctor --files` must then find every file intact and none unknown |
| Access rules | every route without, with a forged and with a signed-out token; members on owner routes; one account on another's photos, uploads and devices |
| Attacks | paths that try to leave the library, oversized bodies and headers, forged client addresses, hundreds of idle connections, headers sent a byte a second |
| Random inputs | proptest: range headers, path templates and paths (thousands of cases), uploads cut up and interrupted at random, and a model test of the whole library in which every device, whenever it last synced, ends with exactly the server's state |
| Bad files | a decompression bomb, broken JPEG, HEIC and video, wrong types, a giant EXIF block, an empty file |
| Upgrades | databases at every earlier stage, and old backups, brought up to date without loss |
| Updates | a stand-in for GitHub with releases signed by a test key: wrong key, changed package, foreign files, a version that lies or can't read the database are all refused |
| Docker | the image is built and started read-only as a user would, then used from outside |

## Every night (`server-intensive.yml`)

| Job | What |
|---|---|
| system | on a fresh Ubuntu: `get-halden.sh` installs from signed stand-in releases (a wrongly signed one is refused), the hardened systemd service runs, real HEIC photos and HEVC videos get thumbnails and copies inside the sandbox, a mirror under `/mnt` gets checked copies, an update from the app installs 0.0.2, a broken 0.0.3 is rolled back, every file is checked, a backup is restored (`packaging/tests/system-test.sh`) |
| disks | loop devices: the library disk fills up mid-upload, turns read-only, the system disk fills up, the mirror disk starts failing in the middle of a copy (device-mapper) (`server/tests/disks.rs`, `HALDEN_ROOT_TESTS=1`) |
| long | every test with ten times the random cases (`HALDEN_TEST_SCALE=10`) |
| memory | the load test with mimalloc and with the system allocator, and a 15-minute soak that watches memory, open files and speed |
| fuzz | two minutes of mutated input per parser (`server/fuzz`) |
| audit | `cargo audit` |

## By hand

```sh
cd server
cargo llvm-cov --summary-only                                   # which lines the tests reach
HALDEN_TEST_SCALE=20 cargo test --release --test properties     # many more random cases
cargo run --release --example loadtest out.md                   # speed with 100,000 photos
SOAK_MINUTES=60 cargo run --release --example loadtest soak.md  # an hour: memory, files, speed
cd fuzz && cargo +nightly fuzz run metadata -- -max_total_time=1800
cargo mutants --file src/upload/mod.rs                          # would a test notice a bug?
```
