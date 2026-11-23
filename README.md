# Halden

**The photo app that doesn't give you twitches.**

Halden is a native iPhone camera with your own self-hosted photo library. You take a photo or
video, it is saved on the phone right away and uploaded to your own server in the background, in
full quality, without you having to think about it. No cloud, no subscription, no jank.

> **Status:** early development. The server has accounts, device pairing, resumable uploads,
> sync, file delivery, metadata corrections, the trash, format conversions, database backups and
> a mirror to a second disk; signed updates, Docker and the iPhone app come next. Nothing here is ready for your only copy of your photos yet.

## How it fits together

| Part | Built with | State |
|---|---|---|
| Server | Rust (Axum, Tokio, rustls, SQLite) for Linux | accounts, uploads, sync, library and backup done |
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

For thumbnails of videos and HEIC photos, and for copies in other formats, the server uses
`ffmpeg` and libheif:

```sh
sudo apt install ffmpeg libheif-examples
```

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
disk), the server's certificate and the database. The first time, it also asks for a username
and password for the first account, which becomes the server's owner. Running it again is safe.

When a device connects for the first time, compare the fingerprint it shows with the one from
`halden status`.

### A second copy

Every day the server backs up its database to `<library>/.halden/backups/` (14 are kept). The
photos themselves exist only once until you set up a **mirror** on another disk, and the app
warns about that. With a USB disk or a NAS folder mounted at `/mnt/backup`:

```sh
sudo halden mirror set /mnt/backup/halden
sudo systemctl edit halden      # add:  [Service]  ReadWritePaths=/mnt/backup/halden
sudo systemctl restart halden
```

Every original, conversion and database backup is then copied there in the same readable
layout and checked by its SHA-256. If the disk is unplugged, Halden waits and catches up when it
is back.

### Find it in the home network

The server announces itself with Bonjour, so the app lists it by itself when the phone is in the
same home network. If `ufw` is on, allow the port and Bonjour: `sudo ufw allow 47130/tcp` and
`sudo ufw allow 5353/udp`. Over Tailscale or from outside, the QR code carries the addresses.

### Add a device

```sh
sudo halden pair                 # QR code for the only account
sudo halden pair --user anna     # or for a specific one
```

Scan the QR code with the Halden app. It carries the server's addresses, its certificate
fingerprint and a one-time code that is valid for 5 minutes. Devices can also sign in with
username and password; a device added that way shows up as new on the account's other devices
until someone confirms it.

### Commands

| Command | What it does |
|---|---|
| `halden setup` | Set up config, folders, certificate and database |
| `halden status` | Show state, fingerprint, addresses, free space and the library's numbers |
| `halden serve` | Run the server (systemd does this for you) |
| `halden user add <name> [--owner]` | Create an account (asks for its password) |
| `halden user list` | List the accounts |
| `halden user passwd <name> [--sign-out]` | Set a new password, optionally signing out its devices |
| `halden user role <name> owner\|member` | Change an account's role |
| `halden user remove <name>` | Delete an account and sign out its devices |
| `halden pair [--user <name>]` | Show a QR code that adds a device |
| `halden devices [--user <name>]` | List signed-in devices |
| `halden devices revoke <id>` | Sign a device out |
| `halden log [--limit 50]` | Show the security log |
| `halden backup now\|list` | Back up the database now, or list the backups |
| `halden backup restore <file>` | Put a backup in place of the database (server stopped) |
| `halden mirror set <folder>\|off\|status` | Mirror everything to a second disk |
| `halden config list` | Show every setting with its value and what it does |
| `halden config get\|set\|reset <setting> [value]` | Read or change one setting |
| `halden doctor [--files]` | Check everything and say how to fix what's wrong; `--files` reads every file back |

### Settings

Everything lives in `/etc/halden/config.toml`; every key is optional. Change settings with
`halden config set <setting> <value>` (comments in the file stay) or in the app; the server
picks up changes by itself within a few seconds, without stopping. A file with a mistake is not
used: the server keeps its settings and `halden doctor` says what's wrong. Besides `[server]`,
`[network]` and `[tls]`:

```toml
[storage]
path_template = "{user}/{year}/{month}/{date}_{time}"  # where originals go in the library
min_free_gb = 5              # refuse uploads that would leave less free space
upload_expiry_days = 7       # throw away unfinished uploads after this long

[library]
location_suggest_minutes = 120  # suggest a place from photos at most this far apart in time
trash_days = 30              # deleted photos stay in the trash this long
tombstone_days = 90          # devices learn about deletions within this time

[jobs]
workers = 1                  # background jobs at once (lowest priority)
thumbnail_delay_minutes = 10 # make thumbnails the phone didn't send after this long
external_timeout_minutes = 30

[backup]
keep = 14                    # database backups kept

[mirror]
path = "/mnt/backup/halden"  # set with `halden mirror set`; leave out for no mirror

[auth]
password_login = true        # false: devices can only be added by pairing
device_inactive_days = 365   # sign out devices unused this long (0 = never)

[security]
log_retention_days = 90      # keep security log entries this long (0 = forever)

[network]
bonjour = true               # announce the server in the home network

[update]
check_daily = true           # look for a new version once a day; installing waits for you
beta = false                 # also offer test versions
```

The app can change every setting except folders, port and certificate; settings that open the
server up or can delete data need your password again.

### Speed

The server is built to stay fast with a big library: one database connection writes while
several read in parallel, every request checks its token with a single indexed lookup, HTTP/2
flow-control windows are sized for uploads over Wi-Fi and Tailscale, uploads are hashed while
they are written (never read twice), sync reads one index range however big the library is,
thumbnails come 500 at a time, files are cached by their hash forever, JSON answers are
compressed, and background work runs at the lowest priority. `cargo run --release
--example loadtest` measures it against a library of 100,000 photos.

### More

- [Protocol](docs/PROTOCOL.md): the HTTP API the apps use
- [Security model](docs/SECURITY_MODEL.md): what is protected, how, and the limits

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
