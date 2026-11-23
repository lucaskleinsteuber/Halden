# Changelog

Notable changes to Halden. Newest first. Dates are day.month.year.

There are no version numbers yet; entries are grouped by date until the first release.

## 23.11.2026

### Added

- Server: `halden config list|get|set|reset` changes settings in the config file and keeps its
  comments. The server picks up a changed file by itself within a few seconds (or on
  `systemctl reload halden`) and starts again with it inside the same process, on the same port;
  cut-off uploads continue. A file with a mistake is not used, and the problem is reported.
- Server: admin routes for the apps (owners only): status (disks, accounts, jobs, memory),
  settings, database backups, the mirror, failed jobs with retry, doctor and restart. Folders,
  port and certificate stay terminal-only; settings that open the server up or can delete data
  need the password again. Every change goes to the security log.
- Server: `halden doctor` checks settings, folders, free space, the database, the certificate,
  ffmpeg and libheif (with a real HEIC round trip), the mirror, failed jobs, backups, the clock,
  systemd write permissions and the firewall, and says how to fix each problem.
  `halden doctor --files` reads every original, thumbnail and mirror copy back and compares its
  SHA-256, and lists files the library doesn't know.
- Server: announces itself in the home network with Bonjour (`_halden._tcp`, with its ID,
  fingerprint, API version and name), only on home-network interfaces, so the apps find it
  without an address. `[network] bonjour = false` turns it off.
- Server: updates like Aurelia's. The server looks for a new version once a day and the apps
  show it; `sudo halden update` (or Install in the app, with the password) installs it.
  Releases must carry the owner's minisign signature over `SHA256SUMS` (the key stays on the
  owner's Mac); never an older version, never files outside the package's folder. The database
  is backed up and the new program tests itself on a copy first; if it doesn't answer after the
  restart, the old program and database come back. `halden update --beta on` also offers test
  versions; `[update] check_daily` turns the daily look off.
- Server: one-line install and update (`get-halden.sh`, checks the signature with openssl) and
  `install.sh` in every release package: system user, program, systemd units, ffmpeg and
  libheif, setup with the first account, firewall, start.
- Docker image (`packaging/docker/`): ffmpeg and libheif included, runs as user 10001 with a
  read-only file system, sets itself up on the first start, health check (`halden health`);
  compose file with host networking. CI builds and tests the image on every change.
- Release workflow: tags `server-v<version>` build packages for x86_64 and aarch64 Linux as a
  draft; `scripts/publish-release.sh` signs and publishes on the Mac; the Docker image is built
  from the signed packages only. No release has been made yet.
- Docs: `docs/DOCKER.md`, `docs/UPDATE_SIGNING.md`, `docs/RELEASING.md`.
- CI: `cargo deny` checks the licences, known vulnerabilities and sources of all dependencies.
- Tests: every route without, with a forged and with a signed-out token; members on owner
  routes; one account on another's photos, uploads and devices; paths that try to leave the
  library; oversized bodies and headers; forged client addresses; hundreds of idle connections
  and headers sent one byte a second. Every `halden` command run as the real program.
- Tests with random inputs (proptest): range headers, path templates, names and paths never
  leave the library (100,000 cases each in the long run); uploads cut up and interrupted at
  random always arrive intact; a model test of the whole library (random uploads, duplicates,
  corrections, trash, restore, deleting) in which every device, whenever it last synced, ends
  with exactly the server's state. `HALDEN_TEST_SCALE` multiplies the number of cases.
- Tests: bad files (decompression bomb, broken JPEG, HEIC and video, wrong type, giant EXIF,
  empty file); databases at every earlier stage, and old backups, brought up to date without
  loss; photos from 1900 and 2100, a leap day, the farthest time zones and the clock change;
  ten photos in the same second; names with emoji and control characters.

- Server: daily database backups on the library disk (checked, 14 kept), also made at start;
  `halden backup now|list|restore`. A restore sets the current database aside first.
- Server: mirror to a second disk (`halden mirror set <folder>`): every original, conversion
  and database backup is copied, checked by SHA-256, and caught up hourly after the disk was
  away. A marker file keeps an unplugged disk's empty mount point from being filled. The apps
  get the backup state in `GET /me` and warn while there is only one copy.
- Server: only one server at a time can use a data folder.
- Server: trash (`POST /assets/trash`, `/restore`, `/delete`). Deleting for good only works from
  the trash; after 30 days in the trash photos are deleted automatically. Tombstones keep no
  place, time or metadata of the deleted photo.
- Server: an extra copy of every photo or video in a preferred format per account
  (`PUT /me/settings`: JPEG, HEIC, PNG, TIFF; MP4, MOV, MKV), next to the original. Videos only
  change their container (no quality lost); existing photos are converted in the background
  after a change, and switching back removes the copies.
- Server: sync (`GET /sync?since=N`): every change gives an asset the next number, a device asks
  for everything after the last number it saw; one index range per page, tombstones for deleted
  photos, and a reset signal for devices that are too far behind.
