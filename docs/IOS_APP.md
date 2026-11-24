# The iPhone app

Native Swift and SwiftUI, iOS 26 and newer. Being built up to the full first version (camera
with video, background uploads, library, trash, Apple Photos, settings and server management);
the design comes after that. What works today is described below.

## Layout

| Folder | What |
|---|---|
| `ios/HaldenKit` | Swift package with everything that isn't a screen: the API client with the pinned certificate, pairing, the local database (GRDB), uploads that survive restarts, sync, thumbnails. Builds for iOS and macOS, so its tests run on the Mac, and the Mac app can use it later. |
| `ios/App` | The app: screens, camera, QR scanner. |
| `ios/UITests` | The screens in the simulator. |
| `ios/project.yml` | Describes the Xcode project; `ios/generate.sh` (XcodeGen) makes `Halden.xcodeproj` from it. Both are committed. |

## How it works

- **Connecting**: scan the QR code from `sudo halden pair` (or paste its link). It carries the
  server's addresses, its certificate fingerprint and a one-time code. The app tries all
  addresses at once and takes the first that answers with exactly that certificate. Signing in
  with a password shows the fingerprint first, to compare with `halden status`; nothing secret
  is sent before. The device token goes to the Keychain (this device only).
- **Trust**: every connection trusts only the certificate whose SHA-256 was pinned (TLS 1.3).
- **The camera**: photo (HEIC in the best quality, or JPEG) and video (HEVC, 4K at 60 fps by
  default, HDR and 1080p/30 in the settings, with sound when the microphone is allowed). Ultra
  wide, main, 2× and tele as one virtual camera, so zooming switches lenses where Apple's camera
  does; zoom buttons and pinching; the front camera. Tap to focus, hold to lock focus and
  exposure, flash (auto/on/off) or the light for videos, self-timer (3 or 10 s), grid lines.
  Photos and videos come out upright however the phone is held. The camera is set up when the
  app starts, all on a queue of its own, so its picture is there at once and the screen never
  waits for it.
- **Time, place and direction**: every photo and video knows when it was taken (with the time
  zone), where (with the accuracy) and which way the camera pointed, sent to the server and
  written into the file itself (EXIF/GPS for photos, QuickTime metadata for videos, as Apple's
  camera does). A place older than a minute is left out; one less precise than the limit (50 m)
  is kept and shown as imprecise, or left out, as set.
- **Taking a photo or video**: written to the app's folder before anything else (away from the
  main thread), then into the library and the upload queue. The shutter never waits.
- **Simulator and UI tests**: the simulator has no camera; there, and in the UI tests, a
  stand-in camera behaves like the real one and delivers made-up photos and short videos.
- **Uploads**: a queue in the database, oldest first, in pieces of 8 MiB. After the app was
  closed or the connection broke, it asks the server where it stands and goes on from there.
  Once the original is checked on the server, the phone sends its own thumbnail (512 px) and
  preview (2048 px).
- **The grid**: everything the phone took and everything synced from the server
  (`GET /sync`, only what changed), newest first. A `UICollectionView` rather than a SwiftUI
  grid, so 50,000 photos scroll without a hitch: cells are reused, only changed cells are
  redrawn, and pictures are asked for before they scroll in. `ImagePipeline` decodes and scales
  each thumbnail to the cell's size off the main thread and keeps decoded pictures in memory
  (96 MB); thumbnails come from a cache on disk, from the local file, or from the server, where
  all cells asking within 15 ms go out as one request. A check mark means: safely on the
  server; a ring shows an upload going.
- **Changes on the phone** (`Actions`): trash, restore, delete for good, corrections and one
  place for many photos show at once and are kept in the `action` table until the server has
  them, in the order they were made. The sync leaves photos with waiting changes alone. A
  change for a photo still uploading waits for it. Errors that may pass (server busy, no
  connection) are tried again later, up to 10 times; a change the server refuses for good is
  dropped and the photo shown as the server has it.
- **Settings** (`AppSettings`): saved on the phone; values from an older version or options
  that went away fall back to their default.

## On your iPhone

Once: connect the iPhone by cable, trust the Mac, turn on Developer Mode (Settings › Privacy &
Security), and put your team into `ios/Config/Local.xcconfig` (`DEVELOPMENT_TEAM = …`). Then:

```sh
ios/install-on-iphone.sh
```

With a free developer account the app runs for 7 days; then install it again the same way.

## Tests

```sh
cd server && cargo build                 # the end-to-end tests start the real server
cd ../ios/HaldenKit && swift test        # unit tests and the whole chain against the server
cd .. && ./ui-tests.sh                   # the app in the simulator, against a real server
```

`ui-tests.sh` sets up a server in a temporary folder, starts it on the Mac (the simulator
reaches it on 127.0.0.1) and stops it afterwards; extra arguments go to `xcodebuild`, e.g.
`-only-testing:HaldenUITests/HaldenUITests/testTheGridScrollsThroughFiftyThousandPhotos`.
Started with `-ui-testing-library 50000`, the app fills its database with that many photos
instead of connecting.

The CI (`.github/workflows/ios.yml`) runs all of it on macOS and checks that the Xcode project
matches `project.yml`.
