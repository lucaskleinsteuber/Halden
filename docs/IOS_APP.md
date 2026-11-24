# The iPhone app

Native Swift and SwiftUI, iOS 26 and newer. Being built up to the full first version (camera
with video, background uploads, library, trash, Apple Photos, settings and server management);
the design comes after that. What works today is described below.

## Layout

| Folder | What |
|---|---|
| `ios/HaldenKit` | Swift package with everything that isn't a screen: the API client with the pinned certificate, pairing, the local database (GRDB), uploads that survive restarts, sync, thumbnails. Builds for iOS and macOS, so its tests run on the Mac, and the Mac app can use it later. |
| `ios/App` | The app: screens, camera, QR scanner. `App/Camera` is shared with the lock-screen camera. |
| `ios/Shared` | What the app and its extensions share: the Live Activity's data and the camera intent. |
| `ios/Widgets` | Widget extension: the Live Activity for uploads and the camera control. |
| `ios/LockedCamera` | The camera on a locked iPhone (LockedCameraCapture extension). |
| `ios/UITests` | The screens in the simulator. |
| `ios/project.yml` | Describes the Xcode project; `ios/generate.sh` (XcodeGen) makes `Halden.xcodeproj` from it. Both are committed. |

## How it works

- **Finding the server**: in the home network the app lists Halden servers announcing
  themselves with Bonjour (`_halden._tcp`); choosing one fills in its address for signing in.
  Finding is not trusting: the fingerprint is still shown to compare.
- **Connecting**: scan the QR code from `sudo halden pair` (or paste its link). It carries the
  server's addresses, its certificate fingerprint and a one-time code. The app tries all
  addresses at once and takes the first that answers with exactly that certificate. Signing in
  with a password shows the fingerprint first, to compare with `halden status`; nothing secret
  is sent before. The device token goes to the Keychain (this device only).
- **Trust**: every connection trusts only the certificate whose SHA-256 was pinned (TLS 1.3).
- **The camera**: photo (HEIC in the best quality, or JPEG) and video (HEVC, 4K at 60 fps by
  default, HDR and 1080p/30 in the settings or right on the camera screen, with sound when the
  microphone is allowed). Ultra wide, main, 2× and tele as one virtual camera, so zooming
  switches lenses where Apple's camera does; the front camera. Tap to focus, hold to lock focus
  and exposure, flash (auto/on/off) or the light for videos, self-timer (3 or 10 s), grid lines.
  Photos and videos come out upright however the phone is held. The camera is set up when the
  app starts, all on a queue of its own, so its picture is there at once and the screen never
  waits for it.
- **Camera screen**: laid out like Apple's camera. On top flash (or the light), self-timer,
  grid and Live Photo, for videos the format in the middle. The picture as it will be taken: 4:3
  under the top bar for photos, 16:9 for videos. Below the zoom buttons, the modes (also changed
  by swiping over the picture) and the shutter between the last photo (opens it) and the button
  that turns the camera around. Nothing moves when the mode changes.
- **Zoom** (`Zoom`): in doublings, as people know it. A lens button glides there in 0.3 s
  however far it is (`ramp(toVideoZoomFactor:withRate:)`), pinching and the dial follow the
  finger with a quick ramp, so steps between touches don't show. The number shown is the
  camera's real zoom as it changes (observed on the device), never the target. Dragging the
  zoom buttons sideways turns them into a dial with a mark at every lens; a light tick when a
  lens is passed.
