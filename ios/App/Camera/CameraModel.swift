import CoreLocation
import Foundation
import HaldenKit
import Observation

/// The camera screen's logic: photo and video, self-timer, flash and torch, and what each photo
/// or video knows about itself (time, place, direction). The camera itself is a
/// `CaptureBackend`; this model works the same with the real one and the stand-in.
@MainActor
@Observable
final class CameraModel {
    let backend: any CaptureBackend
    private(set) var mode = CameraMode.photo
    /// Self-timer in seconds; 0 is off.
    var timer = 0
    /// Seconds left on the self-timer while it runs.
    private(set) var countdown: Int?
    private(set) var recordingSince: Date?
    private(set) var torch = false
    private(set) var problem: String?
    /// Goes up with every photo taken, for the flash on the screen.
    private(set) var shots = 0
    /// ISO, shutter, white balance, focus and exposure compensation set by hand.
    private(set) var manual = ManualSettings()

    @ObservationIgnored let location = LocationTracker()
    @ObservationIgnored var settings: () -> AppSettings = { AppSettings() }
    @ObservationIgnored var keepPhoto: ((TakenPhoto, UploadMetadata) -> Void)?
    @ObservationIgnored var keepVideo: ((URL, UploadMetadata) -> Void)?
    /// Keeps the manual values for the next time, when that is set (the app saves them).
    @ObservationIgnored var keepManual: ((ManualSettings?) -> Void)?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var video: (request: VideoRequest, place: ClientLocation?)?
    @ObservationIgnored private var applied: CaptureOptions?

    init(backend: any CaptureBackend) {
        self.backend = backend
    }

    /// The stand-in camera in the simulator and when the UI tests ask for it; else the real one.
    static func make(standIn: Bool) -> CameraModel {
        #if targetEnvironment(simulator)
            return CameraModel(backend: StandInCamera())
        #else
            return CameraModel(backend: standIn ? StandInCamera() : DeviceCamera())
        #endif
    }

    var recording: Bool { recordingSince != nil }

    /// At app start, so the picture is there at once when the camera opens.
    func prepare() {
        let options = CaptureOptions(settings())
        applied = options
        backend.prepare(mode: mode, options: options)
        if settings().keepManualSettings, let kept = settings().keptManual {
            manual = kept
            backend.setManual(kept)
        }
    }

    /// Changes values set by hand (within what the camera can do).
    func setManual(_ change: (inout ManualSettings) -> Void) {
        var changed = manual
        change(&changed)
        if let limits = backend.state.manualLimits { changed = limits.fitted(changed) }
        guard changed != manual else { return }
        manual = changed
        backend.setManual(changed)
    }

    /// Everything back to the camera.
    func resetManual() {
        guard !manual.isAutomatic else { return }
        manual = ManualSettings()
        backend.setManual(manual)
    }

    func appear() {
        location.start(accuracyWanted: settings().locationAccuracyLimit)
        settingsChanged()
        backend.start()
    }

    /// The video or Live Photo settings may have changed (in the settings, or on the camera
    /// screen): the camera takes them over, unless it is recording.
    func settingsChanged() {
        let options = CaptureOptions(settings())
        guard options != applied, !recording else { return }
        applied = options
        backend.setMode(mode, options: options)
    }

    /// The next mode to the right (1) or left (-1) on the screen, as after a swipe.
    func switchMode(by step: Int) {
        let modes = CameraMode.strip
        guard let index = modes.firstIndex(of: mode), modes.indices.contains(index + step) else { return }
        switchTo(modes[index + step])
    }

    func disappear() {
        cancelCountdown()
        if recording { stopRecording() }
        setTorch(false)
        // Closed: manual values stay only when that is wanted.
        if settings().keepManualSettings {
            keepManual?(manual.isAutomatic ? nil : manual)
        } else {
            resetManual()
        }
        location.stop()
        backend.stop()
    }

