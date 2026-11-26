import Foundation
import HaldenKit
import UIKit

enum CameraMode: String, CaseIterable, Sendable {
    case photo, portrait, panorama, dual, video, cinematic, slowMotion, timeLapse

    /// Everything except still/panorama/dual modes is recorded as video with start/stop.
    var records: Bool { self == .video || self == .cinematic || self == .slowMotion || self == .timeLapse }

    /// Still-photo capture modes (4:3 / 1:1 / 16:9 viewfinder).
    var isStill: Bool { self == .photo || self == .portrait }

    /// What the server calls videos taken this way.
    var captureMode: String? {
        switch self {
        case .cinematic: "cinematic"
        case .slowMotion: "slowmo"
        case .timeLapse: "timelapse"
        default: nil
        }
    }
}

enum CameraSide: Sendable {
    case back, front
}

/// How the camera is set up (from the settings): photos, videos, and Live Photos.
struct CaptureOptions: Equatable, Sendable {
    var resolution: AppSettings.VideoResolution
    var frameRate: Int
    var hdr: Bool
    var autoLowLightFPS: Bool
    var live: Bool
    var photoResolution: PhotoResolution
    var captureRAW: Bool
    var prioritizeFasterShooting: Bool
    var allowAudioPlayback: Bool
    var mirrorFrontCamera: Bool
    var lensCorrection: Bool
    var lockVideoCamera: Bool
    var lockVideoWhiteBalance: Bool
    var style: PhotographicStyle?
    var filter: PhotoFilter?
    var portraitAperture: Double
    var portraitLighting: PortraitLighting
    var actionMode: Bool
    var cinematicAperture: Double
    var audioChannelMode: AudioChannelMode
    var windNoiseRemoval: Bool
    var allowAirPodsMic: Bool
    var showHistogram: Bool
    var showWaveform: Bool
    var scanQRCodes: Bool
    var showLiveText: Bool
    var viewOutsideTheFrame: Bool
    var slowMotionRate: Int
    /// Seconds between pictures of a time-lapse; `nil` for automatic.
    var timeLapseInterval: Double?

    init(_ settings: AppSettings) {
        resolution = settings.videoResolution
        frameRate = settings.videoFrameRate
        hdr = settings.videoHDR
        autoLowLightFPS = settings.autoLowLightFPS
        live = settings.livePhotos
        photoResolution = settings.photoResolution
        captureRAW = settings.captureRAW
        prioritizeFasterShooting = settings.prioritizeFasterShooting
        allowAudioPlayback = settings.allowAudioPlayback
        mirrorFrontCamera = settings.mirrorFrontCamera
        lensCorrection = settings.lensCorrection
        lockVideoCamera = settings.lockVideoCamera
        lockVideoWhiteBalance = settings.lockVideoWhiteBalance
        style = settings.photographicStyle
        filter = settings.photoFilter
        portraitAperture = settings.portraitAperture
        portraitLighting = settings.portraitLighting
        actionMode = settings.actionMode
        cinematicAperture = settings.cinematicAperture
        audioChannelMode = settings.audioChannelMode
        windNoiseRemoval = settings.windNoiseRemoval
        allowAirPodsMic = settings.allowAirPodsMic
        showHistogram = settings.showHistogram
        showWaveform = settings.showWaveform
        scanQRCodes = settings.scanQRCodes
        showLiveText = settings.showLiveText
        viewOutsideTheFrame = settings.viewOutsideTheFrame
        slowMotionRate = settings.slowMotionRate
        timeLapseInterval = settings.timeLapseInterval > 0 ? settings.timeLapseInterval : nil
    }
}

/// What the camera can do right now.
struct CameraState: Equatable, Sendable {
    var ready = false
    var problem: String?
    var side = CameraSide.back
    var canFlip = false
    /// Zoom as people know it from Apple's camera: 0.5 ultra wide, 1 main camera, 2, 3 or 5 tele.
    var presets: [Double] = [1]
    var zoom = 1.0
    var zoomRange: ClosedRange<Double> = 1...1
    var hasFlash = false
    var hasTorch = false
    var focusLocked = false
    /// Live Photos can be taken (this camera, photo mode).
    var canLive = false
    /// Bayer RAW (DNG) can be captured on this camera in photo mode.
    var canRAW = false
    /// Photo resolutions the active camera supports (subset of 12 / 24 / 48 MP).
    var availableResolutions: [PhotoResolution] = [.mp12]
    /// True when the camera detects a smudged lens (where supported by hardware).
    var lensSmudged = false
    /// True when the custom Metal + Core Image viewfinder is active instead of the system layer.
    var customPreviewActive = false
    /// True when the active camera supports depth data delivery (for Portrait & auto-depth).
    var canDepth = false
    /// True when a person, dog or cat is detected in photo mode (auto-depth enabled).
    var subjectDetected = false
    /// Live distance / lighting guidance in Portrait mode.
    var portraitHint: PortraitHint?
    /// QR code currently detected in the camera viewfinder (Photo mode when enabled).
    var detectedQR: ScannedQRCode?
    /// Live Text recognized in the camera viewfinder (Photo mode when enabled).
    var detectedText: String?
    /// True when the active camera supports Cinematic Video capture (iOS 26+).
    var canCinematic = false
    /// True when the device supports simultaneous multi-camera capture (Dual Capture & Outside Frame).
    var canMultiCam = false
    /// True when hardware wind noise removal is available on the active microphone input.
    var canWindNoiseRemoval = false
    /// What can be set by hand on this camera now; `nil` when nothing.
    var manualLimits: ManualLimits?
    /// The video format actually used (the wished one may not exist on this camera).
    var videoFormat: String?
}