- **Live Photos** (on by default, like Apple's camera; the button on top or Settings ›
  Camera): the photo and 1.5 s of video with sound before and after, taken together by
  `AVCapturePhotoOutput` with the same content identifier, the video with place and time. The
  photo is the asset's original, the video its `paired_video`, sent after the photo; the
  uploads count them as one. Full screen shows "LIVE" and plays it while held
  (`PHLivePhotoView`, the video fetched from the server when it isn't on this iPhone). Saved to
  Apple Photos as a Live Photo; shared with both files. The lock-screen camera takes them too.
- **Manual settings** (the slider button on top): ISO in thirds of a stop, shutter speed in the
  usual steps, white balance (kelvin and tint), focus and exposure compensation (`ManualSettings`,
  `ManualLimits`). Each value shows what the camera does now (white when automatic, yellow when
  set) and can be given back with "Auto"; set by hand, it stays while tapping to focus and when
  changing lenses or modes. What can be set comes from the camera in use (in video modes the
  shutter can't be open longer than a frame). While the focus is turned, the picture is shown
  bigger. Closing the camera brings back automatic, unless Settings › Camera › Keep manual
  values is on.
- **Slow motion** (Slo-mo): 1080p at 240 fps (or 120, in the settings or on the camera
  screen), with sound, on the camera that can record that fast. The file stays as recorded;
  played, a part of it is slow (`Retiming.slowMotion`, the sound slowing down with it): by
  default from a seventh in to a seventh before the end at 30 frames a second (1/8 at 240 fps).
  Where and how slow can be changed (the slow-motion button in the full-screen view); the
  server keeps it as the asset's `playback`, a correction with its history, and every device
  gets it with the sync. Shared as recorded or as played (written anew).
- **Time-lapse**: the camera's frames, of which `TimeLapseRecorder` keeps a few and writes them
  at 30 frames a second (HEVC, with place and time). Automatic like Apple's camera: two
  pictures a second at first, half as many whenever the video would get longer than 40 s, and
  when it stops, the earlier stretches are sped up to the pace of the last one, so the video is
  20 to 40 s and runs at one speed (`TimeLapsePlan`, `Retiming.timeLapse`). A fixed interval
  (0.5 to 10 s) can be set instead.
- Slow-motion videos and time-lapses are marked in the grid and full screen, and the server
  knows them by their `captureMode`.
- **Time, place and direction**: every photo and video knows when it was taken (with the time
  zone), where (with the accuracy) and which way the camera pointed, sent to the server and
  written into the file itself (EXIF/GPS for photos, QuickTime metadata for videos, as Apple's
  camera does). A place older than a minute is left out; one less precise than the limit (50 m)
  is kept and shown as imprecise, or left out, as set.
- **Taking a photo or video**: written to the app's folder before anything else (away from the
  main thread), then into the library and the upload queue. The shutter never waits.
- **Simulator and UI tests**: the simulator has no camera; there, and in the UI tests, a
  stand-in camera behaves like the real one and delivers made-up photos and short videos.
- **Albums** (Photos › Albums): made, renamed, sorted, given a cover and deleted (the photos
  stay); photos go in from the library ("Add to album" for the chosen ones or one full screen)
  and come out in the album. All of it shows at once and reaches the server when it can (an
  album change waits for photos still uploading), and every device gets it with the sync.
  Photos in the trash aren't shown in albums and are back when restored.
- **Editing** (the slider button full screen; `EditRecipe`, `EditRenderer`): light (exposure,
  brightness, contrast, highlights, shadows), colour (saturation, vibrance, warmth, tint), and
  for photos turning, straightening and cropping (free or in a shape), for videos trimming.
  "Auto" suggests light and colour from the picture. The picture follows every slider at once
  (Core Image on the GPU). Only what was set is kept, as the asset's `edit` (a correction with
  its history on the server); the original stays, and "Original" goes back to it. Every device
  applies the edit itself when it shows the photo (grid, full screen, zoomed in) or plays the
  video (`AVVideoComposition`), so nothing has to be uploaded again and nothing can get out of
  step. Shared "as edited", written anew in full size with the original's metadata.
- **Map** (Photos › Map): every photo with a place, grouped (`MapClusters`): the visible part
  of the map on a grid fixed to the earth, in steps of two, so groups don't jump while the map
  moves and split in four when zooming in; each group shows its newest photo and how many there
  are, estimated places with a dashed frame. Grouped again away from the main thread when the
  map stops; only pins that changed are replaced. A tap shows the group's photos; photos without
  a place are a tap away.
- **Trips** (`Trips`, `TripFinder`): home is where most days have photos; a run of days with
  photos farther away (50 km, in Settings › Place; a day or two without photos still belongs to
  it, at least six photos) is a trip, named after the town where most of them were taken (from
  Apple Maps, asked once per place) and the months: "Rome, May 2026". Found on the iPhone, never
  sent anywhere; "Keep" makes it an album.
- **Uploads**: a queue in the database, oldest first, in pieces of 8 MiB. After the app was
  closed or the connection broke, it asks the server where it stands and goes on from there.
  Once the original is checked on the server, the phone sends its own thumbnail (512 px) and
  preview (2048 px), for videos made from a frame.
- **Network rules** (Settings › Uploads): over cellular yes or no, videos only on Wi-Fi (also
  waiting on another phone's hotspot and in Low Data Mode), only on the home Wi-Fi (the server
  answers at its home address, not over Tailscale; no permission for Wi-Fi names needed).
  Photos behind a waiting video still go.
- **In the background**: when Halden leaves the screen, the rest of every upload that may go is
  handed to a background `URLSession`, one request from the current offset to the end (from the
  file itself, or from a copy of its rest). The system sends it while Halden is suspended or
  closed, keeps the network rules, checks the pinned certificate through the app, and wakes the
  app when it is done; the thumbnails follow when Halden next runs. A `BGProcessingTask` gives
  more time for hashing and uploading.
- **Settings**: on top the server and whether everything is on it (a tap shows the uploads),
  then one page per topic: server and account, uploads, camera, place, Apple Photos, storage on
  this iPhone, formats, trash, and for owners the server. Every setting says in a line what it
  does.
- **Uploads screen** (Settings, the server at the top): every upload not finished yet with its
  progress and error, "Try again", why uploads wait right now, and "12 of 40" for the current
  round.
