# The iPhone app

Native Swift and SwiftUI, iOS 26 and newer. Right now it is the skeleton: connect to the
server, take a photo, watch it go up (also after a break), see it in the grid with a check mark.
Design, video, background uploads, the trash, Apple Photos and the Live Activity come next.

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
- **Taking a photo**: HEIC in the best quality, written to the app's folder before anything else,
  with place, accuracy and direction (also in the file's own metadata). The shutter never waits.
- **Uploads**: a queue in the database, oldest first, in pieces of 8 MiB. After the app was
  closed or the connection broke, it asks the server where it stands and goes on from there.
  Once the original is checked on the server, the phone sends its own thumbnail (512 px) and
  preview (2048 px).
- **The grid**: everything the phone took and everything synced from the server
  (`GET /sync`, only what changed), newest first. Thumbnails come from a cache on disk, from the
  local file, or 500 at a time from the server. A check mark means: safely on the server.

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
cd .. && xcodebuild test -project Halden.xcodeproj -scheme Halden \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO
```

The CI (`.github/workflows/ios.yml`) runs all of it on macOS and checks that the Xcode project
matches `project.yml`.
