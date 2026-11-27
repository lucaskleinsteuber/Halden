import AVFoundation
import CoreImage
import HaldenKit
import ImageIO
import Observation
import UIKit
import Vision

/// The iPhone's cameras through AVFoundation: ultra wide, main and tele as one virtual camera
/// (so zooming switches between them where Apple's camera does), and the front camera. All
/// AVFoundation work happens on the camera's own queue (`CaptureCore`), never on the main thread.
@MainActor
@Observable
final class DeviceCamera: CaptureBackend {
    private(set) var state = CameraState()
    private(set) var zoomNow = 1.0
    private(set) var lookSample: CGImage?
    private(set) var reconfigurations = 0
    @ObservationIgnored let preview = PreviewContainerView()
    var previewView: UIView { preview }
    @ObservationIgnored private let core: CaptureCore
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var zoomObservation: NSKeyValueObservation?
    @ObservationIgnored private var zoomRelay: Relay<Double>?
    @ObservationIgnored private var smudgeObservation: NSKeyValueObservation?
    @ObservationIgnored private var smudgeRelay: Relay<Bool>?
    private(set) var readings = CameraReadings()
    private(set) var liveScopes: LiveScopesData?
    private(set) var dualPipImage: UIImage?
    @ObservationIgnored private var readingsWatch: ReadingsWatch?
    @ObservationIgnored private var scopesRelay: Relay<LiveScopesData?>?
    @ObservationIgnored private var pipRelay: Relay<UIImage?>?
    @ObservationIgnored private var sampleRelay: Relay<CGImage>?
    @ObservationIgnored private let multiCam: MultiCamEngine
    @ObservationIgnored private var dualRecording = false
    @ObservationIgnored private var dualCorner = PiPCorner.topRight
    @ObservationIgnored private var dualSwapped = false
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var mode = CameraMode.photo
    @ObservationIgnored private var video: CaptureOptions?
    @ObservationIgnored var onControlStyleChanged: (@MainActor (PhotographicStyle?) -> Void)?

    init() {
        let preview = self.preview
        let core = CaptureCore(metalView: preview.metalView)
        self.core = core
        let multiCam = MultiCamEngine(metalView: preview.metalView)
        self.multiCam = multiCam
        preview.previewLayer.session = core.session
        preview.previewLayer.videoGravity = .resizeAspectFill
        core.changed = { [weak self] state, device in
            Task { @MainActor in self?.update(state, device: device?.value) }
        }
        core.onControlStyleChanged = { [weak self] style in
            Task { @MainActor in self?.onControlStyleChanged?(style) }
        }
        zoomRelay = Relay { [weak self] zoom in
            if let self, abs(self.zoomNow - zoom) > 0.0005 { self.zoomNow = zoom }
        }
        smudgeRelay = Relay { [weak self] smudged in self?.state.lensSmudged = smudged }
        readingsWatch = ReadingsWatch { [weak self] readings in
            if self?.readings != readings { self?.readings = readings }
        }
        let scopesRelay = Relay<LiveScopesData?> { [weak self] scopes in
            if self?.liveScopes != scopes { self?.liveScopes = scopes }
        }
        self.scopesRelay = scopesRelay
        core.scopesChanged = { scopes in scopesRelay.send(scopes) }
        let pipRelay = Relay<UIImage?> { [weak self] image in
            self?.dualPipImage = image
        }
        self.pipRelay = pipRelay
        multiCam.onPipImage = { image in pipRelay.send(image) }
        let sampleRelay = Relay<CGImage> { [weak self] image in self?.lookSample = image }
        self.sampleRelay = sampleRelay
        core.lookSampled = { image in sampleRelay.send(image) }
    }

    static var allowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    func prepare(mode: CameraMode, options video: CaptureOptions) {
        self.mode = mode
        self.video = video
        guard Self.allowed else { return }
        configureOnce()
    }

    private func configureOnce() {
        guard !configured else { return }
        configured = true
        let (mode, video) = (mode, video)
        core.run { $0.configure(side: .back, mode: mode, video: video) }
    }

    func start() {
        Task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .video) else { return denied() }
            default:
                return denied()
            }
            // Live Photos have sound, like videos.
            if video?.live == true, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                if await AVCaptureDevice.requestAccess(for: .audio), let video {
                    let mode = mode
                    core.run { $0.change(mode: mode, video: video) }
                }
            }
            configureOnce()
            let started = ContinuousClock.now
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                core.run { core in
                    core.startRunning()
                    core.waitForFirstFrame { done.resume() }
                }
            }
            CameraTimingLog.shared.record(.open, milliseconds: started.duration(to: .now).milliseconds)
        }
    }

    private func denied() {
        state.problem = "Halden may not use the camera. Allow it in Settings › Halden."
    }

    func stop() {
        multiCam.stop()
        core.run { $0.stopRunning() }
    }

    func setMode(_ mode: CameraMode, options video: CaptureOptions) async {
        let wasDual = self.mode == .dual
        self.mode = mode
        self.video = video
        // Sound for videos, Cinematic, Spatial and Live Photos; without the microphone they are silent.
        let sound =
            mode == .video || mode == .cinematic || mode == .slowMotion || mode == .spatial
            || (mode == .photo && video.live)
        if sound, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if mode == .dual && MultiCamEngine.isSupported {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                core.run { core in
                    core.prepareForMultiCam(video: video)
                    done.resume()
                }
            }
            preview.setMetalActive(true)
            state.customPreviewActive = true
            state.canMultiCam = true
            state.videoFormat = nil
            state.presets = dualSwapped ? [1] : [1, 2]
            state.zoomRange = dualSwapped ? 1...1 : 1...5
            zoomNow = 1
            multiCam.start(swapped: dualSwapped, corner: dualCorner)
            return
        }
        if wasDual {
            multiCam.stop()
            dualPipImage = nil
            core.run { $0.startRunning() }
        }
        reconfigurations += 1
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            core.run { core in
                core.change(mode: mode, video: video)
                core.waitForFirstFrame { done.resume() }
            }
        }
    }

    func applyLook(_ options: CaptureOptions) {
        video = options
        guard mode != .dual else { return }
        let started = ContinuousClock.now
        let measure = mode.isStill
        core.run { core in
            core.applyLook(options)
            guard measure else { return }
            core.waitForFirstFrame {
                CameraTimingLog.shared.record(.look, milliseconds: started.duration(to: .now).milliseconds)
            }
        }
    }

    func applyDevice(_ options: CaptureOptions) {
        video = options
        guard mode != .dual else { return }
        core.run { $0.applyDevice(options) }
    }

    func sampleLooks(_ on: Bool) {
        core.sampleLooks(on)
        if !on { lookSample = nil }
    }

    func flip() async {
        let side: CameraSide = state.side == .back ? .front : .back
        let (mode, video) = (mode, video)
        reconfigurations += 1
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            core.run { core in
                core.configure(side: side, mode: mode, video: video)
                core.waitForFirstFrame { done.resume() }
            }
        }
    }

    /// The zoom shown follows the camera itself (see `update`), so it moves along with a glide
    /// instead of jumping to where it is going.
    func zoom(to factor: Double, glide: Bool) {
        if mode == .dual {
            let clamped = min(max(factor, state.zoomRange.lowerBound), state.zoomRange.upperBound)
            zoomNow = clamped
            multiCam.zoom(to: clamped, glide: glide)
            return
        }
        core.run { $0.zoom(to: factor, glide: glide) }
    }

    func focus(at point: CGPoint, lock: Bool) {
        let devicePoint = preview.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        core.run { $0.focus(at: devicePoint, lock: lock) }
    }

    func setTorch(_ on: Bool) {
        core.run { $0.torch(on) }
    }

    func setManual(_ settings: ManualSettings) {
        core.run { $0.manual(settings) }
    }

    /// Which way is up for what is recorded now (the screen stays upright, the phone may not).
    private var captureAngle: CGFloat {
        rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
    }

    func takePhoto(_ request: PhotoRequest, preview: (@Sendable (CGImage) -> Void)?) async -> TakenPhoto? {
        let angle = captureAngle
        return await withCheckedContinuation { continuation in
            core.run {
                $0.takePhoto(request, angle: angle, preview: preview) { continuation.resume(returning: $0) }
            }
        }
    }

    func takeNightBurst(
        count: Int, request: PhotoRequest, onFrame: @MainActor @escaping (Int, Int) -> Void
    ) async -> [Data] {
        var fast = request
        fast.live = false
        fast.raw = false
        fast.flash = .off
        fast.prioritizeFaster = true
        fast.captureDepth = false
        fast.capturePortraitMatte = false
        fast.prioritizeFastest = true
        let total = max(1, count)
        let angle = captureAngle
        let request = fast
        // All frames asked for at once: the camera takes them back to back instead of waiting for
        // each one to be processed before starting the next.
        return await withCheckedContinuation { (continuation: CheckedContinuation<[Data], Never>) in
            let collector = FrameCollector(total: total) { done in
                Task { @MainActor in onFrame(done, total) }
            } finished: { frames in
                continuation.resume(returning: frames)
            }
            core.run { core in
                for index in 0..<total {
                    core.takePhoto(request, angle: angle) { photo in collector.add(index, photo?.data) }
                }
            }
        }
    }

    func takeStillWhileRecording(_ request: PhotoRequest) async -> TakenPhoto? {
        let angle = captureAngle
        return await withCheckedContinuation { continuation in
            core.run { $0.takeStillWhileRecording(request, angle: angle) { continuation.resume(returning: $0) } }
        }
    }

    func startRecording(_ request: VideoRequest) -> Bool {
        guard state.ready else { return false }
        let angle = captureAngle
        core.run { $0.startRecording(request, angle: angle) }
        return true
    }

    func startQuickTake(_ request: VideoRequest) -> Bool {
        guard state.ready else { return false }
        let angle = captureAngle
        core.run { $0.startQuickTake(request, angle: angle) }
        return true
    }

    func pauseRecording() {
        core.run { $0.pauseRecording() }
    }

    func resumeRecording() {
        core.run { $0.resumeRecording() }
    }

    func stopRecording() async -> URL? {
        if dualRecording {
            dualRecording = false
            return await withCheckedContinuation { continuation in
                multiCam.stopRecording { continuation.resume(returning: $0) }
            }
        }
        let (url, plan): (URL?, TimeLapsePlan?) = await withCheckedContinuation { continuation in
            core.run { $0.stopRecording { url, plan in continuation.resume(returning: (url, plan)) } }
        }
        guard let url else { return nil }
        if let plan, plan.stretches.count > 1 { return await Self.evenOut(url, plan) ?? url }
        return url
    }

    func takeDualPhoto(_ request: PhotoRequest, corner: PiPCorner, swapped: Bool) async -> TakenPhoto? {
        guard mode == .dual else { return nil }
        return await withCheckedContinuation { continuation in
            multiCam.takePhoto(request: request, corner: corner, swapped: swapped) {
                continuation.resume(returning: $0)
            }
        }
    }

    func startDualRecording(_ request: VideoRequest, corner: PiPCorner, swapped: Bool) -> Bool {
        guard mode == .dual, !dualRecording else { return false }
        dualRecording = multiCam.startRecording(request: request, corner: corner, swapped: swapped)
        return dualRecording
    }

    func updateDualLayout(corner: PiPCorner, swapped: Bool) {
        dualCorner = corner
        dualSwapped = swapped
        if mode == .dual {
            state.presets = swapped ? [1] : [1, 2]
            state.zoomRange = swapped ? 1...1 : 1...5
            zoomNow = 1
        }
        multiCam.updateLayout(swapped: swapped, corner: corner)
    }

    func setWatchFrameHandler(_ handler: (@Sendable (Data) -> Void)?) {
        let isDual = mode == .dual
        core.run { $0.setWatchFrameHandler(handler, dualActive: isDual) }
    }

    func startPanorama(direction: PanoramaDirection) -> Bool {
        guard state.ready else { return false }
        let angle = captureAngle
        core.run { $0.startPanorama(direction: direction, angle: angle) }
        return true
    }

    func stopPanorama(request: PhotoRequest) async -> TakenPhoto? {
        await withCheckedContinuation { continuation in
            core.run { $0.stopPanorama(request: request) { continuation.resume(returning: $0) } }
        }
    }

    /// A time-lapse whose first stretches were taken more often: played faster, so the whole
    /// video runs at one speed (written anew, with the same place and time).
    private static func evenOut(_ url: URL, _ plan: TimeLapsePlan) async -> URL? {
        let asset = AVURLAsset(url: url)
        let even = url.deletingPathExtension().appendingPathExtension("even.mov")
        do {
            let composition = try await Retiming.timeLapse(asset, stretches: plan.speedUps, frameRate: 30)
            try await Retiming.export(composition, to: even, metadataOf: asset)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: even, to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: even)
            return nil
        }
    }

    private func update(_ new: CameraState, device: AVCaptureDevice?) {
        var new = new
        // The smudge status comes from KVO on the device; a state sent without a new device is older.
        if device == nil { new.lensSmudged = state.lensSmudged }
        if new.ready, new.side == .back { Self.rememberCapabilities(new.capabilities) }
        // Only a real change redraws what reads the state.
        if state != new { state = new }
        preview.setMetalActive(new.customPreviewActive)
        guard let device, device !== rotation?.device else { return }
        if let zoomRelay { zoomObservation = Self.follow(zoomOf: device, into: zoomRelay) }
        if let smudgeRelay { smudgeObservation = Self.follow(smudgeOf: device, into: smudgeRelay) }
        readingsWatch?.watch(device)
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview.previewLayer)
        rotation = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                guard let connection = self?.preview.previewLayer.connection,
                    connection.isVideoRotationAngleSupported(angle)
                else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    /// Sends the zoom as shown (0.5, 1, 2, …) whenever the camera's zoom changes: every frame of
    /// a glide, on whichever thread the camera changes it (so not isolated to the main actor).
    /// What the back camera can do, for Settings before the camera opens.
    private static var remembered: DeviceCapabilities?
    private static func rememberCapabilities(_ capabilities: DeviceCapabilities) {
        guard remembered != capabilities else { return }
        remembered = capabilities
        CapabilityCache().save(capabilities)
    }

    nonisolated private static func follow(zoomOf device: AVCaptureDevice, into relay: Relay<Double>)
        -> NSKeyValueObservation
    {
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        return device.observe(\.videoZoomFactor, options: [.initial, .new]) { @Sendable device, change in
            relay.send(Double(change.newValue ?? device.videoZoomFactor) * multiplier)
        }
    }

    nonisolated private static func follow(smudgeOf device: AVCaptureDevice, into relay: Relay<Bool>)
        -> NSKeyValueObservation
    {
        device.observe(\.cameraLensSmudgeDetectionStatus, options: [.initial, .new]) { @Sendable device, change in
            let status = change.newValue ?? device.cameraLensSmudgeDetectionStatus
            relay.send(status == .smudged)
        }
    }
}

