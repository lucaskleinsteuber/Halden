import CoreLocation
import Foundation
import HaldenKit
import ImageIO
import Observation
import SwiftUI

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
    /// While the camera changes mode (or video format): the picture is blurred and still, as in
    /// Apple's camera, so the switch doesn't flicker.
    private(set) var switching = false
    /// The zoom asked for, which the lens buttons show at once.
    private var zoomShown = ZoomShown()
    /// The photo just taken, small, for the button left of the shutter: there at once, before
    /// the library has made its thumbnail.
    private(set) var lastShot: CGImage?

    @ObservationIgnored let location = LocationTracker()
    @ObservationIgnored var settings: () -> AppSettings = { AppSettings() }
    @ObservationIgnored var keepPhoto: ((TakenPhoto, UploadMetadata) -> Void)?
    @ObservationIgnored var keepVideo: ((URL, UploadMetadata) -> Void)?
    /// Keeps the manual values for the next time, when that is set (the app saves them).
    @ObservationIgnored var keepManual: ((ManualSettings?) -> Void)?
    /// Updates persisted settings when Preserve Settings rules apply on close.
    @ObservationIgnored var updateSettings: (((inout AppSettings) -> Void) -> Void)?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var video: (request: VideoRequest, place: ClientLocation?)?
    @ObservationIgnored private var applied: CaptureOptions?
    @ObservationIgnored private var switches = 0

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

    /// The zoom to show: the one asked for (at once), or the camera's when something else moved it.
    var zoom: Double {
        zoomShown.value(device: backend.state.zoom, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Zoom as shown (0.5, 1, 2, …), within what the camera offers. `glide` for the lens buttons.
    func zoom(to factor: Double, glide: Bool) {
        let range = backend.state.zoomRange
        let target = min(max(factor, range.lowerBound), range.upperBound)
        zoomShown.ask(target, at: ProcessInfo.processInfo.systemUptime)
        backend.zoom(to: target, glide: glide)
    }

    func flip() {
        zoomShown.forget()
        backend.flip()
    }

    /// Hands a mode or format to the camera; meanwhile the picture is blurred. It clears again
    /// once the camera has the new one and a frame later, at the earliest when the frame has
    /// changed its shape on the screen.
    private func change(to mode: CameraMode, options: CaptureOptions) {
        switches += 1
        let mine = switches
        switching = true
        Task {
            let started = ContinuousClock.now
            await backend.setMode(mode, options: options)
            let left = Self.switchAtLeast - (ContinuousClock.now - started)
            try? await Task.sleep(for: max(left, .zero) + Self.firstFrame)
            if mine == switches { switching = false }
        }
    }

    /// How long the frame takes to change between 4:3 and 16:9 on the screen.
    static let switchAtLeast = Duration.milliseconds(280)
    /// About how long the camera takes to show a picture again after a change.
    static let firstFrame = Duration.milliseconds(120)

    /// At app start, so the picture is there at once when the camera opens.
    func prepare() {
        let current = settings()
        if current.preserveMode, let kept = current.keptMode, let restored = CameraMode(rawValue: kept) {
            mode = restored
        }
        let options = CaptureOptions(current)
        applied = options
        backend.prepare(mode: mode, options: options)
        if current.keepManualSettings, let kept = current.keptManual {
            manual = kept
            backend.setManual(kept)
        } else if current.preserveExposure, current.keptExposureBias != 0 {
            manual.exposureBias = CameraControls.clampedExposureBias(current.keptExposureBias)
            backend.setManual(manual)
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
        change(to: mode, options: options)
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
        let current = settings()
        let bias = manual.exposureBias
        let currentMode = mode.rawValue
        // Closed: preserve only what the user asked to keep.
        if current.keepManualSettings {
            keepManual?(manual.isAutomatic ? nil : manual)
        } else {
            resetManual()
            if current.preserveExposure {
                manual.exposureBias = CameraControls.clampedExposureBias(bias)
                backend.setManual(manual)
            }
        }
        updateSettings? { s in
            if s.preserveMode { s.keptMode = currentMode }
            if s.preserveExposure { s.keptExposureBias = bias }
            s = CameraControls.resetUnpreserved(in: s)
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
        change(to: mode, options: options)
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
        let raw = settings.captureRAW && backend.state.canRAW
        let aspectRatio = settings.photoAspectRatio
        shots += 1
        let request = PhotoRequest(
            format: settings.photoFormat, flash: settings.flash, location: place,
            trueNorth: location.compass?.trueNorth ?? false, takenAt: now,
            live: settings.livePhotos && backend.state.canLive && !raw,
            resolution: settings.photoResolution, raw: raw,
            prioritizeFaster: settings.prioritizeFasterShooting)
        Task {
            guard var photo = await backend.takePhoto(request) else {
                problem = "The photo could not be taken."
                return
            }
            problem = nil
            if let crop = aspectRatio.crop(forWidth: photo.width, height: photo.height) {
                var recipe = EditRecipe()
                recipe.crop = crop
                photo.edit = recipe
            }
            let data = photo.data
            if let small = await Task.detached(operation: { Self.small(data) }).value {
                withAnimation(.snappy(duration: 0.25)) { lastShot = small }
            }
            var metadata = Self.metadata(at: now, place: place)
            metadata.width = photo.width
            metadata.height = photo.height
            keepPhoto?(photo, metadata)
        }
    }

    /// The library shows the newest photo itself now.
    func forgetLastShot() {
        lastShot = nil
    }

    /// A photo's picture at button size (from the embedded thumbnail when there is one).
    nonisolated static func small(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
    private var oneShot: [CheckedContinuation<PlaceReading?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
    }

    func start(accuracyWanted: Double) {
        // The best the phone can do when a few metres matter; a little less precise saves power.
        manager.desiredAccuracy = accuracyWanted <= 20 ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
        // In the UI tests no system question covers the screen (a fresh simulator would ask).
        if manager.authorizationStatus == .notDetermined,
            !ProcessInfo.processInfo.arguments.contains("-ui-testing")
        {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// A fresh reading right now, without asking for permission (returns `nil` when not allowed
    /// or no fix arrives in time). Used when taking over recent screenshots while the app is open.
    func currentReading(timeout: Duration = .seconds(4)) async -> PlaceReading? {
        let now = Date()
        if let reading, abs(now.timeIntervalSince(reading.measuredAt)) <= CapturePlace.maxAge { return reading }
        if let last = manager.location, last.horizontalAccuracy >= 0,
            abs(now.timeIntervalSince(last.timestamp)) <= CapturePlace.maxAge
        {
            let fresh = PlaceReading(
                latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, altitude: last.altitude,
                horizontalAccuracy: last.horizontalAccuracy, verticalAccuracy: last.verticalAccuracy,
                measuredAt: last.timestamp)
            reading = fresh
            return fresh
        }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        return await withCheckedContinuation { continuation in
            oneShot.append(continuation)
            if oneShot.count == 1 {
                manager.requestLocation()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finishOneShot(with: nil)
                }
            }
        }
    }

    private func finishOneShot(with reading: PlaceReading?) {
        guard !oneShot.isEmpty else { return }
        let waiters = oneShot
        oneShot = []
        for waiter in waiters { waiter.resume(returning: reading) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let reading = PlaceReading(
            latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, altitude: last.altitude,
            horizontalAccuracy: last.horizontalAccuracy, verticalAccuracy: last.verticalAccuracy,
            measuredAt: last.timestamp)
        MainActor.assumeIsolated {
            self.reading = reading
            self.finishOneShot(with: reading)
        }
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.finishOneShot(with: nil) }
    }
}