- Server: files by their hash (`GET /files/{sha256}`, cached forever) and by role, with Range
  for seeking in videos, ETag and `304`; up to 500 thumbnails in one streamed answer
  (`POST /thumbnails`).
- Server: corrections of time, time zone, place, title and description (`PATCH /assets/{id}`)
  that never touch the original values, with a history; one place for many photos at once.
- Server: photos without a place get one suggested from the nearest photo in time
  (`GET /assets/without-location`).
- Server: background job queue in the database with retries; workers run at the lowest priority.
  If the phone hasn't sent thumbnails after 10 minutes, the server makes them (JPEG, PNG, TIFF,
  WebP, GIF directly; HEIC with libheif; videos with ffmpeg).
- `halden status` shows waiting and failed background jobs.
- Server: resumable uploads (`POST /uploads`, `PATCH /uploads/{id}` with `Upload-Offset`). A
  broken connection or a killed server loses nothing; the next request continues where the
  bytes stopped. The last piece finishes the upload: SHA-256 check, flush to disk, atomic move
  into a readable folder (`<user>/<year>/<month>/<date>_<time>.<ext>`), one database
  transaction.
- Server: duplicates are recognised by content per account and stored once; retries with the
  same asset id never create a second photo.
- Server: capture time, time zone, camera and GPS are read from EXIF and QuickTime metadata
  when the phone doesn't send them.
- Server: thumbnails and previews go up in one request each and are stored by their hash on the
  fast disk; `POST /assets/check` answers for up to 1000 photos at once whether they are backed
  up.
- Server: free space is checked before an upload is accepted, counting uploads in progress and a
  reserve (`[storage] min_free_gb`). Unfinished uploads expire after 7 days.
- `halden status` shows the number of photos and videos, the library size and unfinished
  uploads.
- Load test (`cargo run --release --example loadtest`) against a library of 100,000 photos.
- Server: accounts with owner and member roles; the server always keeps one active owner.
- Server: sign-in with username and password (Argon2id) or by pairing with a QR code or a typed
  one-time code (5 minutes, single use). Each device gets its own token (`hd1_…`); only its hash
  is stored.
- Server: new devices that signed in with a password show up on the account's other devices
  ("That was me" / "Block"). Blocking signs a device out and refuses its installation.
- Server: brakes against guessing (20 attempts per minute per address, growing waits per
  username), password sign-in can be turned off, unused devices are signed out after 365 days.
- Server: security log of sign-ins, devices and account changes, kept 90 days.
- Commands `halden user add|list|passwd|role|remove`, `halden pair`, `halden devices [revoke]`
  and `halden log`; `halden setup` asks for the first owner account.
- Docs: `docs/PROTOCOL.md` and `docs/SECURITY_MODEL.md`.

### Changed

- Server: explicit limits for slow and idle clients: 10 s for the TLS handshake, 15 s for HTTP/1
  headers, at most 64 KiB of HTTP/2 headers per request (instead of 16 MiB).
- Server: `halden mirror set|off` keeps the comments in the config file and needs no restart.
- systemd: the server may write to `/etc/halden` (settings from the app) and to `/mnt` and
  `/media` (mirror disks); `systemctl reload halden` works.

- Server: the database uses one writing and several reading connections, with a larger cache
  and memory-mapped reads; signing a request in takes one indexed lookup.
- Server: HTTP/2 flow-control windows of 4 MiB per stream (instead of 64 KiB), keepalive pings,
  JSON answers compressed with gzip or brotli, small files read in one go, a cap on helper
  threads, and mimalloc as the memory allocator on Linux (memory stays flat under load).

### Fixed

- Server: a photo deleted for good could still be corrected (title, place, time), which put
  details back into its tombstone. Tombstones can't be changed any more. Found by the new model
  test.
- Server: a small picture claiming to be huge (a "decompression bomb", e.g. a PNG of
  50,000 × 50,000 pixels) made the thumbnail job reserve gigabytes before failing, which could
  take a server with little memory down. Pictures that would need more than 1 GiB decoded are
  now refused before anything is reserved.
- Security log: "1 device signed out" instead of "1 devices".
- Server: a crash at the wrong moment could leave files behind or out of step with the
  database. A file journal now notes every move into the library before it happens and every
  removal in the same transaction that deletes the record; the next start finishes what was
  interrupted. An upload cut off between moving and recording goes back to its partial file and
  can be finished; an unrecorded conversion is removed and made again; a photo deleted for good
  never stays behind on the library disk, the thumbnails or the mirror. Tested by making the
  real server die at exactly these moments (`HALDEN_FAILPOINT`, debug builds only).
- Server: an upload whose phone hung up (or whose server restarted) at the very moment it was
  being finished could leave the file in the library without a record. Finishing now always runs
  to the end on its own.

## 22.11.2026

### Added

- Server foundation: one `halden` program with `setup`, `status` and `serve`.
- TLS 1.3 only, with a self-signed certificate that apps pin by its fingerprint.
- Connections only from the home network and Tailscale unless opened up in the config.
- SQLite database with migrations, systemd unit with hardening, GitHub checks (format, lint,
  tests, release build).