/// Carries something that isn't marked `Sendable` from the camera's queue to the main thread,
/// where it is only read.
struct Carry<Value>: @unchecked Sendable {
    let value: Value
}

/// Hands values that come fast, from any thread, to the main thread: only the newest one, at
/// most once per turn of the main thread.
final class Relay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Value?
    private let deliver: @MainActor (Value) -> Void

    init(_ deliver: @escaping @MainActor (Value) -> Void) {
        self.deliver = deliver
    }

    func send(_ value: Value) {
        let waiting = lock.withLock {
            defer { latest = value }
            return latest != nil
        }
        guard !waiting else { return }
        Task { @MainActor in
            let value = self.lock.withLock {
                defer { self.latest = nil }
                return self.latest
            }
            if let value { self.deliver(value) }
        }
    }
}

/// Gathers the frames of a Night Mode series as they come, in the order they were asked for.
final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private var frames: [Int: Data] = [:]
    private var done = 0
    private let progress: @Sendable (Int) -> Void
    private let finished: @Sendable ([Data]) -> Void

    init(
        total: Int, progress: @escaping @Sendable (Int) -> Void, finished: @escaping @Sendable ([Data]) -> Void
    ) {
        self.total = total
        self.progress = progress
        self.finished = finished
    }

    func add(_ index: Int, _ data: Data?) {
        let (count, all): (Int, [Data]?) = lock.withLock {
            done += 1
            if let data { frames[index] = data }
            let all = done == total ? frames.sorted { $0.key < $1.key }.map(\.value) : nil
            return (done, all)
        }
        progress(count)
        if let all { finished(all) }
    }
}

/// Runs its work the first time it is asked to, never again (for whichever comes first: the
/// awaited event or its time-out).
final class RunOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var work: (@Sendable () -> Void)?

    init(_ work: @escaping @Sendable () -> Void) {
        self.work = work
    }

    func run() {
        let pending: (@Sendable () -> Void)? = lock.withLock {
            defer { work = nil }
            return work
        }
        pending?()
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}

