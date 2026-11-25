# Changelog

Notable changes to Halden. Newest first. Dates are day.month.year.

The server and the iPhone app have version numbers of their own (semantic versioning), both
from 0.1.0 on 25.11.2026; a heading names the versions released that day. Everything before is
part of the first versions.

## 25.11.2026

### Added

- Composition and video recording locks: CoreMotion horizon and overhead/flat-lay crosshair
  level (`LevelOverlay`, `Composition`), 24 / 28 / 35 mm focal-length cycling when tapping the
  active 1× lens button, front-camera mirroring, geometric lens distortion correction,
  dismissible smudged-lens warning banner (where supported), and options under Settings › Camera
  › Record Video to lock the active lens and white balance while filming.
- In-camera iOS 26 control drawer (`CameraDrawer`, opened by the top-bar chevron or swiping up
  over the modes) with photo controls (flash, Live Photo, EV −2…+2 slider, aspect ratio
  4:3/16:9/1:1, timer off/3/5/10 s, 12/24/48 MP resolution, Bayer RAW DNG) and video controls
  (1080p/4K, 24/25 PAL/30/60 fps, HDR, auto low-light FPS), plus customizable top-bar controls.
- Non-destructive camera aspect ratios (16:9 and 1:1 stored as `EditRecipe.crop`, keeping the
  full original in Halden while saving the cropped copy to Apple Photos).
- Restructured Settings › Camera like Apple's (Preserve Settings, Top Bar Controls, Formats,
  Record Video with PAL and audio playback while filming, faster shooting prioritization,
  default focal length, Volume Up for burst, and Composition).
- Screenshots and screen recordings without GPS get an estimated place in Halden only (Apple
  Photos stays unchanged): this iPhone's current place (new server location source `device`)
  when taken within 30 minutes while Halden is open, otherwise the place of the nearest photo
  within two hours (`estimated`); existing unlocated screenshots get a one-time pass on sync.
  Full screen and Info show "Where your iPhone was" or "From a photo nearby", the map marks
  them as estimated, and Settings › Place lets you configure whether screenshots and screen
  recordings get a place and the maximum age.

### Fixed

- The tab bar (Camera, Photos, Settings) is visible in the camera again, with clear space above
  it so the shutter row never crowds or overlaps it.

## 25.11.2026 – App 0.1.0

### Added

- Layout tests (`ios/UITests/LayoutTests.swift`, `ios/layout-tests.sh`): every screen is checked
  for something cut off by the edge of the screen, controls on top of each other, buttons
  smaller than 44×44 points and buttons or texts that can't be seen (too little contrast, such
  as white on white), on the smallest and the biggest iPhone and with big text, keeping a
  screenshot of each screen.

### Changed

- The camera uses the whole screen, without the tab bar, like Apple's camera. The last photo
  opens full screen with "All Photos" to the library, which has the tab bar back to the camera
  and the settings.
- Zoom: the lens buttons show the zoom asked for at once (a tap on "2" says "2×" while the
  picture glides) and one highlight glides to the chosen lens; the highest zoom is a round
  number. The lens buttons lie on the picture's lower edge again.
- Changing between photo and video blurs the picture for a moment while the camera changes its
  format, and the frame glides into its new shape.
- Library, Albums and Map are switched with a switcher floating above the tab bar, as in
  Apple's Photos.

### Fixed

- Zoom counted up on the old lens button and then jumped, and ended at 9.9 instead of 10.
- The last photo beside the shutter stayed black until the library had its thumbnail; it now
  shows the photo just taken at once.
- In the library, the Library/Albums/Map switcher was cut off at the left edge and lay under
  "Select".
- In slow motion, the video format on top lay over the self-timer button.
- The full-screen photo opened from the camera had invisible (white on white) buttons.
- Small buttons in the camera (modes, manual values, video format) are now big enough to hit.

## 25.11.2026 – Server 0.1.0

### Added

