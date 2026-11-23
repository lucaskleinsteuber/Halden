import AVFoundation
import CoreLocation
import HaldenKit
import ImageIO
import Observation
import UIKit

/// The back main camera, photos only, in the best quality Apple's processing gives. While the
/// camera is open, location runs, so every photo knows where it was taken, how precisely, and
/// which way the camera pointed.
@MainActor
@Observable
final class CameraModel: NSObject {
    private(set) var available = false
    private(set) var running = false
    private(set) var lastProblem: String?
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera")
    private let location = LocationTracker()
    private var configured = false
    private var pending: [Int64: PhotoCapture] = [:]
    /// Gets each photo: its data, whether it is HEIC (else JPEG), and what is known about it.
    var keep: ((Data, Bool, UploadMetadata) -> Void)?

    func start() {
        location.start()
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                lastProblem = "Halden may not use the camera. Allow it in Settings › Halden."
                return
            }
            configure()
            let handle = SessionHandle(session: session)
            queue.async { handle.session.startRunning() }
            running = true
        }
    }

    func stop() {
        location.stop()
        let handle = SessionHandle(session: session)
        queue.async { handle.session.stopRunning() }
        running = false
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera)
        else {
            available = false
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        output.maxPhotoQualityPrioritization = .quality
        if let largest = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
            $0.width * $0.height < $1.width * $1.height
        }) {
            output.maxPhotoDimensions = largest
        }
        session.commitConfiguration()
        available = true
    }

    /// Takes a photo. The shutter never waits: the photo is handed over when the camera is done.
    func capture() {
        guard available else { return }
        let settings =
            output.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        let heic = settings.format?[AVVideoCodecKey] as? AVVideoCodecType == .hevc
        let id = settings.uniqueID
        let capture = PhotoCapture(
            location: location.current, heading: location.heading, takenAt: Date(), heic: heic
        ) { [weak self] data, metadata in
            self?.pending[id] = nil
            self?.keep?(data, heic, metadata)
        }
        pending[settings.uniqueID] = capture
        output.capturePhoto(with: settings, delegate: capture)
    }
}

/// One photo on its way out of the camera.
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let location: CLLocation?
    let heading: Heading?
    let takenAt: Date
    let heic: Bool
    let done: @MainActor (Data, UploadMetadata) -> Void

    init(
        location: CLLocation?, heading: Heading?, takenAt: Date, heic: Bool,
        done: @escaping @MainActor (Data, UploadMetadata) -> Void
    ) {
        self.location = location
        self.heading = heading
        self.takenAt = takenAt
        self.heic = heic
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
            let data = photo.fileDataRepresentation(with: GPSWriter(location: location, heading: heading))
        else { return }
        let dimensions = photo.resolvedSettings.photoDimensions
        let zone = TimeZone.current
        var metadata = UploadMetadata(
            takenAt: Int64(takenAt.timeIntervalSince1970 * 1000),
            timeZoneOffsetMinutes: zone.secondsFromGMT(for: takenAt) / 60,
            timeZone: zone.identifier,
            width: Int(dimensions.width), height: Int(dimensions.height))
        if let location, location.horizontalAccuracy >= 0 {
            metadata.location = ClientLocation(
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
                heading: heading?.degrees,
                headingAccuracy: heading?.accuracy)
        }
        let finished = metadata
        Task { @MainActor in done(data, finished) }
    }
}

/// Writes the place (with its accuracy) and direction into the photo's own metadata, like
/// Apple's camera does, so the file carries them wherever it goes.
final class GPSWriter: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    let location: CLLocation?
    let heading: Heading?

    init(location: CLLocation?, heading: Heading?) {
        self.location = location
        self.heading = heading
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let location, location.horizontalAccuracy >= 0 else { return nil }
        var metadata = photo.metadata
        let coordinate = location.coordinate
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSHPositioningError as String: location.horizontalAccuracy,
            kCGImagePropertyGPSTimeStamp as String: ISO8601DateFormatter().string(from: location.timestamp),
        ]
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude >= 0 ? 0 : 1
        }
        if let heading {
            gps[kCGImagePropertyGPSImgDirection as String] = heading.degrees
            gps[kCGImagePropertyGPSImgDirectionRef as String] = heading.isTrueNorth ? "T" : "M"
        }
        metadata[kCGImagePropertyGPSDictionary as String] = gps
        return metadata
    }
}

/// Location and compass while the camera is open. A position that is too old or too imprecise
/// is not used: better no place than a wrong one.
@MainActor
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private(set) var heading: Heading?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
    }

    var current: CLLocation? {
        guard let latest, -latest.timestamp.timeIntervalSinceNow < 30, latest.horizontalAccuracy >= 0,
            latest.horizontalAccuracy <= 500
        else { return nil }
        return latest
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated { latest = last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let reading = Heading(newHeading)
        MainActor.assumeIsolated { heading = reading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// `AVCaptureSession` is meant to be started and stopped off the main thread (Apple says so), but
/// isn't marked `Sendable`; this carries it there.
struct SessionHandle: @unchecked Sendable {
    let session: AVCaptureSession
}

/// Which way the camera points: true north when known, else magnetic north. `nil` while the
/// compass is unsure.
struct Heading: Sendable {
    let degrees: Double
    let accuracy: Double
    let isTrueNorth: Bool

    init?(_ heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else { return nil }
        isTrueNorth = heading.trueHeading >= 0
        degrees = isTrueNorth ? heading.trueHeading : heading.magneticHeading
        accuracy = heading.headingAccuracy
    }
}