/// Everything that touches AVFoundation. Only ever used on `queue` (that is what makes the
/// `@unchecked Sendable` true).
final class CaptureCore: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.camera", qos: .userInitiated)
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    /// Time-lapses: the frames, of which `timeLapse` keeps a few.
    private let frameOutput = AVCaptureVideoDataOutput()
    /// Custom Metal preview output: attached only when a style, filter, portrait or scopes need GPU rendering.
    /// Preview-sized frames for the custom viewfinder (looks, portrait, scopes), Live Text and the
    /// filter buttons. Always attached in Photo and Portrait, so a filter never rebuilds the session.
    private let previewOutput = AVCaptureVideoDataOutput()
    /// Depth map stream for live Portrait bokeh preview.
    private let depthOutput = AVCaptureDepthDataOutput()
    /// People, faces, dogs & cats detection for automatic depth capture in Photo mode.
    private let metadataOutput = AVCaptureMetadataOutput()
    private var depthSynchronizer: AVCaptureDataOutputSynchronizer?
    private let metalView: MetalPreviewView
    private let previewRelay: PreviewFrameRelay
    private let subjectRelay = SubjectMetadataRelay()
    private let timeLapse = TimeLapseRecorder()
    private var timeLapsing = false
    private let panoramaCollector = PanoramaCollector()
    private var panoramaCapturing = false
    private var lockedForPanorama = false
    private let textDetector = ViewfinderTextDetector()
    /// Values set by hand, applied to every camera and mode.
    private var manual = ManualSettings()
    private var input: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var mode = CameraMode.photo
    private var video: CaptureOptions?
    private var side = CameraSide.back
    private var state = CameraState()
    private var photos: [Int64: PhotoCapture] = [:]
    private var recording: Recording?
    private var quickTaking = false
    private var lockedSwitchingForRecording = false
    private var lockedWhiteBalanceForRecording = false
    private var wantRunning = false
    private var observers: [NSObjectProtocol] = []
    private var activeExternalURL: URL?
    private let controlsRelay = CameraControlsRelay()
    /// Called when the iPhone 16+ Camera Control style picker changes the active Photographic Style.
    var onControlStyleChanged: (@Sendable (PhotographicStyle?) -> Void)?
    /// Gets every new state (and the camera, when it changed).
    var changed: (@Sendable (CameraState, Carry<AVCaptureDevice>?) -> Void)?
    /// Delivers throttled live histogram/waveform snapshots when enabled.
    var scopesChanged: (@Sendable (LiveScopesData?) -> Void)?
    private let scopeLock = NSLock()
    private var lastScopeTime: Double = 0
    private var watchFrameHandler: (@Sendable (Data) -> Void)?
    private let watchContext = CIContext(options: [.cacheIntermediates: false])
    private let watchLock = NSLock()
    private var lastWatchTime: Double = 0
    /// Gets the small picture for the filter buttons.
    var lookSampled: (@Sendable (CGImage) -> Void)?
    /// The audio session as last set up (`nil` before the camera first ran): set only when it changes.
    private var audioSessionSetup: String?
    /// Facts about a camera that never change (its formats), found once per camera.
    private var facts: [String: CameraFacts] = [:]
    private static let profile = DeviceProfile.named(DeviceProfile.currentIdentifier)

    /// What `describe` would otherwise search all formats for every time.
    struct CameraFacts {
        var canFlip: Bool
        var canCinematic: Bool
        var canSpatialVideo: Bool
        var canAppleLog: Bool
        var canActionMode: Bool
        var canMacro: Bool
        var canBayerRAW: Bool
        var kelvin: ClosedRange<Double>
    }

    init(metalView: MetalPreviewView) {
        self.metalView = metalView
        self.previewRelay = PreviewFrameRelay(metalView: metalView)
        super.init()
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.setSampleBufferDelegate(timeLapse, queue: timeLapse.queue)
        previewOutput.alwaysDiscardsLateVideoFrames = true
        previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // About screen size in every format (not 4K frames in video modes): less to draw, quicker focus.
        previewOutput.automaticallyConfiguresOutputBufferDimensions = false
        previewOutput.deliversPreviewSizedOutputBuffers = true
        previewOutput.setSampleBufferDelegate(previewRelay, queue: previewRelay.queue)
        previewRelay.textDetector = textDetector
        previewRelay.lookSampled = { [weak self] image in self?.lookSampled?(image) }
        depthOutput.isFilteringEnabled = true
        subjectRelay.onDetect = { [weak self] detected in
            self?.run { core in
                guard core.state.subjectDetected != detected else { return }
                core.state.subjectDetected = detected
                core.publish(device: nil)
            }
        }
        subjectRelay.onQRCode = { [weak self] code in
            self?.run { core in
                let effective = core.mode == .photo && core.video?.scanQRCodes != false ? code : nil
                guard core.state.detectedQR != effective else { return }
                core.state.detectedQR = effective
                core.publish(device: nil)
            }
        }
        textDetector.onText = { [weak self] text in
            self?.run { core in
                let effective = core.mode == .photo && core.video?.showLiveText != false ? text : nil
                guard core.state.detectedText != effective else { return }
                core.state.detectedText = effective
                core.publish(device: nil)
            }
        }
        metadataOutput.setMetadataObjectsDelegate(subjectRelay, queue: subjectRelay.queue)
        controlsRelay.onFullscreenChanged = { [weak self] fullscreen in
            self?.run { core in
                guard core.state.controlsFullscreen != fullscreen else { return }
                core.state.controlsFullscreen = fullscreen
                core.publish(device: nil)
            }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { [weak self] _ in
                // After the media services restarted, for example: start again.
                self?.run { core in
                    if core.wantRunning && !core.session.isRunning { core.session.startRunning() }
                }
            })
    }

    func run(_ work: @escaping @Sendable (CaptureCore) -> Void) {
        queue.async { work(self) }
    }

    private var device: AVCaptureDevice? { input?.device }

    static func supportsBackBayerRAW() -> Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    /// The back camera with the most lenses there are, or the front camera. For slow motion the
    /// first that can record that fast (not every camera made of several lenses can). For Bayer RAW
    /// in Photo mode, the physical wide sensor is required because virtual fusion cameras only expose
    /// Apple ProRAW.
    static func camera(_ side: CameraSide, mode: CameraMode = .photo, options: CaptureOptions? = nil)
        -> AVCaptureDevice?
    {
        if mode == .photo, side == .back, options?.captureRAW == true, options?.captureProRAW != true,
            let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        {
            return wide
        }
        let types: [AVCaptureDevice.DeviceType] =
            side == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let devices = types.compactMap {
            AVCaptureDevice.default($0, for: .video, position: side == .back ? .back : .front)
        }
        if mode == .slowMotion {
            let wanted = Double(min(options?.slowMotionRate ?? 240, 120))
            if let fast = devices.first(where: { device in
                device.formats.contains { format in
                    let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return size.width == 1920 && size.height == 1080
                        && (format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) >= wanted
                }
            }) {
                return fast
            }
        }
        return devices.first
    }

    func configure(side: CameraSide, mode: CameraMode, video: CaptureOptions?) {
        self.side = side
        self.mode = mode
        self.video = video
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        input = nil
        guard let device = Self.camera(side, mode: mode, options: video),
            let newInput = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(newInput)
        else {
            session.commitConfiguration()
            state.ready = false
            state.problem = "There is no camera here."
            publish(device: nil)
            return
        }
        session.addInput(newInput)
        input = newInput
        apply(mode: mode, on: device)
        configureSessionControls(on: device)
        session.commitConfiguration()
        prepare(device)
        state = describe(device)
        publish(device: device)
    }

    func change(mode: CameraMode, video: CaptureOptions) {
        guard let device, !movieOutput.isRecording, !timeLapsing else { return }
        // Slow motion may need another camera than the others.
        if Self.camera(side, mode: mode, options: video) != device {
            return configure(side: side, mode: mode, video: video)
        }
        self.mode = mode
        self.video = video
        session.beginConfiguration()
        apply(mode: mode, on: device)
        session.commitConfiguration()
        // Another format has other limits.
        applyManual(on: device)
        state = describe(device)
        publish(device: nil)
    }

    func prepareForMultiCam(video: CaptureOptions?) {
        self.mode = .dual
        self.video = video
        if session.isRunning { session.stopRunning() }
        if !wantsScopes { scopesChanged?(nil) }
        metalView.configure(
            style: nil, filter: nil, portraitAperture: nil, portraitLighting: nil,
            frameObserver: makeFrameObserver())
    }

    func startRunning() {
        wantRunning = true
        if audioSessionSetup == nil {
            // Only now that the camera opens (not at app start, which would interrupt music).
            configureAudioSession(
                allowPlayback: video?.allowAudioPlayback == true, allowAirPodsMic: video?.allowAirPodsMic == true,
                needsAudio: mode != .timeLapse)
        }
        if !session.isRunning { session.startRunning() }
    }

    /// Calls `done` (on the camera's queue) once the next picture arrives, so a switch ends when
    /// the new picture is there and not after a fixed time. Without frames to watch, a moment later.
    func waitForFirstFrame(_ done: @escaping @Sendable () -> Void) {
        guard session.isRunning, session.outputs.contains(previewOutput) else {
            queue.asyncAfter(deadline: .now() + 0.06) { done() }
            return
        }
        let once = RunOnce(done)
        previewRelay.whenNextFrame { [weak self] in self?.queue.async { once.run() } }
        // Never longer than this, whatever happens.
        queue.asyncAfter(deadline: .now() + 0.8) { once.run() }
    }

    /// The small live picture for the filter buttons, five times a second while on.
    func sampleLooks(_ on: Bool) {
        previewRelay.setSampling(on)
    }

    /// Only how the picture looks: drawn into the next frame, nothing rebuilt.
    func applyLook(_ options: CaptureOptions) {
        video = options
        configureLook()
        let custom = needsMetalPreview && session.outputs.contains(previewOutput)
        guard custom != state.customPreviewActive else { return }
        state.customPreviewActive = custom
        publish(device: nil)
    }

    /// Settings the camera takes on the fly: lens correction and macro, what it looks for (faces,
    /// QR codes, text), mirroring, the Cinematic aperture and wind noise removal.
    func applyDevice(_ options: CaptureOptions) {
        video = options
        guard let device else { return }
        applyComposition(on: device)
        configureSubjectMetadata()
        previewRelay.setTextDetection(mode == .photo && options.showLiveText)
        if !options.showLiveText, state.detectedText != nil { state.detectedText = nil }
        if let connection = previewOutput.connection(with: .video) {
            applyMirroring(on: connection, mirror: side == .front)
        }
        if let audioInput, audioInput.isWindNoiseRemovalSupported {
            let wanted = options.windNoiseRemoval && audioInput.multichannelAudioMode != .none
            if audioInput.isWindNoiseRemovalEnabled != wanted { audioInput.isWindNoiseRemovalEnabled = wanted }
        }
        if mode == .cinematic, let input, input.isCinematicVideoCaptureEnabled {
            let format = device.activeFormat
            let aperture = CinematicRules.clampedAperture(
                options.cinematicAperture, min: Double(max(format.minSimulatedAperture, 2.0)),
                max: Double(max(format.maxSimulatedAperture, 2.0)))
            input.simulatedAperture = Float(aperture)
            state.videoFormat = "Cinematic · \(CinematicRules.formatAperture(aperture))"
        }
        state = describe(device)
        publish(device: nil)
    }

    /// The look the custom viewfinder draws (none in video modes).
    private func configureLook() {
        metalView.configure(
            style: mode.isStill ? video?.style : nil, filter: mode.isStill ? video?.filter : nil,
            filterIntensity: video?.filterIntensity ?? 1,
            portraitAperture: mode == .portrait ? (video?.portraitAperture ?? PortraitMath.defaultAperture) : nil,
            portraitLighting: mode == .portrait ? video?.portraitLighting : nil,
            frameObserver: makeFrameObserver())
    }

    func stopRunning() {
        wantRunning = false
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if timeLapsing {
            timeLapsing = false
            timeLapse.finish { _, _ in }
        }
        if panoramaCapturing {
            panoramaCapturing = false
            panoramaCollector.cancel()
            unlockAfterPanorama()
        }
        unlockAfterRecording()
        if session.isRunning { session.stopRunning() }
    }

    private func publish(device: AVCaptureDevice?) {
        changed?(state, device.map(Carry.init))
    }

    /// Keeps exactly these outputs in the session. Live Photos and `movieOutput` must never be
    /// active together; in photo mode only `photoOutput` (plus `previewOutput` when a look needs
    /// Metal rendering) is attached, while in video mode Live Photos are off so `movieOutput` and
    /// `photoOutput` coexist for photo-while-recording.
    private func use(_ outputs: [AVCaptureOutput]) {
        depthSynchronizer = nil
        for candidate in [photoOutput, movieOutput, frameOutput, previewOutput, depthOutput, metadataOutput]
            as [AVCaptureOutput]
        {
            if !outputs.contains(where: { $0 === candidate }), session.outputs.contains(candidate) {
                session.removeOutput(candidate)
            }
        }
        for output in outputs {
            if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        }
    }

    private var wantsScopes: Bool {
        mode != .timeLapse && mode != .panorama && (video?.showHistogram == true || video?.showWaveform == true)
    }

    /// Photo and Portrait always have the preview frames (looks, Live Text, the filter buttons);
    /// other modes only for scopes or the Apple Watch.
    private var wantsPreviewFrames: Bool {
        mode.isStill || needsMetalPreview || watchFrameHandler != nil
    }

    private var isBayerRAWActive: Bool {
        mode == .photo && video?.captureRAW == true
            && !(video?.captureProRAW == true && photoOutput.isAppleProRAWSupported)
            && availableBayerRAW() != nil
    }

    private var needsMetalPreview: Bool {
        if wantsScopes { return true }
        guard mode.isStill else { return false }
        let filter = (video?.filterIntensity ?? 1) > 0.005 ? video?.filter : nil
        return LookRenderer.needsCustomPreview(style: video?.style, filter: filter, isPortrait: mode == .portrait)
    }

    private func sampleScopes(_ image: CIImage) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldRun = scopeLock.withLock { () -> Bool in
            guard now - lastScopeTime >= 0.12 else { return false }
            lastScopeTime = now
            return true
        }
        guard shouldRun else { return }
        let data = LiveScopesAnalyzer.analyze(image)
        scopesChanged?(data)
    }

    private func sampleWatchFrame(_ image: CIImage, handler: @Sendable (Data) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldRun = watchLock.withLock { () -> Bool in
            guard now - lastWatchTime >= 0.125 else { return false }
            lastWatchTime = now
            return true
        }
        guard shouldRun else { return }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(1.0, 240.0 / max(extent.width, extent.height))
        let scaled =
            scale < 1.0 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        guard let cg = watchContext.createCGImage(scaled, from: scaled.extent.integral),
            let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.45)
        else { return }
        handler(jpeg)
    }

    func makeFrameObserver() -> (@Sendable (CIImage) -> Void)? {
        let scopes = wantsScopes
        let watch = watchFrameHandler
        guard scopes || watch != nil else { return nil }
        return { [weak self] frame in
            guard let self else { return }
            if scopes { self.sampleScopes(frame) }
            if let watch { self.sampleWatchFrame(frame, handler: watch) }
        }
    }

    func setWatchFrameHandler(_ handler: (@Sendable (Data) -> Void)?, dualActive: Bool) {
        let hadHandler = watchFrameHandler != nil
        watchFrameHandler = handler
        if dualActive {
            metalView.configure(
                style: nil, filter: nil, portraitAperture: nil, portraitLighting: nil,
                frameObserver: makeFrameObserver())
            return
        }
        configureLook()
        let hasHandler = handler != nil
        guard hadHandler != hasHandler, let device, !movieOutput.isRecording, !timeLapsing, !panoramaCapturing else {
            return
        }
        if mode != .timeLapse && mode != .panorama {
            session.beginConfiguration()
            apply(mode: mode, on: device)
            session.commitConfiguration()
            state = describe(device)
            publish(device: nil)
        }
    }

    /// Photo: the photo output in the chosen resolution and prioritization (no movie output so
    /// Live Photos work), plus metadata detection for automatic depth on people/pets.
    /// Portrait: photo + Metal preview (+ synchronized depth when supported).
    /// Cinematic: iOS 26 `isCinematicVideoCaptureEnabled` + required metadata output.
    /// Video: movie + photo output (Live Photos off) for photo-while-recording, Action Mode & audio.
    private func apply(mode: CameraMode, on device: AVCaptureDevice) {
        if session.automaticallyConfiguresCaptureDeviceForWideColor != mode.isStill {
            session.automaticallyConfiguresCaptureDeviceForWideColor = mode.isStill
        }
        if mode != .cinematic, let input, input.isCinematicVideoCaptureEnabled {
            input.isCinematicVideoCaptureEnabled = false
        }
        if audioSessionSetup != nil {
            configureAudioSession(
                allowPlayback: video?.allowAudioPlayback == true,
                allowAirPodsMic: video?.allowAirPodsMic == true,
                needsAudio: mode != .timeLapse)
        }
        if !wantsScopes { scopesChanged?(nil) }
        configureLook()
        previewRelay.setTextDetection(mode == .photo && video?.showLiveText != false)
        if mode != .photo || video?.showLiveText == false { state.detectedText = nil }
        switch mode {
        case .photo:
            // Live Text reads the preview frames: no extra full-size output.
            use([photoOutput, metadataOutput, previewOutput])
            configureSubjectMetadata()
            if let connection = previewOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                applyMirroring(on: connection, mirror: side == .front)
                previewOutput.setSampleBufferDelegate(previewRelay, queue: previewRelay.queue)
            }
            // Live Photos record sound (unless Bayer RAW or Apple ProRAW is active).
            let proRAW = video?.captureProRAW == true && photoOutput.isAppleProRAWSupported
            let raw = !proRAW && video?.captureRAW == true && availableBayerRAW() != nil
            let live = video?.live == true && !raw && !proRAW
            if live {
                addMicrophone()
            } else if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if session.sessionPreset != .photo, session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            if raw, (try? device.lockForConfiguration()) != nil {
                device.videoZoomFactor = 1.0
                device.unlockForConfiguration()
            }
            // Every one of these may rebuild the camera's pipeline, so each is set only when it changes.
            let faster = video?.prioritizeFasterShooting ?? true
            let priority: AVCapturePhotoOutput.QualityPrioritization = faster ? .balanced : .quality
            if photoOutput.maxPhotoQualityPrioritization != priority {
                photoOutput.maxPhotoQualityPrioritization = priority
            }
            let supported = device.activeFormat.supportedMaxPhotoDimensions
            let tuples = supported.map { (width: Int($0.width), height: Int($0.height)) }
            let available = PhotoResolution.available(for: tuples)
            let wanted: PhotoResolution =
                raw ? .mp12 : PhotoResolution.fitted(video?.photoResolution ?? .mp24, in: available)
            let dimensions: CMVideoDimensions? =
                if let index = PhotoResolution.bestDimensionIndex(wanted: wanted, in: tuples) {
                    supported[index]
                } else {
                    supported.max(by: { $0.width * $0.height < $1.width * $1.height })
                }
            if let dimensions,
                photoOutput.maxPhotoDimensions.width != dimensions.width
                    || photoOutput.maxPhotoDimensions.height != dimensions.height
            {
                photoOutput.maxPhotoDimensions = dimensions
            }
            if photoOutput.isResponsiveCaptureSupported, photoOutput.isResponsiveCaptureEnabled != faster {
                photoOutput.isResponsiveCaptureEnabled = faster
            }
            if photoOutput.isFastCapturePrioritizationSupported,
                photoOutput.isFastCapturePrioritizationEnabled != faster
            {
                photoOutput.isFastCapturePrioritizationEnabled = faster
            }
            if photoOutput.isAppleProRAWSupported, photoOutput.isAppleProRAWEnabled != proRAW {
                photoOutput.isAppleProRAWEnabled = proRAW
            }
            let depth =
                video?.autoDepth != false && !raw && !proRAW && photoOutput.isDepthDataDeliverySupported
            if photoOutput.isDepthDataDeliveryEnabled != depth { photoOutput.isDepthDataDeliveryEnabled = depth }
            let matte = depth && photoOutput.isPortraitEffectsMatteDeliverySupported
            if photoOutput.isPortraitEffectsMatteDeliveryEnabled != matte {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = matte
            }
            let liveOn = live && photoOutput.isLivePhotoCaptureSupported
            if photoOutput.isLivePhotoCaptureEnabled != liveOn { photoOutput.isLivePhotoCaptureEnabled = liveOn }
            if liveOn, !photoOutput.isLivePhotoAutoTrimmingEnabled { photoOutput.isLivePhotoAutoTrimmingEnabled = true }
            state.videoFormat = nil
        case .portrait:
            var outputs: [AVCaptureOutput] = [photoOutput, previewOutput, metadataOutput]
            let canStreamDepth = !device.activeFormat.supportedDepthDataFormats.isEmpty
            if canStreamDepth { outputs.append(depthOutput) }
            use(outputs)
            configureSubjectMetadata()
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if session.sessionPreset != .photo, session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            if photoOutput.isLivePhotoCaptureEnabled { photoOutput.isLivePhotoCaptureEnabled = false }
            if photoOutput.isDepthDataDeliveryEnabled != photoOutput.isDepthDataDeliverySupported {
                photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
            }
            let matte = photoOutput.isDepthDataDeliveryEnabled && photoOutput.isPortraitEffectsMatteDeliverySupported
            if photoOutput.isPortraitEffectsMatteDeliveryEnabled != matte {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = matte
            }
            if let connection = previewOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                applyMirroring(on: connection, mirror: side == .front)
            }
            if canStreamDepth, session.outputs.contains(depthOutput),
                let depthConnection = depthOutput.connection(with: .depthData)
            {
                if depthConnection.isVideoRotationAngleSupported(90) { depthConnection.videoRotationAngle = 90 }
                if depthConnection.isVideoMirroringSupported { depthConnection.isVideoMirrored = side == .front }
                let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [previewOutput, depthOutput])
                sync.setDelegate(previewRelay, queue: previewRelay.queue)
                depthSynchronizer = sync
            } else {
                previewOutput.setSampleBufferDelegate(previewRelay, queue: previewRelay.queue)
            }
            state.videoFormat = nil
        case .video, .cinematic, .slowMotion, .spatial:
            // Disable Live Photos before adding `movieOutput`, then keep `photoOutput` attached in
            // `.video` mode so users can snap still photos while recording.
            if photoOutput.isLivePhotoCaptureEnabled { photoOutput.isLivePhotoCaptureEnabled = false }
            var outputs: [AVCaptureOutput] =
                switch mode {
                case .video: [movieOutput, photoOutput]
                case .cinematic: [movieOutput, metadataOutput]
                default: [movieOutput]
                }
            if wantsPreviewFrames { outputs.append(previewOutput) }
            use(outputs)
            addMicrophone()
            configureAudioInput()
            var wantedProFormat = ProVideoFormat.standard
            if let video {
                if mode == .slowMotion {
                    applyVideoFormat(
                        sizes: [(1920, 1080)], rate: Double(video.slowMotionRate), hdr: false,
                        autoLowLightFPS: false, appleLog: false, on: device)
                } else if mode == .cinematic {
                    applyCinematicFormat(video: video, on: device)
                } else if mode == .spatial {
                    applySpatialVideoFormat(on: device)
                } else {
                    let canProRes = movieOutput.availableVideoCodecTypes.contains(.proRes422)
                    let canLog = device.formats.contains { $0.supportedColorSpaces.contains(.appleLog) }
                    wantedProFormat = ProDeviceRules.effectiveVideoFormat(
                        wanted: video.proVideoFormat,
                        capabilities: DeviceCapabilities(canProRes: canProRes, canAppleLog: canLog))
                    applyVideoFormat(
                        sizes: video.resolution == .uhd4K ? [(3840, 2160), (1920, 1080)] : [(1920, 1080)],
                        rate: Double(video.frameRate), hdr: video.hdr && wantedProFormat != .proResLog,
                        autoLowLightFPS: video.autoLowLightFPS, appleLog: wantedProFormat == .proResLog,
                        on: device)
                    if wantedProFormat == .proRes, let base = state.videoFormat {
                        state.videoFormat = "\(base) · ProRes"
                    } else if wantedProFormat == .proResLog, let base = state.videoFormat {
                        state.videoFormat = "\(base) · ProRes Log"
                    }
                    if video.actionMode,
                        device.activeFormat.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced),
                        let base = state.videoFormat
                    {
                        state.videoFormat = "\(base) · Action"
                    }
                }
            }
            if wantsPreviewFrames, let connection = previewOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                applyMirroring(on: connection, mirror: side == .front)
                previewOutput.setSampleBufferDelegate(previewRelay, queue: previewRelay.queue)
            }
            if mode == .video,
                let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                    $0.width * $0.height < $1.width * $1.height
                }),
                photoOutput.maxPhotoDimensions.width != largest.width
                    || photoOutput.maxPhotoDimensions.height != largest.height
            {
                photoOutput.maxPhotoDimensions = largest
            }
            if movieOutput.isSpatialVideoCaptureSupported {
                movieOutput.isSpatialVideoCaptureEnabled = mode == .spatial
            }
            if let connection = movieOutput.connection(with: .video) {
                if mode == .video && wantedProFormat != .standard
                    && movieOutput.availableVideoCodecTypes.contains(.proRes422)
                {
                    movieOutput.setOutputSettings(
                        [AVVideoCodecKey: AVVideoCodecType.proRes422], for: connection)
                } else if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                }
                if connection.isVideoStabilizationSupported {
                    let action =
                        mode == .video && video?.actionMode == true
                        && device.activeFormat.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced)
                    let wanted: AVCaptureVideoStabilizationMode = action ? .cinematicExtendedEnhanced : .auto
                    if connection.preferredVideoStabilizationMode != wanted {
                        connection.preferredVideoStabilizationMode = wanted
                    }
                }
            }
        case .panorama:
            if photoOutput.isLivePhotoCaptureEnabled { photoOutput.isLivePhotoCaptureEnabled = false }
            frameOutput.setSampleBufferDelegate(panoramaCollector, queue: panoramaCollector.queue)
            use([frameOutput])
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            applyVideoFormat(sizes: [(1920, 1080)], rate: 30, hdr: false, autoLowLightFPS: false, on: device)
            state.videoFormat = nil
            if let connection = frameOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                applyMirroring(on: connection, mirror: side == .front)
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        case .timeLapse:
            frameOutput.setSampleBufferDelegate(timeLapse, queue: timeLapse.queue)
            use([frameOutput])
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if let video {
                applyVideoFormat(
                    sizes: video.resolution == .uhd4K ? [(3840, 2160), (1920, 1080)] : [(1920, 1080)], rate: 30,
                    hdr: false, autoLowLightFPS: false, on: device)
                state.videoFormat = video.timeLapseInterval.map { "every \(CameraMode.intervalText($0))" } ?? "Auto"
            }
            if let connection = frameOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        case .dual:
            state.videoFormat = nil
        }
        applyComposition(on: device)
    }

    /// Watches people, faces, dogs and cats in photo/portrait mode so depth data can be captured
    /// automatically, plus `.qr` in photo mode when QR scanning is enabled.
    private func configureSubjectMetadata() {
        guard session.outputs.contains(metadataOutput) else { return }
        // People and pets only matter for depth: always in Portrait, in Photo with automatic depth.
        let wantsSubjects = mode == .portrait || (video?.autoDepth != false && photoOutput.isDepthDataDeliveryEnabled)
        var wanted: [AVMetadataObject.ObjectType] = wantsSubjects ? [.face, .humanBody, .dogBody, .catBody] : []
        if !wantsSubjects, state.subjectDetected { state.subjectDetected = false }
        if mode == .photo && video?.scanQRCodes != false {
            wanted.append(.qr)
        } else {
            subjectRelay.resetQR()
            state.detectedQR = nil
        }
        let available = Set(metadataOutput.availableMetadataObjectTypes)
        let types = wanted.filter { available.contains($0) }
        if metadataOutput.metadataObjectTypes != types { metadataOutput.metadataObjectTypes = types }
    }

    /// Geometric distortion correction and lens smudge detection (where supported by hardware).
    private func applyComposition(on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        let correct = video?.lensCorrection ?? true
        if device.isGeometricDistortionCorrectionSupported, device.isGeometricDistortionCorrectionEnabled != correct {
            device.isGeometricDistortionCorrectionEnabled = correct
        }
        if device.activeFormat.isCameraLensSmudgeDetectionSupported, !device.isCameraLensSmudgeDetectionEnabled {
            device.setCameraLensSmudgeDetectionEnabled(
                true, detectionInterval: CMTime(seconds: 3, preferredTimescale: 1))
        }
        if device.isVirtualDevice, device.primaryConstituentDeviceSwitchingBehavior != .unsupported,
            !lockedSwitchingForRecording
        {
            switch video?.macroMode ?? .auto {
            case .off:
                device.setPrimaryConstituentDeviceSwitchingBehavior(
                    .restricted, restrictedSwitchingBehaviorConditions: [])
            case .auto, .on:
                device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            }
        }
        device.unlockForConfiguration()
    }

    private func applyMirroring(on connection: AVCaptureConnection, mirror: Bool) {
        guard connection.isVideoMirroringSupported else { return }
        if side == .front {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        } else {
            connection.automaticallyAdjustsVideoMirroring = true
        }
    }

    /// Locks the active constituent lens and/or white balance for the duration of a recording.
    private func lockForRecording(on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if video?.lockVideoCamera == true, device.isVirtualDevice,
            device.primaryConstituentDeviceSwitchingBehavior != .unsupported
        {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
            lockedSwitchingForRecording = true
        }
        if video?.lockVideoWhiteBalance == true, manual.whiteBalance == nil,
            device.isWhiteBalanceModeSupported(.locked)
        {
            var gains = device.deviceWhiteBalanceGains
            let most = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), most)
            gains.greenGain = min(max(gains.greenGain, 1), most)
            gains.blueGain = min(max(gains.blueGain, 1), most)
            device.setWhiteBalanceModeLocked(with: gains)
            lockedWhiteBalanceForRecording = true
        }
    }

    private func unlockAfterRecording() {
        guard lockedSwitchingForRecording || lockedWhiteBalanceForRecording else { return }
        let unlockSwitching = lockedSwitchingForRecording
        let unlockWB = lockedWhiteBalanceForRecording
        lockedSwitchingForRecording = false
        lockedWhiteBalanceForRecording = false
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if unlockSwitching, device.isVirtualDevice,
            device.primaryConstituentDeviceSwitchingBehavior != .unsupported
        {
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
        }
        if unlockWB, manual.whiteBalance == nil,
            device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
        {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    /// Configures iOS 26 Cinematic Video capture format, required metadata object types and
    /// simulated aperture (`AVCaptureDeviceInput.isCinematicVideoCaptureEnabled`).
    private func applyCinematicFormat(video: CaptureOptions, on device: AVCaptureDevice) {
        let cinematicFormats = device.formats.filter(\.isCinematicVideoCaptureSupported)
        if let chosen = cinematicFormats.first(where: {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == 1920 && size.height == 1080
        }) ?? cinematicFormats.first,
            (try? device.lockForConfiguration()) != nil
        {
            device.activeFormat = chosen
            if let range = chosen.videoFrameRateRangeForCinematicVideo {
                let fps = min(30.0, range.maxFrameRate)
                let frame = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
                device.activeVideoMinFrameDuration = frame
                device.activeVideoMaxFrameDuration = frame
            }
            device.unlockForConfiguration()
        }
        if session.outputs.contains(metadataOutput) {
            let required = metadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture
            let available = Set(metadataOutput.availableMetadataObjectTypes)
            metadataOutput.metadataObjectTypes = required.filter { available.contains($0) }
        }
        let format = device.activeFormat
        let aperture = CinematicRules.clampedAperture(
            video.cinematicAperture,
            min: Double(max(format.minSimulatedAperture, 2.0)),
            max: Double(max(format.maxSimulatedAperture, 2.0)))
        if let input, input.isCinematicVideoCaptureSupported {
            input.isCinematicVideoCaptureEnabled = true
            input.simulatedAperture = Float(aperture)
            state.videoFormat = "Cinematic · \(CinematicRules.formatAperture(aperture))"
        } else {
            applyVideoFormat(sizes: [(1920, 1080)], rate: 30, hdr: false, autoLowLightFPS: false, on: device)
            state.videoFormat = "Cinematic · \(CinematicRules.formatAperture(video.cinematicAperture))"
        }
    }

    /// Configures Spatial (first-order Ambisonics), Stereo or Mono audio and Wind Noise Removal.
    private func configureAudioInput() {
        guard let audioInput else { return }
        let wanted = video?.audioChannelMode ?? .stereo
        if wanted == .spatial && audioInput.isMultichannelAudioModeSupported(.firstOrderAmbisonics) {
            audioInput.multichannelAudioMode = .firstOrderAmbisonics
        } else if wanted != .mono && audioInput.isMultichannelAudioModeSupported(.stereo) {
            audioInput.multichannelAudioMode = .stereo
        } else if audioInput.isMultichannelAudioModeSupported(.none) {
            audioInput.multichannelAudioMode = .none
        }
        // Wind noise removal requires multichannelAudioMode != .none on iOS 18+/26+.
        if audioInput.isWindNoiseRemovalSupported {
            audioInput.isWindNoiseRemovalEnabled =
                (video?.windNoiseRemoval ?? true) && audioInput.multichannelAudioMode != .none
        }
    }

    /// Configures a spatial MV-HEVC video format when supported by the camera hardware.
    private func applySpatialVideoFormat(on device: AVCaptureDevice) {
        let spatialFormats = device.formats.filter(\.isSpatialVideoCaptureSupported)
        if let chosen = spatialFormats.first, (try? device.lockForConfiguration()) != nil {
            device.activeFormat = chosen
            let frame = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            device.unlockForConfiguration()
            state.videoFormat = "Spatial · 1080p · 30 fps"
        } else {
            applyVideoFormat(
                sizes: [(1920, 1080)], rate: 30, hdr: false, autoLowLightFPS: false, appleLog: false, on: device)
            state.videoFormat = "Spatial · 1080p · 30 fps"
        }
    }

    /// Registers iPhone 16+ Camera Control sliders (Zoom, Exposure Bias, Photographic Style) when supported.
    private func configureSessionControls(on device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        for existing in session.controls { session.removeControl(existing) }
        session.setControlsDelegate(controlsRelay, queue: queue)
        let zoomSlider = AVCaptureSystemZoomSlider(device: device)
        if session.canAddControl(zoomSlider) { session.addControl(zoomSlider) }
        let exposureSlider = AVCaptureSystemExposureBiasSlider(device: device)
        if session.canAddControl(exposureSlider) { session.addControl(exposureSlider) }
        let presets = PhotographicStylePreset.allCases
        let titles = presets.map(\.title)
        let stylePicker = AVCaptureIndexPicker(
            "Style", symbolName: "wand.and.stars", localizedIndexTitles: titles)
        stylePicker.setActionQueue(queue) { [weak self] (index: Int) in
            guard presets.indices.contains(index) else { return }
            let preset = presets[index]
            let style: PhotographicStyle? = preset == .standard ? nil : PhotographicStyle(preset: preset)
            self?.onControlStyleChanged?(style)
        }
        if session.canAddControl(stylePicker) { session.addControl(stylePicker) }
    }

    /// Lets music or podcasts keep playing while filming and/or routes audio from AirPods / Bluetooth HFP.
    private func configureAudioSession(allowPlayback: Bool, allowAirPodsMic: Bool, needsAudio: Bool) {
        // Setting the audio session up is slow; only when what is wanted changes.
        let setup = "\(allowPlayback)-\(allowAirPodsMic)-\(needsAudio)"
        guard setup != audioSessionSetup else { return }
        audioSessionSetup = setup
        guard needsAudio else {
            session.automaticallyConfiguresApplicationAudioSession = true
            return
        }
        if allowPlayback || allowAirPodsMic {
            session.automaticallyConfiguresApplicationAudioSession = false
            let audio = AVAudioSession.sharedInstance()
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
            if allowPlayback { options.insert(.mixWithOthers) }
            try? audio.setCategory(.playAndRecord, mode: .videoRecording, options: options)
            if allowAirPodsMic,
                let bluetooth = audio.availableInputs?.first(where: { $0.portType == .bluetoothHFP })
            {
                try? audio.setPreferredInput(bluetooth)
            } else {
                try? audio.setPreferredInput(nil)
            }
            try? audio.setActive(true)
        } else {
            session.automaticallyConfiguresApplicationAudioSession = true
        }
    }

    private func availableBayerRAW() -> OSType? {
        photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
    }

    private func availableAppleProRAW() -> OSType? {
        photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
    }

    private func connectedExternalStorage() -> (device: AVExternalStorageDevice, info: ExternalStorageInfo)? {
        guard AVExternalStorageDeviceDiscoverySession.isSupported,
            let dev = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices
                .first(where: \.isConnected)
        else { return nil }
        let info = ExternalStorageInfo(
            displayName: dev.displayName ?? "External SSD", freeBytes: Int64(max(0, dev.freeSize)))
        return (dev, info)
    }

    /// Sound, when allowed.
    private func addMicrophone() {
        guard audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            let microphone = AVCaptureDevice.default(for: .audio),
            let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input)
        else { return }
        session.addInput(input)
        audioInput = input
    }

    /// The format closest to what was asked: the size first, then the frame rate, then HDR (10
    /// bit with HLG) or not, and auto low-light FPS when requested and supported. What was
    /// actually chosen is shown on the camera screen.
    private func applyVideoFormat(
        sizes: [(Int, Int)], rate: Double, hdr wantHDR: Bool, autoLowLightFPS: Bool,
        appleLog wantLog: Bool = false, on device: AVCaptureDevice
    ) {
        func dimensions(_ format: AVCaptureDevice.Format) -> (Int, Int) {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (Int(size.width), Int(size.height))
        }
        func maxRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        func tenBit(_ format: AVCaptureDevice.Format) -> Bool {
            CMFormatDescriptionGetMediaSubType(format.formatDescription)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        let sized =
            sizes.lazy.map { size in device.formats.filter { dimensions($0) == size } }.first { !$0.isEmpty }
            ?? []
        guard !sized.isEmpty else {
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            state.videoFormat = nil
            return
        }
        let fast = sized.filter { maxRate($0) >= rate }
        let pool = fast.isEmpty ? sized : fast
        let format =
            pool.first {
                if wantLog {
                    return tenBit($0) && $0.supportedColorSpaces.contains(.appleLog)
                }
                return wantHDR ? tenBit($0) && $0.supportedColorSpaces.contains(.HLG_BT2020) : !tenBit($0)
            }
            ?? pool[0]
        let used = min(rate, maxRate(format)).rounded()
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        // Setting frame durations while `isAutoVideoFrameRateEnabled` is true throws an exception.
        if autoLowLightFPS && format.isAutoVideoFrameRateSupported {
            device.isAutoVideoFrameRateEnabled = true
        } else {
            if device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
            let frame = CMTime(value: 1, timescale: CMTimeScale(used))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
        }
        if wantLog, format.supportedColorSpaces.contains(.appleLog) {
            device.activeColorSpace = .appleLog
        } else if wantHDR, format.supportedColorSpaces.contains(.HLG_BT2020) {
            device.activeColorSpace = .HLG_BT2020
        } else if format.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        device.unlockForConfiguration()
        let (width, _) = dimensions(format)
        let hdr = device.activeColorSpace == .HLG_BT2020
        let fpsText = CameraControls.frameRateLabel(Int(used))
        let autoSuffix = device.isAutoVideoFrameRateEnabled ? " · Auto" : ""
        state.videoFormat = "\(width >= 3840 ? "4K" : "1080p") · \(fpsText)\(hdr ? " · HDR" : "")\(autoSuffix)"
    }

    /// 1× (the main camera), focus and exposure following the picture.
    private func prepare(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        let one = 1 / device.displayVideoZoomFactorMultiplier
        device.videoZoomFactor = min(max(one, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.isSubjectAreaChangeMonitoringEnabled = true
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.unlockForConfiguration()
        applyManual(on: device)
        state.focusLocked = false
        for observer in observers.dropFirst() { NotificationCenter.default.removeObserver(observer) }
        observers = Array(observers.prefix(1))
        observers.append(
            NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: nil
            ) { [weak self] _ in
                // The picture changed a lot since the last tap: follow the middle again.
                self?.run { core in
                    if !core.state.focusLocked { core.focus(at: CGPoint(x: 0.5, y: 0.5), lock: false) }
                }
            })
    }

    /// What the screen shows: the zoom buttons, the range, flash and torch.
    private func describe(_ device: AVCaptureDevice) -> CameraState {
        let facts = cameraFacts(device)
        var described = CameraState()
        described.ready = true
        described.side = side
        described.canFlip = facts.canFlip
        described.canMultiCam = MultiCamEngine.isSupported && (Self.profile?.multiCam ?? true)
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        let lowest = Double(device.minAvailableVideoZoomFactor) * multiplier
        var presets: [Double] = []
        if lowest < 0.95 { presets.append((lowest * 10).rounded() / 10) }
        presets.append(1)
        if side == .back { presets.append(2) }
        for switchOver in device.virtualDeviceSwitchOverVideoZoomFactors {
            let shown = (switchOver.doubleValue * multiplier * 10).rounded() / 10
            if shown > 1.05, !presets.contains(where: { abs($0 - shown) < 0.15 }) { presets.append(shown) }
        }
        let highest = Zoom.highest(
            device: Double(device.maxAvailableVideoZoomFactor) * multiplier, cap: max(10, (presets.max() ?? 1) * 5))
        described.presets = presets.filter { $0 <= highest }.sorted()
        described.zoomRange = lowest...max(lowest, highest)
        described.hasFlash = device.hasFlash
        described.hasTorch = device.hasTorch
        described.canLive = mode == .photo && photoOutput.isLivePhotoCaptureSupported
        described.canRAW = mode == .photo && (availableBayerRAW() != nil || (side == .back && facts.canBayerRAW))
        let dims = device.activeFormat.supportedMaxPhotoDimensions.map {
            (width: Int($0.width), height: Int($0.height))
        }
        described.availableResolutions = PhotoResolution.available(for: dims)
        if isBayerRAWActive {
            described.presets = [1]
            described.zoomRange = 1...1
            described.availableResolutions = [.mp12]
        }
        described.customPreviewActive = needsMetalPreview && session.outputs.contains(previewOutput)
        described.canDepth = photoOutput.isDepthDataDeliverySupported
        described.subjectDetected = state.subjectDetected
        described.portraitHint =
            mode == .portrait ? PortraitMath.hint(distanceMeters: nil, iso: Double(device.iso)) : nil
        let canSpatialVideo = facts.canSpatialVideo
        let canAppleLog = facts.canAppleLog
        // ProRes shows on the movie output only while it is attached; the Log formats imply it.
        let canProRes =
            canAppleLog || movieOutput.availableVideoCodecTypes.contains(.proRes422)
            || (Self.profile?.proRes == true && photoOutput.isAppleProRAWSupported)
        let canMacro = facts.canMacro
        let canSpatialAudio =
            audioInput?.isMultichannelAudioModeSupported(.firstOrderAmbisonics) ?? canSpatialVideo
        let runtime = DeviceCapabilities(
            canProRAW: photoOutput.isAppleProRAWSupported,
            canProRes: canProRes,
            canAppleLog: canAppleLog,
            canExternalStorage: AVExternalStorageDeviceDiscoverySession.isSupported,
            canSpatialVideo: canSpatialVideo,
            canMacroControl: canMacro,
            canCameraControl: session.supportsControls,
            canSpatialAudio: canSpatialAudio,
            canAudioMix: canSpatialAudio,
            canActionMode: facts.canActionMode,
            canCinematic: facts.canCinematic,
            canDepth: photoOutput.isDepthDataDeliverySupported || side == .back,
            canBayerRAW: facts.canBayerRAW,
            canWindNoiseRemoval: audioInput?.isWindNoiseRemovalSupported ?? false)
        described.capabilities = DeviceProfile.effective(runtime: runtime, profile: Self.profile)
        described.canCinematic = described.capabilities.canCinematic
        described.canWindNoiseRemoval = runtime.canWindNoiseRemoval
        described.externalStorage = connectedExternalStorage()?.info
        described.macroActive =
            canMacro && device.activePrimaryConstituent?.deviceType == .builtInUltraWideCamera
            && Double(device.videoZoomFactor) * multiplier >= 0.95
        described.controlsFullscreen = state.controlsFullscreen
        described.manualLimits = limits(of: device)
        described.focusLocked = state.focusLocked
        described.videoFormat = state.videoFormat
        return described
    }

    /// The facts about `device` that never change, searched for once.
    private func cameraFacts(_ device: AVCaptureDevice) -> CameraFacts {
        if let known = facts[device.uniqueID] { return known }
        let formats = device.formats
        let found = CameraFacts(
            canFlip: Self.camera(side == .back ? .front : .back) != nil,
            canCinematic: formats.contains(where: \.isCinematicVideoCaptureSupported),
            canSpatialVideo: formats.contains(where: \.isSpatialVideoCaptureSupported),
            canAppleLog: formats.contains { $0.supportedColorSpaces.contains(.appleLog) },
            canActionMode: formats.contains { $0.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced) },
            canMacro: device.isVirtualDevice
                && device.constituentDevices.contains {
                    $0.deviceType == .builtInUltraWideCamera && $0.isFocusModeSupported(.autoFocus)
                },
            canBayerRAW: side == .back && Self.supportsBackBayerRAW(),
            kelvin: ManualLimits.reachableKelvin { kelvin in
                let gains = device.deviceWhiteBalanceGains(for: .init(temperature: Float(kelvin), tint: 0))
                let most = device.maxWhiteBalanceGain
                return [gains.redGain, gains.greenGain, gains.blueGain].allSatisfy { $0 >= 1 && $0 <= most }
            })
        facts[device.uniqueID] = found
        return found
    }

    /// Always a ramp: a glide for the lens buttons (about the same time for any distance), and
    /// a quick one that follows a finger smoothly. The camera switches lenses on the way where
    /// Apple's camera does.
    func zoom(to shown: Double, glide: Bool) {
        guard !isBayerRAWActive, let device, (try? device.lockForConfiguration()) != nil else { return }
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        let factor = min(
            max(shown / multiplier, Double(device.minAvailableVideoZoomFactor)),
            Double(device.maxAvailableVideoZoomFactor))
        let rate = glide ? Zoom.glideRate(from: Double(device.videoZoomFactor), to: factor) : Zoom.followRate
        device.ramp(toVideoZoomFactor: CGFloat(factor), withRate: rate)
        device.unlockForConfiguration()
    }

    /// What can be set by hand on this camera, in its current format. In video modes the shutter
    /// can't stay open longer than a frame.
    private func limits(of device: AVCaptureDevice) -> ManualLimits? {
        let format = device.activeFormat
        guard device.isExposureModeSupported(.custom) else { return nil }
        var longest = format.maxExposureDuration.seconds
        if mode.records { longest = min(longest, device.activeVideoMaxFrameDuration.seconds) }
        let shortest = format.minExposureDuration.seconds
        guard shortest > 0, longest >= shortest, format.maxISO >= format.minISO else { return nil }
        return ManualLimits(
            shutter: shortest...longest, iso: Double(format.minISO)...Double(format.maxISO),
            exposureBias: Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias),
            canFocus: device.isLockingFocusWithCustomLensPositionSupported,
            canSetWhiteBalance: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            kelvin: cameraFacts(device).kelvin)
    }

    func manual(_ settings: ManualSettings) {
        manual = settings
        if let device { applyManual(on: device) }
    }

    /// Exposure (shutter, ISO; the one not set stays where the camera had it), white balance
    /// and focus as set by hand; everything else back to the camera.
    private func applyManual(on device: AVCaptureDevice) {
        guard let limits = limits(of: device), (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let set = limits.fitted(manual)
        if set.exposureIsManual {
            let duration = set.shutter.map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) }
            device.setExposureModeCustom(
                duration: duration ?? AVCaptureDevice.currentExposureDuration,
                iso: set.iso.map(Float.init) ?? AVCaptureDevice.currentISO)
        } else if device.exposureMode == .custom, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.setExposureTargetBias(Float(set.exposureBias))
        if let balance = set.whiteBalance {
            var gains = device.deviceWhiteBalanceGains(
                for: .init(temperature: Float(balance.kelvin), tint: Float(balance.tint)))
            let most = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), most)
            gains.greenGain = min(max(gains.greenGain, 1), most)
            gains.blueGain = min(max(gains.blueGain, 1), most)
            device.setWhiteBalanceModeLocked(with: gains)
        } else if device.whiteBalanceMode == .locked,
            device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
        {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        let cinematicActive = input?.isCinematicVideoCaptureEnabled == true
        if !cinematicActive {
            if let focus = set.focus {
                device.setFocusModeLocked(lensPosition: Float(focus))
            } else if device.focusMode == .locked, !state.focusLocked,
                device.isFocusModeSupported(.continuousAutoFocus)
            {
                device.focusMode = .continuousAutoFocus
            }
        }
    }

    /// `point` in the camera's coordinates (0…1). Locked: focus and expose once, then keep.
    /// What is set by hand stays.
    func focus(at point: CGPoint, lock: Bool) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if input?.isCinematicVideoCaptureEnabled == true {
            // While Cinematic Video capture is enabled, changing `device.focusMode` throws
            // NSInvalidArgumentException; use the dedicated Cinematic tracking focus API instead.
            device.setCinematicVideoTrackingFocus(at: point, focusMode: lock ? .strong : .weak)
            device.unlockForConfiguration()
            if state.focusLocked != lock {
                state.focusLocked = lock
                publish(device: nil)
            }
            return
        }
        if manual.focus == nil {
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
            let focusMode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
            if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
        }
        if !manual.exposureIsManual {
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
            let exposureMode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
            if device.isExposureModeSupported(exposureMode) { device.exposureMode = exposureMode }
        }
        device.isSubjectAreaChangeMonitoringEnabled = !lock
        device.unlockForConfiguration()
        if state.focusLocked != lock {
            state.focusLocked = lock
            publish(device: nil)
        }
    }

    func torch(_ on: Bool) {
        guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        let mode: AVCaptureDevice.TorchMode = on ? .on : .off
        if device.isTorchModeSupported(mode) { device.torchMode = mode }
        device.unlockForConfiguration()
    }

    func takePhoto(
        _ request: PhotoRequest, angle: CGFloat, preview: (@Sendable (CGImage) -> Void)? = nil,
        done: @escaping @Sendable (TakenPhoto?) -> Void
    ) {
        guard mode.isStill, session.isRunning, let connection = photoOutput.connection(with: .video) else {
            return done(nil)
        }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        applyMirroring(on: connection, mirror: request.mirrorFrontCamera)
        let heic = request.format == .heic && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let processedFormat: [String: Any] = [AVVideoCodecKey: heic ? AVVideoCodecType.hevc : .jpeg]
        var rawFormat: OSType? =
            if request.proRAW, photoOutput.isAppleProRAWEnabled {
                availableAppleProRAW()
            } else if request.raw {
                availableBayerRAW()
            } else {
                nil
            }
        let isBayerRAW = rawFormat.map { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) } ?? false
        if isBayerRAW {
            if let device, device.videoZoomFactor != 1.0, (try? device.lockForConfiguration()) != nil {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = 1.0
                device.unlockForConfiguration()
            }
            if device?.videoZoomFactor != 1.0 || connection.videoScaleAndCropFactor != 1.0 {
                rawFormat = nil
            }
        }
        let settings: AVCapturePhotoSettings
        if let rawFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: processedFormat)
        } else {
            settings = AVCapturePhotoSettings(format: processedFormat)
        }
        if rawFormat != nil && isBayerRAW {
            settings.photoQualityPrioritization = .speed
            if photoOutput.isConstantColorSupported { settings.isConstantColorEnabled = false }
        } else {
            let wantedPriority: AVCapturePhotoOutput.QualityPrioritization =
                request.prioritizeFastest ? .speed : request.prioritizeFaster ? .balanced : .quality
            settings.photoQualityPrioritization =
                wantedPriority.rawValue <= photoOutput.maxPhotoQualityPrioritization.rawValue
                ? wantedPriority : photoOutput.maxPhotoQualityPrioritization
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        // A small JPEG inside the file: the button next to the shutter shows it at once.
        if preview != nil, settings.availableEmbeddedThumbnailPhotoCodecTypes.contains(.jpeg) {
            settings.embeddedThumbnailPhotoFormat = [
                AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 320, AVVideoHeightKey: 320,
            ]
        }
        let flash: AVCaptureDevice.FlashMode =
            switch request.flash {
            case .auto: .auto
            case .on: .on
            case .off: .off
            }
        if photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        if request.captureDepth, rawFormat == nil, photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            if request.capturePortraitMatte, photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                settings.isPortraitEffectsMatteDeliveryEnabled = true
            }
        }
        if request.live, rawFormat == nil, photoOutput.isLivePhotoCaptureEnabled {
            settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mov")
            if photoOutput.availableLivePhotoVideoCodecTypes.contains(.hevc) {
                settings.livePhotoVideoCodecType = .hevc
            }
            settings.livePhotoMovieMetadata = VideoMetadata.items(
                location: request.location, takenAt: request.takenAt, timeZone: .current)
        }
        let id = settings.uniqueID
        let capture = PhotoCapture(request: request, heic: heic, preview: preview) { [weak self] photo in
            self?.run { $0.photos[id] = nil }
            done(photo)
        }
        photos[id] = capture
        photoOutput.capturePhoto(with: settings, delegate: capture)
    }

    /// Snaps a still photo during an active video or locked QuickTake recording (no Live Photo,
    /// no RAW, no flash) using the `photoOutput` coexisting in the session.
    func takeStillWhileRecording(
        _ request: PhotoRequest, angle: CGFloat, done: @escaping @Sendable (TakenPhoto?) -> Void
    ) {
        guard session.isRunning, movieOutput.isRecording, session.outputs.contains(photoOutput),
            device?.activeColorSpace != .appleLog,
            let connection = photoOutput.connection(with: .video)
        else { return done(nil) }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        applyMirroring(on: connection, mirror: request.mirrorFrontCamera)
        let heic = request.format == .heic && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: heic ? AVVideoCodecType.hevc : .jpeg])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        let speedPriority = AVCapturePhotoOutput.QualityPrioritization.speed
        settings.photoQualityPrioritization =
            speedPriority.rawValue <= photoOutput.maxPhotoQualityPrioritization.rawValue
            ? speedPriority : photoOutput.maxPhotoQualityPrioritization
        if photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
        let id = settings.uniqueID
        let capture = PhotoCapture(request: request, heic: heic) { [weak self] photo in
            self?.run { $0.photos[id] = nil }
            done(photo)
        }
        photos[id] = capture
        photoOutput.capturePhoto(with: settings, delegate: capture)
    }

    /// Starts a QuickTake video from photo mode by disabling Live Photos and attaching
    /// `movieOutput` temporarily; restored back to photo mode once recording ends.
    func startQuickTake(_ request: VideoRequest, angle: CGFloat) {
        guard mode == .photo, session.isRunning, !movieOutput.isRecording, let device else { return }
        session.beginConfiguration()
        photoOutput.isLivePhotoCaptureEnabled = false
        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        addMicrophone()
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            $0.width * $0.height < $1.width * $1.height
        }) {
            photoOutput.maxPhotoDimensions = largest
        }
        if let connection = movieOutput.connection(with: .video) {
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
        session.commitConfiguration()
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        applyMirroring(on: connection, mirror: video?.mirrorFrontCamera == true)
        lockForRecording(on: device)
        movieOutput.metadata = VideoMetadata.items(
            location: request.location, takenAt: request.takenAt, timeZone: request.timeZone)
        let recording = Recording()
        self.recording = recording
        quickTaking = true
        movieOutput.startRecording(to: request.url, recordingDelegate: recording)
    }

    func pauseRecording() {
        guard movieOutput.isRecording, !movieOutput.isRecordingPaused else { return }
        movieOutput.pauseRecording()
    }

    func resumeRecording() {
        guard movieOutput.isRecording, movieOutput.isRecordingPaused else { return }
        movieOutput.resumeRecording()
    }

    func startRecording(_ request: VideoRequest, angle: CGFloat) {
        let metadata = VideoMetadata.items(
            location: request.location, takenAt: request.takenAt, timeZone: request.timeZone)
        if mode == .timeLapse {
            guard session.isRunning, !timeLapsing, let connection = frameOutput.connection(with: .video) else { return }
            // The frames come upright, so the file needs no turning.
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            applyMirroring(on: connection, mirror: video?.mirrorFrontCamera == true)
            if let device { lockForRecording(on: device) }
            timeLapsing = true
            timeLapse.begin(url: request.url, fixedInterval: video?.timeLapseInterval, metadata: metadata)
            return
        }
        guard mode.records, session.isRunning, !movieOutput.isRecording,
            let connection = movieOutput.connection(with: .video)
        else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        applyMirroring(on: connection, mirror: video?.mirrorFrontCamera == true)
        if let device { lockForRecording(on: device) }
        movieOutput.metadata = metadata
        var targetURL = request.url
        if request.preferExternalStorage, let external = connectedExternalStorage(),
            let urls = try? external.device.nextAvailableURLs(withPathExtensions: ["mov"]),
            let externalURL = urls.first, externalURL.startAccessingSecurityScopedResource()
        {
            activeExternalURL = externalURL
            targetURL = externalURL
        }
        let recording = Recording()
        self.recording = recording
        movieOutput.startRecording(to: targetURL, recordingDelegate: recording)
    }

    /// The finished file, and for a time-lapse which stretches were taken how often.
    func stopRecording(done: @escaping @Sendable (URL?, TimeLapsePlan?) -> Void) {
        unlockAfterRecording()
        if timeLapsing {
            timeLapsing = false
            return timeLapse.finish { url, plan in done(url, plan) }
        }
        guard let recording else { return done(nil, nil) }
        self.recording = nil
        let wasQuickTake = quickTaking
        quickTaking = false
        recording.whenFinished { [weak self] url in
            self?.run { core in
                if let scoped = core.activeExternalURL {
                    scoped.stopAccessingSecurityScopedResource()
                    core.activeExternalURL = nil
                }
                if wasQuickTake, core.mode == .photo, let device = core.device {
                    core.session.beginConfiguration()
                    core.apply(mode: .photo, on: device)
                    core.session.commitConfiguration()
                    core.state = core.describe(device)
                    core.publish(device: nil)
                }
            }
            done(url, nil)
        }
        if movieOutput.isRecording { movieOutput.stopRecording() }
    }

    func startPanorama(direction: PanoramaDirection, angle: CGFloat) {
        guard mode == .panorama, session.isRunning, !panoramaCapturing,
            let connection = frameOutput.connection(with: .video)
        else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        applyMirroring(on: connection, mirror: video?.mirrorFrontCamera == true)
        if let device { lockForPanorama(on: device) }
        panoramaCapturing = true
        panoramaCollector.begin(direction: direction)
    }

    func stopPanorama(request: PhotoRequest, done: @escaping @Sendable (TakenPhoto?) -> Void) {
        unlockAfterPanorama()
        guard panoramaCapturing else { return done(nil) }
        panoramaCapturing = false
        let preferHEIC = request.format == .heic
        panoramaCollector.finish { frames, direction in
            DispatchQueue.global(qos: .userInitiated).async {
                let images = frames.map { CIImage(cgImage: $0) }
                guard
                    let stitched = PanoramaStitcher.stitch(
                        frames: images, direction: direction, preferHEIC: preferHEIC)
                else {
                    done(nil)
                    return
                }
                done(
                    TakenPhoto(
                        data: stitched.data, heic: stitched.heic, width: stitched.width, height: stitched.height))
            }
        }
    }

    /// Locks exposure and white balance when a panorama sweep starts so brightness and colour
    /// stay uniform across the stitched frames.
    private func lockForPanorama(on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) {
            var gains = device.deviceWhiteBalanceGains
            let most = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), most)
            gains.greenGain = min(max(gains.greenGain, 1), most)
            gains.blueGain = min(max(gains.blueGain, 1), most)
            device.setWhiteBalanceModeLocked(with: gains)
        }
        lockedForPanorama = true
    }

    private func unlockAfterPanorama() {
        guard lockedForPanorama else { return }
        lockedForPanorama = false
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if !manual.exposureIsManual, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if manual.whiteBalance == nil, device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }
}

