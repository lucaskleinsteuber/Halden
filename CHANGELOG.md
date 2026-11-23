# Changelog

Notable changes to Halden. Newest first. Dates are day.month.year.

There are no version numbers yet; entries are grouped by date until the first release.

## 23.11.2026

### Added

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

- Server: the database uses one writing and several reading connections, with a larger cache
  and memory-mapped reads; signing a request in takes one indexed lookup.
- Server: HTTP/2 flow-control windows of 4 MiB per stream (instead of 64 KiB), keepalive pings,
  JSON answers compressed with gzip or brotli, and mimalloc as the memory allocator.

## 22.11.2026

### Added

- Server foundation: one `halden` program with `setup`, `status` and `serve`.
- TLS 1.3 only, with a self-signed certificate that apps pin by its fingerprint.
- Connections only from the home network and Tailscale unless opened up in the config.
- SQLite database with migrations, systemd unit with hardening, GitHub checks (format, lint,
  tests, release build).