- Version numbers: the server and the iPhone app count on their own, both from 0.1.0. Server
  0.1.0 is the first release: signed with the owner's key (now built into the program and
  `get-halden.sh`) and, like every 0.x version, a pre-release on GitHub.
- Test versions made visible: with them off, `halden update`, `halden status` and the app's
  Update page say when a newer test version is waiting and how to get it
  (`sudo halden update --beta on`); the app has a switch "Install test versions" for it
  (`GET /admin/update` now carries `beta` and `testVersion`).
- `get-halden.sh --beta` installs the newest test version (`… | sudo bash -s -- --beta`); without
  it, it says when there are only test versions.
- iPhone app icon: six curved aperture blades in the colours of a photo library around an open
  hexagon, as layers in Icon Composer's format (`ios/App/AppIcon.icon`), so iOS adds the Liquid
  Glass edges and the dark, tinted and clear looks itself; made by `ios/Icon/make_icon.py`.
- Shared links: photos or an album as a web page for people without Halden, with an end, a
  password and originals only if allowed; made, listed and withdrawn on the iPhone. The server
  serves the page on a listener of its own that knows nothing else (`[share] enabled`, `listen`,
  `public_url`), for Tailscale Funnel, a Cloudflare Tunnel or Caddy (`docs/SHARING.md`).
- Server: `halden import takeout` (Google Photos from Google Takeout, ZIP files or folders, all
  parts at once) and `halden import immich` (an Immich account by API key). The import goes
  through the running server as a device of its own, so duplicates stay single; what Google or
  Immich knew comes along where the file doesn't say (time, place, description), albums and
  favourites become albums, Live Photos keep their video, Google's edited copies are left out.
  Resumable (a journal in the data folder), `--dry-run` to count.
- Small copies of big videos to play on the go: made on the iPhone (720p H.264) and sent as the
  asset's `stream` (a new upload role), or made by the server with ffmpeg when the phone
  hasn't (`[jobs] stream_versions`, `stream_height`, `stream_kbps`); the app plays them on
  cellular and away from home.

### Changed

- Releases: the release workflow and `scripts/publish-release.sh` publish every 0.x version (and
  every test version) as a pre-release; the Docker image is tagged `latest` only for stable
  releases. `publish-release.sh` takes the signing key's password from the Mac's Keychain.
- The app shows its build number next to its version (Settings).
- iPhone: less memory with a big library (172 instead of 207 MB peak while scrolling through
  50,000 photos in the simulator): an edit recipe costs a pointer per photo until a photo has
  one, and trips are looked for only while the albums are shown.
- iPhone: a new album for chosen photos is named right in the album list (no extra question on
  top, which didn't always close); the buttons for chosen photos are icons, so all four fit.

### Fixed

- Server: the list of allowed file roles is made anew (migration 11), so new roles can be
  stored.
- UI tests in the CI: the camera no longer asks for the place in UI-test mode, and system
  questions are answered only while they are there.

## 24.11.2026

### Added

- iPhone editing without touching the original: light, colour, turning, straightening,
  cropping (photos) and trimming (videos), with Auto and a live picture; kept as what was set
  (the asset's `edit` on the server, with its history) and applied by every device when it shows
  or plays it; shared as edited in full size.
- iPhone map with all photos (Photos › Map): groups with their newest photo and count, steady
  while the map moves, estimated places marked, a tap shows the photos; the photos without a
  place a tap away. Measured with 50,000 photos (`PerformanceTests`).
- Albums: on the server (`/albums`, in the sync with the assets) and on the iPhone, with names,
  covers, order, adding and taking out photos, also offline; photos in the trash stay in their
  albums, deleted for good they leave them.
- iPhone trip albums: trips found in the photos (days far from home), named after the town and
  the months, kept as an album with one tap.
- iPhone manual camera settings: ISO, shutter speed, white balance (kelvin and tint), focus and
  exposure compensation, each automatic or set within what the camera can do, with the current
  value always shown and a bigger picture while focusing; back to automatic when the camera
  closes unless they are to be kept.
- iPhone slow motion: 1080p at 240 or 120 fps with sound; the original stays as recorded and a
  slow part (by default most of it, at 30 frames a second) is set next to it, changeable in the
  full-screen view, kept on the server as the asset's `playback` and synced to every device;
  shared as recorded or as played.
- iPhone time-lapse: automatic like Apple's camera (the video stays 20 to 40 seconds however
  long it runs, at one speed) or with a fixed interval.
- Server: the asset's `captureMode` (`slowmo`, `timelapse`, from the upload's metadata) and
  `playback` (the slow part of a slow-motion video, a correction with its history).