- **Live Activity**: "12 of 40 uploaded" on the Lock Screen and in the Dynamic Island, for
  rounds of five or more (or 50 MB), and whenever uploads still wait when Halden leaves the
  screen; it ends a minute after the last one.
- **Copies on this iPhone**: kept by default. With "Keep copies on this iPhone" off, an
  original leaves the phone once the server has it (checked by its hash) and its thumbnail and
  preview are here.
- **Apple Photos** (`PhotosSync`, Settings › Apple Photos):
  - New photos and videos there (Apple's camera, screenshots, other apps) come into Halden and
    are backed up, found through the library's persistent change history, so also what was
    added while Halden wasn't running. Live Photos come with their video (uploaded after the
    photo as the asset's `paired_video`). Time and place come from Apple Photos.
  - Deleted there: into Halden's trash, restorable. Deleted everywhere in Halden: deleted there
    too, after the system asks.
  - Photos taken with Halden are saved there too and linked, so they never come back as new.
  - The photos from before Halden come in on request, 50 at a time, going on where it stopped.
  - Importing needs access to all photos (or the ones chosen); saving needs only adding. All
    three directions can be turned off.
- **The account** (Settings › Account): the devices signed in (new ones to confirm with "That
  was me" or block, others to sign out), adding a device with a pairing code shown as QR code,
  the security log, the password, and the preferred formats (`/me/settings`).
- **Looking after the server** (owners, Settings › Look after the server): status with disks,
  numbers per account, jobs and memory; the doctor; every setting `halden config` knows except
  folders, port and certificate (saved together, the server restarts with them; settings that
  open the server up ask for the password again); accounts (add, disable, delete, pairing codes
  for them); the mirror; database backups; failed jobs; updates (in Docker: the command to run
  instead); restart.
- **Lock Screen and Control Center**: a control ("Halden Camera") for Control Center, the Lock
  Screen and the Action button opens Halden's camera, also on a locked iPhone. There it runs as
  an extension that may only keep what it takes in a folder the system gives it; Halden takes it
  over and uploads it the next time it runs. Whether a free developer account may sign the
  extensions is tried on the iPhone.
- **The grid**: everything the phone took and everything synced from the server
  (`GET /sync`, only what changed), newest first. A `UICollectionView` rather than a SwiftUI
  grid, so 50,000 photos scroll without a hitch: cells are reused, only changed cells are
  redrawn, and pictures are asked for before they scroll in. `ImagePipeline` decodes and scales
  each thumbnail to the cell's size off the main thread and keeps decoded pictures in memory
  (96 MB); thumbnails come from a cache on disk, from the local file, or from the server, where
  all cells asking within 15 ms go out as one request. A check mark means: safely on the
  server; a ring shows an upload going.
- **Full screen**: swipe between photos, pinch or double-tap to zoom. The thumbnail is there at
  once, the preview (2048 px) fades in over it at the same size, the original follows when
  zoomed in; what isn't on the iPhone comes from the server once and stays in the cache by its
  hash. Videos play from the iPhone, or stream from the server in ranges through the pinned
  connection (`StreamLoader`; the system's player can't check Halden's certificate itself).
- **Info**: three layers. As shown (with corrections: time and time zone, place on a map with
  its accuracy circle and direction, title, description), as taken (the original time and place
  and where they came from, camera, lens, EXIF), and on the server (backed up, checksum, every
  file kept with its type and size, the copy in the preferred format).
- **Corrections**: time, time zone, title, description and place (tapped on a map), or back to
  the time and place as taken. They show at once and reach the server through `Actions`, also
  later; the server keeps the original values and every correction.
- **Without place** (Photos › … › Without place): photos without a place, from this iPhone's
  library (also offline); choose some, then give them the place of the photo taken nearest in
  time (the server's suggestion, marked as estimated) or a place tapped on the map.
- **Deleting**: two different things, named apart. "Delete everywhere" moves photos to the
  server's trash, on every device, restorable for the days the owner set (`trashDays` from
  `/me`). "Remove from this iPhone" only frees space: for photos safely on the server, which
  stay in the library. Many at once with Select in the grid. Offline both wait in `Actions`.
- **Trash** (Photos › … › Trash): what was deleted, with the days left; restore, or delete for
  good after a question (one, chosen ones or all).
- **Sharing**: the original, a copy with the corrected time, place, title and description
  written into the file (EXIF/GPS/IPTC for photos, QuickTime metadata for videos, the picture
  copied without encoding it again), or the copy in the account's preferred format.
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

Measurements (launch, the camera's start, memory and processor while scrolling through 50,000
photos) run only on purpose:

```sh
TEST_RUNNER_HALDEN_MEASURE=1 ios/ui-tests.sh -only-testing:HaldenUITests/PerformanceTests
```

The CI (`.github/workflows/ios.yml`) runs all of it on macOS and checks that the Xcode project
matches `project.yml`.