/// Bridges iPhone 16+ Camera Control overlay lifecycle events to the camera state.
final class CameraControlsRelay: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    var onFullscreenChanged: (@Sendable (Bool) -> Void)?

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        onFullscreenChanged?(true)
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        onFullscreenChanged?(false)
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        onFullscreenChanged?(false)
    }
}

/// Collects video-output frames during a Panorama sweep on a serial queue, keeping up to 24
/// well-spaced `CGImage` frames so pixel-buffer pools stay free.
final class PanoramaCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.panorama", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var active = false
    private var direction = PanoramaDirection.leftToRight
    private var frames: [CGImage] = []
    private var lastCaptureTime: Double = 0

    func begin(direction: PanoramaDirection) {
        queue.async {
            self.direction = direction
            self.frames = []
            self.lastCaptureTime = 0
            self.active = true
        }
    }

    func cancel() {
        queue.async {
            self.active = false
            self.frames = []
        }
    }

    func finish(_ done: @escaping @Sendable ([CGImage], PanoramaDirection) -> Void) {
        queue.async {
            self.active = false
            let collected = self.frames
            let dir = self.direction
            self.frames = []
            done(collected, dir)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard active, frames.count < 24, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= 0.16 else { return }
        lastCaptureTime = now
        let ci = CIImage(cvPixelBuffer: buffer)
        if let cg = ciContext.createCGImage(ci, from: ci.extent) {
            frames.append(cg)
        }
    }
}

