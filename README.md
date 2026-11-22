# Halden

**The photo app that doesn't give you twitches.**

Halden is a native iPhone camera with your own self-hosted photo library. You take a photo or
video, it is saved on the phone right away and uploaded to your own server in the background, in
full quality, without you having to think about it. No cloud, no subscription, no jank.

> **Status:** early development. The server foundation is in place; uploads and the iPhone app
> come next. Nothing here is ready for your only copy of your photos yet.

## How it fits together

| Part | Built with | State |
|---|---|---|
| Server | Rust (Axum, Tokio, rustls, SQLite) for Linux | foundation done |
| iPhone app | Swift, SwiftUI, AVFoundation | planned |
| Mac app | Swift | later |

### Principles

- **Your originals are never changed.** The server stores every file byte for byte as it was taken.
- **Nothing gets lost.** A photo only counts as backed up once the server has verified its checksum.
- **The shutter never waits.** Uploads run in the background; the camera stays instant.
- **Everything is configurable**, with sensible defaults.
- **Home network first.** The server only talks to your home network and Tailscale unless you
  open it up yourself, and every connection is TLS 1.3 with a pinned certificate.

## Server

### Build

```sh
cd server
cargo build --release
# the program is server/target/release/halden
```

### Set up on Ubuntu Server

```sh
sudo install -m 755 server/target/release/halden /usr/local/bin/halden
sudo useradd --system --home /var/lib/halden --shell /usr/sbin/nologin halden
sudo halden setup --library-dir /srv/halden/library
sudo install -m 644 packaging/systemd/halden.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now halden
halden status
```

`halden setup` creates the config (`/etc/halden/config.toml`), the data folder
(`/var/lib/halden`, best on the system SSD), the library folder for your photos (best on the big
disk), the server's certificate and the database. Running it again is safe.

When a device connects for the first time, compare the fingerprint it shows with the one from
`halden status`.

### Commands

| Command | What it does |
|---|---|
| `halden setup` | Set up config, folders, certificate and database |
| `halden status` | Show state, fingerprint, addresses and free space |
| `halden serve` | Run the server (systemd does this for you) |

### Develop

```sh
cd server
cargo test          # unit and integration tests
cargo clippy --all-targets
cargo run -- --config ../Local/dev/config.toml setup --data-dir "$PWD/../Local/dev/data" --library-dir "$PWD/../Local/dev/library"
cargo run -- --config ../Local/dev/config.toml serve
```

`Local/` is ignored by git; it holds plans, test servers and test results.

## License

[MIT](LICENSE)
