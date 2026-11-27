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
| `ios/Icon` | `make_icon.py` makes the app icon (`App/AppIcon.icon`, Icon Composer's layered format) and a flat `preview.svg`. |
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
- **Camera screen**: laid out like Apple's camera. Instead of the system tab bar (83 points) the
  camera has its own slim one (`CameraTabBar`: three symbols, 44 points, fades out while
  recording), which leaves room between the modes, the shutter and the bar. On top up to four
  customizable controls (default: flash/light, manual controls, self-timer 3/5/10 s, Live Photo),
  with the chevron for the control drawer always in the middle; for videos the format sits just
  below the top bar. The drawer (also opened by swiping up over the modes) takes the modes' place
  while open, and the details of a control (a slider, the styles, the filters) lie over the
  picture above the lens buttons, so nothing jumps. It offers only what this iPhone can do and
  nothing that is in the top bar already: Night, style, filter, EV (−2…+2), aspect ratio
  (4:3, 16:9, 1:1), timer, photo resolution (only the sizes the camera really has) and Bayer RAW
  (12 MP on the 1× lens, without Live Photo) in photo mode, and Action (where a format supports
  it), 1080p/4K, 24/25 (PAL)/30/60 fps, HDR and auto low-light FPS in video mode. Hints (night,
  depth, AE/AF lock, a smudged lens) share one line under the top bar and appear after half a
  second, so a value near a threshold doesn't make them blink. Non-4:3 aspect ratios are stored non-destructively
  as `EditRecipe.crop` so Halden keeps the full original while Apple Photos receives the cropped
  copy. Settings › Camera mirrors Apple's layout (Preserve Settings, Top Bar Controls, Formats,
  Record Video, Shooting including faster capture prioritization, audio playback while filming,
  default focal length and Volume Up for burst, and Composition). The picture as it will be
  taken: 4:3 or 1:1 under the top bar, 16:9 full-height for 16:9 photos and videos. The modes
  start where the 4:3 picture ends when space allows, so the zoom buttons lie on its lower edge;
  below them the modes (also changed by swiping over the picture) and the shutter between the
  last photo and the button that turns the camera around. Nothing moves when the mode changes:
  the picture blurs for a moment (`SwitchBlur`) while the camera changes its format and the
  frame glides into its new shape. Every control is at least 44×44 points.