/// Runs throttled fast Vision text recognition in Photo mode on the preview frames (at most every
/// 1.5 s, one at a time) so the viewfinder can offer a Live Text button when text comes into view.
final class ViewfinderTextDetector: @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.livetext", qos: .utility)
    var onText: (@Sendable (String?) -> Void)?
    private let lock = NSLock()
    private var lastScanTime: Double = 0
    private var busy = false
    private var lastDetectedAt: Double = 0
    private var lastText: String?

    /// A frame from the preview: looked at when enough time has passed and none is being read.
    func offer(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let take = lock.withLock { () -> Bool in
            guard !busy, now - lastScanTime >= 1.5 else { return false }
            busy = true
            lastScanTime = now
            return true
        }
        guard take else { return }
        let frame = Carry(value: buffer)
        queue.async { [weak self] in
            self?.read(frame.value, at: now)
            self?.lock.withLock { self?.busy = false }
        }
    }

    private func read(_ buffer: CVPixelBuffer, at now: Double) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        // The preview frames are already upright.
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        let joined = lines.isEmpty ? nil : lines.prefix(12).joined(separator: "\n")
        if let joined {
            lastDetectedAt = now
            if joined != lastText {
                lastText = joined
                onText?(joined)
            }
        } else if lastText != nil, now - lastDetectedAt >= 2.0 {
            lastText = nil
            onText?(nil)
        }
    }
}