    func switchTo(_ mode: CameraMode) {
        guard mode != self.mode, !recording else { return }
        cancelCountdown()
        setTorch(false)
        self.mode = mode
        let options = CaptureOptions(settings())
        applied = options
        backend.setMode(mode, options: options)
    }

    func setTorch(_ on: Bool) {
        guard torch != on else { return }
        torch = on
        backend.setTorch(on)
    }

    /// The big button: a photo (after the self-timer), or start and stop a video.
    func shutter() {
        if countdown != nil { return cancelCountdown() }
        if recording { return stopRecording() }
        let action: () -> Void =
            mode.records ? { [weak self] in self?.startRecording() } : { [weak self] in self?.takePhoto() }
        guard timer > 0 else { return action() }
        countdown = timer
        countdownTask = Task { [weak self] in
            for left in stride(from: self?.timer ?? 0, to: 0, by: -1) {
                self?.countdown = left
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.countdown = nil
            action()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func place(at moment: Date) -> ClientLocation? {
        CapturePlace.location(location.reading, heading: location.compass, at: moment, settings: settings())
    }

    private func takePhoto() {
        let now = Date()
        let settings = settings()
        let place = place(at: now)
        shots += 1
        let request = PhotoRequest(
            format: settings.photoFormat, flash: settings.flash, location: place,
            trueNorth: location.compass?.trueNorth ?? false, takenAt: now,
            live: settings.livePhotos && backend.state.canLive)
        Task {
            guard let photo = await backend.takePhoto(request) else {
                problem = "The photo could not be taken."
                return
            }
            problem = nil
            var metadata = Self.metadata(at: now, place: place)
            metadata.width = photo.width
            metadata.height = photo.height
            keepPhoto?(photo, metadata)
        }
    }

    private func startRecording() {
        let now = Date()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let request = VideoRequest(
            url: url, location: place(at: now), takenAt: now, timeZone: .current, mode: mode)
        guard backend.startRecording(request) else {
            problem = "The video could not be started."
            return
        }
        problem = nil
        video = (request, request.location)
        recordingSince = now
    }

    private func stopRecording() {
        guard let (request, place) = video else { return }
        video = nil
        recordingSince = nil
        Task {
            guard let url = await backend.stopRecording() else {
                problem = "The video could not be saved."
                return
            }
            var metadata = Self.metadata(at: request.takenAt, place: place)
            metadata.captureMode = request.mode.captureMode
            if let facts = try? await VideoFacts.read(url) {
                metadata.width = facts.width
                metadata.height = facts.height
                metadata.durationMs = facts.durationMs
            }
            keepVideo?(url, metadata)
        }
    }

    static func metadata(at moment: Date, place: ClientLocation?) -> UploadMetadata {
        let zone = TimeZone.current
        return UploadMetadata(
            takenAt: Int64((moment.timeIntervalSince1970 * 1000).rounded()),
            timeZoneOffsetMinutes: zone.secondsFromGMT(for: moment) / 60, timeZone: zone.identifier,
            location: place)
    }
}

/// Place and compass while the camera is open.
@MainActor
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var reading: PlaceReading?
    private(set) var compass: CompassReading?

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
    }

    func start(accuracyWanted: Double) {
        // The best the phone can do when a few metres matter; a little less precise saves power.
        manager.desiredAccuracy = accuracyWanted <= 20 ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let reading = PlaceReading(
            latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, altitude: last.altitude,
            horizontalAccuracy: last.horizontalAccuracy, verticalAccuracy: last.verticalAccuracy,
            measuredAt: last.timestamp)
        MainActor.assumeIsolated { self.reading = reading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        let reading: CompassReading? =
            heading.headingAccuracy < 0
            ? nil
            : CompassReading(
                degrees: heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading,
                accuracy: heading.headingAccuracy, trueNorth: heading.trueHeading >= 0)
        MainActor.assumeIsolated { compass = reading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