/// A photo as it comes out of the camera, ready to be written to disk.
struct TakenPhoto: Sendable {
    var data: Data
    var heic: Bool
    var width: Int
    var height: Int
    /// The short video of a Live Photo, in a temporary file.
    var liveVideo: URL? = nil
    /// Companion Bayer DNG when RAW was enabled.
    var rawData: Data? = nil
    /// Non-destructive crop/edit (such as 16:9 or 1:1 aspect ratio).
    var edit: EditRecipe? = nil
}

struct PhotoRequest: Sendable {
    var format: AppSettings.PhotoFormat
    var flash: AppSettings.Flash
    /// Written into the file, like Apple's camera does.
    var location: ClientLocation?
    var trueNorth: Bool
    var takenAt: Date
    /// A Live Photo: with its short video (when the camera can).
    var live = false
    /// Target photo resolution (12 / 24 / 48 MP).
    var resolution = PhotoResolution.mp24
    /// Also capture Bayer DNG when supported.
    var raw = false
    /// Prefer faster capture over maximum processing latency.
    var prioritizeFaster = true
    /// Mirror front-camera photos so they match the preview.
    var mirrorFrontCamera = false
    /// Include depth data (Portrait mode or automatic person/pet detection in Photo mode).
    var captureDepth = false
    /// Include Portrait Effects Matte when supported (Portrait mode).
    var capturePortraitMatte = false
}

struct VideoRequest: Sendable {
    var url: URL
    var location: ClientLocation?
    var takenAt: Date
    var timeZone: TimeZone
    /// Video, slow motion or time-lapse.
    var mode = CameraMode.video
}

/// A camera for the camera screen: the real one (`DeviceCamera`), or the stand-in that the
/// simulator and the UI tests use (`StandInCamera`).
@MainActor
protocol CaptureBackend: AnyObject {
    var state: CameraState { get }
    /// ISO, shutter, white balance and focus as the camera has them now (a few times a second).
    var readings: CameraReadings { get }
    /// Live RGB+Luma histogram and luma waveform data when enabled (`nil` when scopes are off).
    var liveScopes: LiveScopesData? { get }
    /// Live secondary camera image for the Picture-in-Picture overlay in Dual Capture mode.
    var dualPipImage: UIImage? { get }
    /// Shows what the camera sees.
    var previewView: UIView { get }
    /// Gets everything ready without starting, so the picture is there the moment the camera
    /// screen opens. Does nothing until the camera may be used.
    func prepare(mode: CameraMode, options: CaptureOptions)
    func start()
    func stop()
    /// Returns once the camera works in the new mode.
    func setMode(_ mode: CameraMode, options: CaptureOptions) async
    func flip()
    /// Zoom as shown (0.5, 1, 2, …). `glide` for the lens buttons (about 0.3 s for any
    /// distance); otherwise it follows a finger closely. `state.zoom` follows the camera (the
    /// screen shows `CameraModel.zoom`, the zoom asked for).
    func zoom(to factor: Double, glide: Bool)
    /// A point in `previewView`. `lock` keeps focus and exposure until the next tap.
    func focus(at point: CGPoint, lock: Bool)
    func setTorch(_ on: Bool)
    /// Values set by hand; what is `nil` the camera decides. Kept across lenses and modes.
    func setManual(_ settings: ManualSettings)
    func takePhoto(_ request: PhotoRequest) async -> TakenPhoto?
    /// Captures a rapid burst of short exposures for Night Mode stacking.
    func takeNightBurst(
        count: Int, request: PhotoRequest, onFrame: @MainActor @escaping (Int, Int) -> Void
    ) async -> [Data]
    /// Takes a still photo without interrupting an active video recording.
    func takeStillWhileRecording(_ request: PhotoRequest) async -> TakenPhoto?
    func startRecording(_ request: VideoRequest) -> Bool
    /// Starts a QuickTake video recording from photo mode (temporarily detaching Live Photos).
    func startQuickTake(_ request: VideoRequest) -> Bool
    func pauseRecording()
    func resumeRecording()
    /// The finished video file, or `nil` when nothing usable was recorded.
    func stopRecording() async -> URL?
    /// Starts collecting frames for a Panorama (locks exposure and white balance).
    func startPanorama(direction: PanoramaDirection) -> Bool
    /// Stops Panorama capture, unlocks AE/AWB, and stitches frames into a HEIC photo.
    func stopPanorama(request: PhotoRequest) async -> TakenPhoto?
    /// Takes a composited front+back Dual Capture photo as a single file.
    func takeDualPhoto(_ request: PhotoRequest, corner: PiPCorner, swapped: Bool) async -> TakenPhoto?
    /// Starts recording a composited front+back Dual Capture video as a single file.
    func startDualRecording(_ request: VideoRequest, corner: PiPCorner, swapped: Bool) -> Bool
    /// Updates PiP layout / camera swap while Dual Capture preview is live.
    func updateDualLayout(corner: PiPCorner, swapped: Bool)
}