/// One photo on its way out of the camera.
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let request: PhotoRequest
    let heic: Bool
    let preview: (@Sendable (CGImage) -> Void)?
    let done: @Sendable (TakenPhoto?) -> Void
    private var photo: TakenPhoto?
    private var rawData: Data?
    private var movie: URL?
    private let started = ContinuousClock.now

    init(
        request: PhotoRequest, heic: Bool, preview: (@Sendable (CGImage) -> Void)? = nil,
        done: @escaping @Sendable (TakenPhoto?) -> Void
    ) {
        self.request = request
        self.heic = heic
        self.preview = preview
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
            let data = photo.fileDataRepresentation(
                with: GPSWriter(location: request.location, trueNorth: request.trueNorth, at: request.takenAt))
        else { return }
        if photo.isRawPhoto {
            rawData = data
            return
        }
        // Before a Live Photo's video is finished: the small picture for the shutter's neighbour.
        if let preview, let small = Self.small(data) { preview(small) }
        let size = Thumbnails.shownSize(of: data)
        let dimensions = photo.resolvedSettings.photoDimensions
        self.photo = TakenPhoto(
            data: data, heic: heic, width: size?.width ?? Int(dimensions.width),
            height: size?.height ?? Int(dimensions.height))
    }

    /// The sensor has the picture: the camera can take the next one.
    func photoOutput(
        _ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        CameraTimingLog.shared.record(.shutterToReady, milliseconds: started.duration(to: .now).milliseconds)
    }

    /// The embedded thumbnail (or a quick downscale), turned upright.
    static func small(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
    ) {
        if error == nil { movie = outputFileURL }
    }

    /// Called last, after the photo and (for a Live Photo / RAW) its companion.
    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if var photo {
            if let movie, FileManager.default.fileExists(atPath: movie.path) { photo.liveVideo = movie }
            if let rawData { photo.rawData = rawData }
            self.photo = photo
        }
        done(photo)
    }
}