- iPhone Live Photos, on by default like Apple's camera (button on the camera, Settings ›
  Camera): photo and short video with sound, uploaded as the asset's `original` and
  `paired_video` and counted as one, played full screen while held, marked in the grid, saved to
  Apple Photos as a Live Photo, shared with both files, also from the lock-screen camera.
- iPhone zoom dial: dragging the zoom buttons sideways zooms continuously, with a mark at every
  lens and a light tick when one is passed.
- iPhone camera: the video format (size, frame rate, HDR) can be changed on the camera screen;
  swiping over the picture changes the mode; the last photo is next to the shutter and opens
  full screen.
- iPhone measurements on request (`PerformanceTests`): launch, the camera's start, memory and
  processor while scrolling through 50,000 photos. In the simulator: responsive after 1.9 s,
  146 MB at most while scrolling fast.
- iPhone settings for the account and the server: devices (confirm, block, sign out), adding a
  device with a pairing QR code, the security log, the password and the preferred formats; for
  owners the whole server: status, doctor, settings (with the password where needed; the server
  restarts with them), accounts, mirror, database backups, failed jobs, updates and restart.
  The app finds servers in the home network by Bonjour.
- iPhone and Apple Photos: new photos and videos there come into Halden and are backed up (Live
  Photos with their video, as the server's `paired_video`), also what was added while Halden
  wasn't running; deleted there they go to Halden's trash; photos taken with Halden are saved
  there too and never come back as new; deleting everywhere in Halden deletes them there after
  the system asks; the photos from before Halden can be imported, in pieces that go on where
  they stopped.
- iPhone deleting and trash: "Delete everywhere" (into the server's trash on every device) and
  "Remove from this iPhone" (only for photos safely on the server) as two separate actions, for
  one photo or many chosen in the grid; the trash with the days left, restoring, and deleting
  for good after a question; all of it also offline.
- Server: `GET /me` tells the apps `trashDays`, so they can show how long photos stay in the
  trash.
- iPhone library: full screen with swiping and zooming (thumbnail, then preview, then the
  original, without jumps), videos played from the phone or streamed from the server through
  the pinned connection; info in three layers (as shown, as taken with EXIF, on the server) with
  a map showing accuracy and direction; corrections of time, time zone, title, description and
  place, or back to the original; "Without place" with the server's suggestions or a place from
  the map for many photos at once; sharing the original, a copy with the corrections written
  into the file, or the copy in the preferred format.
- iPhone uploads: the network rules (over cellular or not, videos only on Wi-Fi, only on the
  home Wi-Fi); uploads go on in the background, handed to the system as one request for the
  rest of each file, also while Halden is closed; a screen with every waiting upload, its
  progress, error and "Try again"; "12 of 40 uploaded" as a Live Activity on the Lock Screen and
  in the Dynamic Island; copies on the iPhone removed once safely on the server, when so set.
- iPhone camera on the Lock Screen and in Control Center: a "Halden Camera" control opens the
  camera, also on a locked iPhone; what is taken there is taken over by the app the next time
  it runs.
- iPhone camera: photos and videos (HEVC, 4K at 60 fps by default, HDR optional, with sound);
  ultra wide, main, 2× and tele lenses with zoom buttons and pinching, and the front camera; tap
  to focus, hold to lock focus and exposure, flash or light, self-timer, grid lines; upright
  however the phone is held; ready the moment its screen opens. Videos carry time, place,
  accuracy and direction in their own metadata like photos do, and get their thumbnail and
  preview from the phone. A place less precise than the limit is kept and marked or left out,
  as set. In the simulator and the UI tests a stand-in camera delivers made-up photos and videos,
  so a UI test follows a photo, a self-timer photo and a video from the shutter to the server.
- iPhone app foundations for the full app: the grid is now a collection view that stays smooth
  with 50,000 photos (pictures decoded and scaled off the main thread, kept in memory, fetched
  in bulk and ahead of scrolling); changes made on the phone (trash, restore, delete for good,
  corrections, one place for many photos) show at once and reach the server in order once it
  can be reached, also after days offline; all app settings with their defaults; the local
  database learns video length, description, place, origin and links to Apple Photos.
- UI tests against the real server (`ios/ui-tests.sh` starts one on the Mac): signing in with a
  password after comparing the fingerprint, and scrolling through 50,000 photos.
- `halden doctor`, run as root, checks that the server's own user can get through every folder
  on the way to its data and library and write there, and names the folder that stops it.
- Tests for things happening at the same time (the same photo from two phones at once; trash,
  restore and delete-for-good from three devices at once), for the life of an upload (announced
  again, replaced, given up, finished early, expired, partial files left by a crash), and a
  4.3 GB file sent whole with offsets and ranges past 4 GiB (nightly, or `HALDEN_BIG_FILE=1`).
- Tests for what mutation testing (`cargo mutants`) showed no test would notice: devices signed
  out after a year unused, "last seen" written at most once a minute, device names and
  installation ids at sign-in, who hears about new devices, who may make pairing codes for
  whom and for how long they hold, the network rule at the door, the rate limiter staying small
  under thousands of addresses and remembering failures for a day, the longest allowed
  password, the trash and tombstone deadlines to the day, the file journal finishing its
  work, a Live Photo's video next to its photo, the limits of the metadata a phone sends, bytes
  sent past the announced end, finished uploads forgotten after 30 days, and the EXIF data kept
  for the detail view.

### Changed

- iPhone zoom glides: a lens button takes 0.3 s for any distance, pinching follows the finger
  smoothly, and the zoom shown is the camera's real one as it changes instead of jumping to the
  target (it also no longer jumps back after focusing).
- iPhone camera screen laid out like Apple's: the picture as it will be taken (4:3 for photos,
  16:9 for videos), fixed places for every control so nothing moves when the mode changes, the
  modes as a strip.
- iPhone settings in pages (server and account, uploads, camera, place, Apple Photos, storage,
  formats, trash, server), with the server and the upload status on top and a line explaining
  every setting.

- Server: the system allocator on Linux too. Measured on Linux with 100,000 photos: 26 MB at
  rest and 114–120 MB under load, against 54 MB and 184–226 MB with mimalloc. mimalloc stays
  available as `--features mimalloc` to compare.
- Server on Linux: the systemd service and the Docker image set `MALLOC_ARENA_MAX=2`. Under load
  the server then needs 33 MB instead of 140–147 MB, at the same speed.

### Fixed

- Tests: the iPhone UI test for importing from Apple Photos found nothing to import in the CI's
  fresh simulator; `ios/ui-tests.sh` now adds a photo there, and the test answers the system's
  question for the photos should it come.
- Server: on a computer that also runs Docker (or Podman, virtual machines, containers), the
  address of their internal network (like `172.17.0.1`) was handed out in pairing QR codes and
  shown by `halden status`, and took one of the four places for addresses in the QR code; IPv6
  link-local addresses (`fe80::…`), which a phone can't use from a link, too. Both are left out
  now. Found when installing on a server with Docker.
- Server: a correction could set a photo's time to any year (the year 5000 was taken). Times
  outside 1900 to 2200 are refused, as they are for uploads. Found by the app's tests.
- Server: `halden setup` made missing parent folders (like `/srv/halden` for the default library
  `/srv/halden/library`) with the library's restrictive permissions and owned by root, so the
  server's user could not get to its library: under systemd every upload and the daily database
  backup failed. Missing parents are now made 0755. Found by the new system test on Linux.
- Server: a library the server can't get into (gone, or no permission) was reported to the apps
  as a full disk (`insufficient_storage`). It is now a server error, and the log names the
  folder and the reason.
- Server: a photo restored on one device at the moment another device deleted it for good (or
  the trash emptied itself) was deleted anyway, although the first device had been told it was
  back. Deleting now checks inside its own transaction that the photo is still in the trash.
- Server: the same photo sent from two devices at once (both announced before either had
  finished) was stored twice. The second one now ends as `duplicate` with the first one's id,
  as it would have when announced later; the iPhone app understands that answer at every step
  of an upload.
- Tests: the HEIC tests accept `heif-convert` where `heif-dec` is missing (Ubuntu 24.04).
- Tests: the system test checked the update status before the updater had written
  "installed" (it notes that once it has seen the new version answer).
- Tests: servers started as their own process are stopped like systemd does (SIGTERM first), so
  coverage builds count what they ran; the nightly "long" job runs a debug build again (the
  failpoint and updater tests need it).

## 23.11.2026

### Added

- iPhone app skeleton (`ios/`, Swift 6 and SwiftUI, iOS 26): connect by scanning the QR code
  from `halden pair` (or with username and password after comparing the certificate
  fingerprint), the token in the Keychain; camera (back main camera, HEIC in the best quality,
  place with accuracy and direction, also written into the file); every photo saved on the
  phone first and uploaded in 8 MiB pieces from a queue that survives app restarts and
  continues where the server stands; thumbnail and preview made on the phone; the grid with a
  check mark once a photo is on the server; settings with the server, the "only one copy"
  warning and signing out. No design yet.
- `HaldenKit` (Swift package for iOS and macOS): API client trusting only the pinned
  certificate, pairing, local database (GRDB), uploader, sync, thumbnails. Its tests run the
  whole chain against the real Rust server: sign in and pair, an upload cut off and continued,
  sync to a second device, bulk thumbnails, the trash, signing out, duplicates.
- CI for iOS (`ios.yml`): HaldenKit tests against the server, the app build and UI tests in the
  simulator, and a check that the Xcode project matches `project.yml`.
- `ios/install-on-iphone.sh` builds the app and installs it on a connected iPhone.
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
- Nightly CI (`server-intensive.yml`): the whole server on a fresh Ubuntu under systemd
  (install with `get-halden.sh` from signed stand-in releases, real HEIC photos and HEVC videos
  in the sandbox, a mirror, an update from the app, a rollback from a broken version, a backup
  restore); disks that fill up, turn read-only or fail in the middle of a copy; every test with
  ten times the random cases; the load test with both allocators and a 15-minute soak; fuzzing
  of every parser; `cargo audit`. `docs/TESTING.md` describes all of it.
- Load test: `SOAK_MINUTES` keeps it running and watches memory, open files and speed;
  `HALDEN_BINARY` compares builds; `--features mimalloc` builds with mimalloc.
- Fuzzing (`server/fuzz`, cargo-fuzz): range headers, path templates, EXIF and QuickTime
  metadata, picture decoding, the updater's release list and signatures, config files and
  changes, pairing codes.

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

- Updates: after rolling back a version that didn't start, systemd's start limit is reset, so
  the old version always comes back up.
- Server: under heavy load, starting again with changed settings could fail for a moment and
  fall back to the old settings (the previous server still held the data folder and the
  database). Stopping now waits for every background task and closes the database, a restart
  waits briefly for the data folder, and a failed start is tried again instead of ending the
  process. Found by running the settings tests 30 times under full load.
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