- **Last photo**: the photo just taken shows at once (from the capture itself), otherwise the
  newest one in the library (its thumbnail, or its own file when the thumbnail isn't made yet).
  A tap opens it full screen, with "All Photos" leading on to the library; with no photos yet
  it opens the library at once.
- **Zoom** (`Zoom`, `ZoomShown`, `LevelMath`): in doublings, as people know it. A lens button glides there in
  0.3 s however far it is (`ramp(toVideoZoomFactor:withRate:)`), pinching and the dial follow
  the finger with a quick ramp, so steps between touches don't show. The buttons show the zoom
  asked for at once (a tap on "2" says "2×" while the picture glides), and one highlight glides
  to the chosen lens; the camera's own zoom shows only when something else changed it. Tapping
  the active "1×" button on the main back camera cycles through 24 mm (1×), 28 mm (1.2×) and
  35 mm (1.5×), starting at the default focal length chosen in Settings › Camera. The
  highest zoom is a round number (`Zoom.highest`: a camera that stops at 9.94 offers 10).
  Dragging the zoom buttons sideways turns them into a dial with a mark at every lens; a light
  tick when a lens is passed.
- **Composition & video locks** (`Composition`, `LevelOverlay`, `MotionTracker`): optional
  CoreMotion level showing a thin broken horizon bar on slight tilt (snapping yellow with light
  haptics when straight, then fading out) and twin overhead crosshairs when aiming straight down
  or up (flat-lay). Front-camera mirroring, geometric lens distortion correction
  (`isGeometricDistortionCorrectionEnabled`), hardware lens-smudge detection hints
  (`cameraLensSmudgeDetectionStatus`, dismissible banner), and optional camera-lens
  (`primaryConstituentDeviceSwitchingBehavior`) and white-balance locks while recording video.
- **Newer & Pro iPhone features** (`ProDevices`, `DeviceProfile`, `AudioMixSheet`,
  capability-gated via `DeviceCapabilities`):
  - Halden knows the iPhone model (`DeviceProfile`, from `utsname.machine`: name, chip, lenses,
    48 MP, ProRAW, ProRes, Log, macro, Action, Cinematic, Spatial, Camera Control, USB-C
    recording) for every iPhone from the 12 on. AVFoundation's runtime checks have the last
    word; the profile can only rule out what they overstate (`DeviceProfile.effective`).
    Settings › Camera › This iPhone names the model and lists what its camera can do; the
    capabilities found when the back camera last ran are kept (`CapabilityCache`), so Settings is
    right before the camera opens and while the front camera runs.
  - Everything an iPhone can't do is hidden everywhere (camera, drawer, Settings), including
    Cinematic, Portrait (depth), Action mode, wind noise removal and 24 MP where they're missing.
    `StandInCamera` pretends to be a given iPhone with `-ui-testing-device iPhone15,4`, advertises
    full capabilities otherwise (and hides them with `-ui-testing-basic-device`).
  - **Apple ProRAW** up to 48 MP (`isAppleProRAWEnabled`), **Apple ProRes** & **Apple Log**
    (`AVVideoCodecType.proRes422`, `AVCaptureColorSpace.appleLog`), **External USB-C SSD**
    direct capture (`AVExternalStorageDeviceDiscoverySession` with `USB-C` badge), **Spatial
    Video** mode (`isSpatialVideoCaptureEnabled`, MV-HEVC, server `captureMode = "spatial"`),
    **Macro Control** yellow flower toggle + Preserve Settings, iPhone 16+ **Camera Control**
    sliders (`AVCaptureSystemZoomSlider`, `AVCaptureSystemExposureBiasSlider`,
    `AVCaptureIndexPicker` for Photographic Styles), and **Spatial 3D Audio**
    (`firstOrderAmbisonics`) with post-capture **Audio Mix** (`CNAssetSpatialAudioInfo.audioMix`,
    saved non-destructively in `EditRecipe` as `audioMix` / `audioMixIntensity`).
- **Apple Watch camera remote** (`HaldenWatch`, `HaldenWatchProtocol`, `WatchCameraBridge`):
  - Companion watchOS target streaming throttled low-resolution JPEG previews (~8 fps, ≤ 28 KB
    adaptive quality) encoded off the main thread directly from camera pixel buffers over
    `WatchConnectivity` while the iPhone camera is open, never stalling the iPhone shutter when
    unreachable or busy.
  - Supports immediate shutter, one-shot 3-second countdown (without altering the iPhone's
    self-timer setting), camera flip, Digital Crown zoom (`.digitalCrownRotation`), and
    post-capture photo preview on the Watch.
- **Dual Capture & View Outside the Frame** (`DualCapture`, `MultiCamEngine`, `DualPreviewOverlay`):
  - **Dual mode (Double Take)**: simultaneous front + back camera capture via
    `AVCaptureMultiCamSession` (on MultiCam devices, including iPhone 15) with a draggable
    corner-snapping Picture-in-Picture window, one-tap lens swap (from either the PiP button or
    main flip button), 1×–5× back-camera zoom, and Photo/Video toggle saving a single composited
    HEIC/JPEG photo (`DualCompositor`) or `.mov` video with microphone audio and GPS metadata.
  - **View Outside the Frame**: optional setting under Settings › Camera › Composition that shows
    a dimmed peripheral surround outside the photo crop frame at zoom ≥ 1×.
- **Scanner, Live Text & Visual Look Up** (`Scanner`, `ScannerOverlays`, `Viewer`):
  - **Viewfinder QR scanner**: `AVCaptureMetadataOutput` (`.qr`) detects links, Wi-Fi networks,
    contacts (`vCard` / `MECARD`), Halden pairing links and plain text in Photo mode with a
    floating yellow action pill (links open directly; Wi-Fi joins via `NEHotspotConfigurationManager`
    or copies password). Toggleable under Settings › Camera › Scan QR Codes.
  - **Viewfinder Live Text**: throttled Vision text recognition (`VNRecognizeTextRequest`) offers
    a Live Text button in the viewfinder to inspect and copy detected text. Toggleable under
    Settings › Camera › Show Detected Text.
  - **Full-screen Live Text & Visual Look Up**: `Viewer` attaches VisionKit's
    `ImageAnalysisInteraction` (`.automatic` + `.visualLookUp`) to still photos where supported so
    you can select, copy, translate, call, convert units, and look up plants, animals, landmarks or
    artwork right in Halden.
- **Live Photo effects & Key Photo** (`LivePhotoEffects`, `LivePhotoEffectSheet`, `Viewer`):
  - Full-screen Live Photos offer **Live**, **Loop** (cross-faded seamless MP4), **Bounce**
    (forward/reverse MP4), **Long Exposure** (Vision-aligned averaged HEIC/JPEG still), and a
    **Key Photo** frame scrubber.
  - Effects are stored non-destructively in `EditRecipe` (`liveEffect`, `liveKeyFrameMs`); the
    rendered file is cached locally and synced to the server under the `live_effect` derived role
    (`PUT`/`DELETE /assets/{id}/files/live_effect`) so the original Live Photo stays untouched.
- **Panorama** (`Panorama`, `PanoramaGuide`, `PanoramaStitcher`, `PanoramaOverlay`):
  - Dedicated **Pano** camera mode supporting horizontal (`leftToRight` / `rightToLeft`) and
    vertical (`bottomToTop` / `topToBottom`) sweeps. Tap the arrow on the guide strip to reverse
    direction, or tap the orientation pill to switch between Horizontal and Vertical.
  - CoreMotion guidance (`PanoramaGuide`) tracks sweep progress and off-axis tilt, displaying
    "Move slower." when panning too quickly and "Keep arrow on the line." when drifting off the
    yellow guide line.
  - Captures frames from the video output (`AVCaptureVideoDataOutput`) with exposure and white
    balance locked for uniform brightness/colour across the sweep, aligns consecutive frames with
    Vision translational registration (`VNTranslationalImageRegistrationRequest`) and gyroscope
    priors, blends overlapping strips with smooth linear alpha feathering, crops minor wiggle edges,
    and saves the finished panorama as HEIC.
- **Cinematic Video, Action Mode, Audio & Live Scopes** (`VideoPro`, `LiveScopesOverlay`,
  `CinematicEditorView`):
  - **Cinematic Video**: dedicated **Cinematic** mode using iOS 26
    `AVCaptureDeviceInput.isCinematicVideoCaptureEnabled` + `simulatedAperture` (`f/2.0–f/16`) and
    required metadata object types (`requiredMetadataObjectTypesForCinematicVideoCapture`), with
    tap-to-track focus via `setCinematicVideoTrackingFocus(at:focusMode:)`. Videos carry
    `captureMode = "cinematic"` to the server and `/sync`. After capture, opening a Cinematic video
    offers `CinematicEditorView` (`Cinematic.framework`: `CNAssetInfo`, `CNScript`, `CNDecision`)
    to adjust f-stop and add tap-to-refocus transitions stored non-destructively in `EditRecipe`.
  - **Action Mode**: enhanced stabilization (`AVCaptureVideoStabilizationMode.cinematicExtendedEnhanced`)
    with automatic low-light guidance ("More light required.") when ISO is high and Preserve
    Settings support (`preserveActionMode`).
  - **Audio**: Stereo or Mono (`multichannelAudioMode`), Wind Noise Removal
    (`isWindNoiseRemovalEnabled` when supported with multichannel audio), and AirPods / Bluetooth
    HFP microphone routing (`AVAudioSession` `.allowBluetoothHFP` + preferred input).
  - **Live Histogram & Waveform**: RGB + Luma histogram and horizontal Luma waveform (`LiveScopesOverlay`)
    computed on demand from the Metal viewfinder frames (`LiveScopesAnalyzer`) when enabled in the
    camera drawer or Settings › Camera, adding zero GPU overhead while off.
- **Night Mode** (`NightMode`, `NightMath`, `TripodDetector`, `NightStacker`):
  - Automatically suggests Night Mode in dark scenes (`moon.stars.fill` badge and drawer slider):
    1–3 s handheld, or 10–30 s when CoreMotion (`TripodDetector`) detects the iPhone is mounted on
    a tripod. The drawer slider lets you choose Off, Auto, or a manual duration (up to 10 s
    handheld / 30 s on tripod), with Preserve Settings support (`preserveNightMode`).
  - "Auto" starts only in really dim light (ISO ≥ 1000 at 1/17 s or slower, or ISO ≥ 2500), not in
    an ordinary room in the evening. All frames are asked for at once, so the camera takes them
    back to back; once they are in, the camera is free for the next photo while they are combined.
  - Captures a burst of short exposures while showing a circular progress ring around the shutter
    and a live "Hold still" twin-crosshair target, aligns the frames with Vision
    (`VNHomographicImageRegistrationRequest`, translational fallback), merges them on Metal GPU
    using a median-anchored outlier-rejecting trimmed-mean compute kernel (with CPU fallback),
    applies Core Image noise reduction and shadow lift, and saves the result as HEIC.
- **Portrait mode & automatic depth** (`Portrait`, `PortraitMath`, `PortraitRenderer`):
  - Dedicated **Portrait** camera mode with live blurred background preview through the Metal
    viewfinder (`AVCaptureDepthDataOutput` + `AVCaptureDataOutputSynchronizer` when supported,
    with face/matte fallback), depth & Portrait Effects Matte delivery
    (`isDepthDataDeliveryEnabled`, `isPortraitEffectsMatteDeliveryEnabled`), and distance /
    low-light hints ("Move farther away", "Place subject within 2.5 m", "More light required").
  - Adjustable depth of field (`f/1.4–f/16`, `CIDepthBlurEffect`) and six Portrait Lighting
    effects (Natural, Studio, Contour, Stage, Stage Mono, High-Key Mono) built from the matte
    and Vision face detection; both are stored non-destructively in `EditRecipe` and editable
    later in `EditView` › Looks.
  - Automatic depth in **Photo** mode: when `AVCaptureMetadataOutput` detects a person, face,
    dog or cat, Halden displays an `f` badge and captures depth data automatically so the photo
    can be turned into a Portrait afterwards.
- **Photographic Styles, Filters & Metal viewfinder** (`PhotoLooks`, `LookRenderer`,
  `MetalPreviewView`, `StylePadView`):
  - **Custom Metal viewfinder**: when a non-default Photographic Style or Filter, Portrait or the
    live scopes are active, preview-sized `AVCaptureVideoDataOutput` frames pass through Core
    Image and are drawn into a `CAMetalLayer` (`MetalPreviewView`) on the frames' own queue, never
    on the main thread; the system `AVCaptureVideoPreviewLayer` stops drawing meanwhile. In Photo
    and Portrait the frame output stays attached (it also feeds Live Text and the filter buttons),
    so a filter or style never rebuilds the capture session: it shows in the next frame.
  - **Only what a change needs** (`CameraChangeScope`): a look goes into the next frame, lens
    correction, QR scanning or the Cinematic aperture are set on the device, and only formats,
    outputs and resolution reconfigure the session, with every property set only when it changes.
    The short blur of a mode change ends with the first picture in the new mode (no fixed wait).
  - **Photographic Styles**: 15 presets (Standard, Amber, Gold, Rose Gold, Neutral, Cool Rose,
    Vibrant, Natural, Luminous, Dramatic, Quiet, Cozy, Ethereal, Muted B&W, Stark B&W) with a 2D
    Tone/Color control pad and Palette intensity slider, implemented non-destructively in Core
    Image and stored in `EditRecipe` (version 2) so they can be changed later in `EditView` ›
    Looks.
  - **Filters**: Vivid, Warm, Cool, Dramatic, Film, Faded, Mono, Noir and Sepia, each strong
    enough to tell apart at a glance (a unit test renders a test picture through every filter and
    style and checks that any two differ), shown as small live pictures in the camera and the
    editor, with a strength slider (`filterIntensity`, 0…1). Stored in `EditRecipe` (version 2)
    and synced across devices with full edit history; the filters of earlier versions still show
    on photos that have them.
- **Gestures, shutter & bursts** (`ShutterGestures`, `Bursts`, `BurstPickerView`,
  `HaldenShortcuts`):
  - **Focus & exposure sun**: tapping the picture focuses and shows a vertical sun slider beside
    the focus square; dragging vertically adjusts exposure compensation (EV −2…+2). Long press
    locks AE/AF.
  - **QuickTake**: holding the shutter in photo mode starts a video recording (temporarily
    detaching Live Photos so `AVCaptureMovieFileOutput` never coexists with active Live Photos);
    dragging right locks recording hands-free, and dragging up zooms smoothly.
  - **Burst**: dragging the shutter left (or holding Volume Up when enabled) shoots a rapid burst
    of photos sharing a `burstId` carried through the server and `/sync`, with a live counter.
    In the library grid, burst photos collapse into one stack tile with a count badge; full
    screen opens `BurstPickerView` to pick favorites and move the rest to the trash.
  - **Photo while recording & pause/resume**: in video mode (where Live Photos are off, so photo
    and movie outputs coexist) and locked QuickTake, the shutter row shows a pause/resume button
    (`AVCaptureMovieFileOutput.pauseRecording`) and a still-photo button that snaps a photo
    without interrupting recording.
  - **Hardware shutter & voice**: `AVCaptureEventInteraction` triggers the shutter (or Volume Up
    burst) from hardware volume buttons and AirPods stem where iOS allows it. Siri & Shortcuts
    App Intents (`TakePhotoIntent`, `RecordVideoIntent`, `TakeSelfieIntent`) open the camera in
    the chosen mode/side and fire after a 3-second countdown.
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
- **Library, Albums, Map**: the Photos tab switches between them with a switcher that floats
  above the tab bar, as in Apple's Photos; "Select" and the menu (without place, trash,
  uploads) are top right.
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
- **Small copies of videos** (`SmallVideos`): after a big video is on the server, the iPhone
  makes a 720p copy (H.264, about 3 Mbit/s, the sound as it was) with its video encoder, while
  the battery allows (charging or more than a third left, no Low Power Mode), and sends it as
  the asset's `stream`; otherwise the server makes it. A video that isn't on this iPhone plays
  from the server as the small copy on cellular, in Low Data Mode and away from home, as the
  original at home (Settings › Uploads: automatic, always small, always original).