/// A video being recorded; tells when its file is finished.
final class Recording: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: (@Sendable (URL?) -> Void)?
    private var result: URL??

    func whenFinished(_ done: @escaping @Sendable (URL?) -> Void) {
        let ready: URL?? = lock.withLock {
            if result == nil { waiting = done }
            return result
        }
        if let ready { done(ready) }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // An error may still leave a complete file (the disk got full, a call came in).
        let complete =
            error == nil
            || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let outcome: URL? = complete ? url : nil
        let waiting: (@Sendable (URL?) -> Void)? = lock.withLock {
            result = .some(outcome)
            return self.waiting
        }
        waiting?(outcome)
    }
}

/// Writes the place (with its accuracy) and direction into the photo's own metadata, like
/// Apple's camera does, so the file carries them wherever it goes.
final class GPSWriter: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    let location: ClientLocation?
    let trueNorth: Bool
    let moment: Date

    init(location: ClientLocation?, trueNorth: Bool, at moment: Date) {
        self.location = location
        self.trueNorth = trueNorth
        self.moment = moment
    }

    /// Made once (a formatter is slow to make).
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter
    }()
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let location else { return nil }
        var metadata = photo.metadata
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(location.latitude),
            kCGImagePropertyGPSLatitudeRef as String: location.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(location.longitude),
            kCGImagePropertyGPSLongitudeRef as String: location.longitude >= 0 ? "E" : "W",
        ]
        gps[kCGImagePropertyGPSTimeStamp as String] = Self.time.string(from: moment)
        gps[kCGImagePropertyGPSDateStamp as String] = Self.day.string(from: moment)
        if let accuracy = location.horizontalAccuracy {
            gps[kCGImagePropertyGPSHPositioningError as String] = accuracy
        }
        if let altitude = location.altitude {
            gps[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = altitude >= 0 ? 0 : 1
        }
        if let heading = location.heading {
            gps[kCGImagePropertyGPSImgDirection as String] = heading
            gps[kCGImagePropertyGPSImgDirectionRef as String] = trueNorth ? "T" : "M"
        }
        metadata[kCGImagePropertyGPSDictionary as String] = gps
        return metadata
    }
}

