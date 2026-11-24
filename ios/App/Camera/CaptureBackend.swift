import Foundation
import HaldenKit
import UIKit

enum CameraMode: String, CaseIterable, Sendable {
    case photo, video
}

enum CameraSide: Sendable {
    case back, front
}

/// How videos are recorded (from the settings).
struct VideoOptions: Equatable, Sendable {
    var resolution: AppSettings.VideoResolution
    var frameRate: Int
    var hdr: Bool

    init(_ settings: AppSettings) {
        resolution = settings.videoResolution
        frameRate = settings.videoFrameRate
        hdr = settings.videoHDR
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
    /// The video format actually used (the wished one may not exist on this camera).
    var videoFormat: String?
}

/// A photo as it comes out of the camera, ready to be written to disk.
struct TakenPhoto: Sendable {
    var data: Data
    var heic: Bool
    var width: Int
    var height: Int
}

struct PhotoRequest: Sendable {
    var format: AppSettings.PhotoFormat
    var flash: AppSettings.Flash
    /// Written into the file, like Apple's camera does.
    var location: ClientLocation?
    var trueNorth: Bool
    var takenAt: Date
}

struct VideoRequest: Sendable {
    var url: URL
    var location: ClientLocation?
    var takenAt: Date
    var timeZone: TimeZone
}

/// A camera for the camera screen: the real one (`DeviceCamera`), or the stand-in that the
/// simulator and the UI tests use (`StandInCamera`).
@MainActor
protocol CaptureBackend: AnyObject {
    var state: CameraState { get }
    /// Shows what the camera sees.
    var previewView: UIView { get }
    /// Gets everything ready without starting, so the picture is there the moment the camera
    /// screen opens. Does nothing until the camera may be used.
    func prepare(mode: CameraMode, video: VideoOptions)
    func start()
    func stop()
    func setMode(_ mode: CameraMode, video: VideoOptions)
    func flip()
    /// Zoom as shown (0.5, 1, 2, …); `smoothly` for the preset buttons, not while pinching.
    func zoom(to factor: Double, smoothly: Bool)
    /// A point in `previewView`. `lock` keeps focus and exposure until the next tap.
    func focus(at point: CGPoint, lock: Bool)
    func setTorch(_ on: Bool)
    func takePhoto(_ request: PhotoRequest) async -> TakenPhoto?
    func startRecording(_ request: VideoRequest) -> Bool
    /// The finished video file, or `nil` when nothing usable was recorded.
    func stopRecording() async -> URL?
}