- **Shared links** (a photo's share menu, the chosen photos, an album's menu; Settings ›
  Shared links): a web page for people without Halden, working for a day, a week, a month or
  always, with a password if wanted, originals only if allowed. The list shows how often each was
  opened; a swipe withdraws one. While the server isn't on the internet (`docs/SHARING.md`),
  the app says so.
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
  - **Screenshots and screen recordings** (`ScreenshotPlace`, Settings › Place): when imported
    without a place, screenshots (and screen recordings, configurable) get an estimated place in
    Halden only (Apple Photos stays untouched): this iPhone's current place (`device`) if taken
    within the configured window (default 30 min) while Halden is open, else the place of the
    nearest photo within two hours (`estimated`). Existing unlocated screenshots in Halden get
    a one-time pass using the nearby-photo rule. Full screen and Info show "Where your iPhone
    was" or "From a photo nearby", and the map marks them with a dashed frame.
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

The layout of every screen is checked by `UITests/LayoutTests.swift`: nothing cut off by the
edge of the screen, no controls on top of each other, our buttons at least 44×44 points, and no
button or text that can't be seen (too little contrast on the screenshot, such as white on
white). It runs with the other UI tests, and on its own, without a server, on the smallest and
the biggest iPhone and as an iPhone 15 (`HALDEN_DEVICE_PROFILE=iPhone15,4` on an iPhone 16
simulator, same size), each also with big text, keeping a screenshot of every screen in
`Local/screens/<date>/`:

```sh
ios/layout-tests.sh
```

The camera also measures itself on the iPhone (opening, mode change, turning around, a filter,
shutter to thumbnail, shutter to the next photo) and shows the medians against the targets in
Settings › Camera Timings (`CameraTimingLog`).

Measurements (launch, camera start, mode-switch latency, zoom glide, Metal viewfinder toggle &
memory, filter switching, scrolling 50,000 photos, and the 50,000-photo map) run only on purpose:

```sh
TEST_RUNNER_HALDEN_MEASURE=1 ios/ui-tests.sh -only-testing:HaldenUITests/PerformanceTests
```

The CI (`.github/workflows/ios.yml`) runs all of it on macOS and checks that the Xcode project
matches `project.yml`.