/// Follows ISO, shutter speed, white balance and focus as the camera changes them, and hands them
/// to the main thread at most five times a second (and the last one always).
final class ReadingsWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var readings = CameraReadings()
    private var observations: [NSKeyValueObservation] = []
    private var lastSent = Date.distantPast
    private var waiting = false
    private let relay: Relay<CameraReadings>
    private let pause = 0.2

    init(_ deliver: @escaping @MainActor (CameraReadings) -> Void) {
        relay = Relay(deliver)
    }

    @MainActor func watch(_ device: AVCaptureDevice) {
        observations = Self.observe(device, into: self)
    }

    nonisolated private static func observe(_ device: AVCaptureDevice, into watch: ReadingsWatch)
        -> [NSKeyValueObservation]
    {
        [
            device.observe(\.iso, options: [.initial]) { @Sendable device, _ in
                watch.change { $0.iso = Double(device.iso) }
            },
            device.observe(\.exposureDuration, options: [.initial]) { @Sendable device, _ in
                watch.change { $0.shutter = device.exposureDuration.seconds }
            },
            device.observe(\.lensPosition, options: [.initial]) { @Sendable device, _ in
                watch.change { $0.focus = Double(device.lensPosition) }
            },
            device.observe(\.deviceWhiteBalanceGains, options: [.initial]) { @Sendable device, _ in
                var gains = device.deviceWhiteBalanceGains
                let most = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), most)
                gains.greenGain = min(max(gains.greenGain, 1), most)
                gains.blueGain = min(max(gains.blueGain, 1), most)
                let balance = device.temperatureAndTintValues(for: gains)
                watch.change {
                    $0.kelvin = Double(balance.temperature)
                    $0.tint = Double(balance.tint)
                }
            },
        ]
    }

    private func change(_ update: (inout CameraReadings) -> Void) {
        let (send, later): (CameraReadings?, Double?) = lock.withLock {
            update(&readings)
            let since = Date().timeIntervalSince(lastSent)
            if since >= pause {
                lastSent = Date()
                return (readings, nil)
            }
            if waiting { return (nil, nil) }
            waiting = true
            return (nil, pause - since)
        }
        if let send { relay.send(send) }
        if let later {
            DispatchQueue.global().asyncAfter(deadline: .now() + later) { [weak self] in
                guard let self else { return }
                let latest = self.lock.withLock {
                    self.waiting = false
                    self.lastSent = Date()
                    return self.readings
                }
                self.relay.send(latest)
            }
        }
    }
}
