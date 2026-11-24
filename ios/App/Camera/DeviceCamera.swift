import AVFoundation
import HaldenKit
import ImageIO
import Observation
import UIKit

/// The iPhone's cameras through AVFoundation: ultra wide, main and tele as one virtual camera
/// (so zooming switches between them where Apple's camera does), and the front camera. All
/// AVFoundation work happens on the camera's own queue (`CaptureCore`), never on the main thread.
@MainActor
@Observable
final class DeviceCamera: CaptureBackend {
    private(set) var state = CameraState()
    @ObservationIgnored let preview = PreviewView()
    var previewView: UIView { preview }
    @ObservationIgnored private let core = CaptureCore()
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var zoomObservation: NSKeyValueObservation?
    @ObservationIgnored private var zoomRelay: Relay<Double>?
    private(set) var readings = CameraReadings()
    @ObservationIgnored private var readingsWatch: ReadingsWatch?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var mode = CameraMode.photo
    @ObservationIgnored private var video: CaptureOptions?

    init() {
        preview.previewLayer.session = core.session
        preview.previewLayer.videoGravity = .resizeAspectFill
        core.changed = { [weak self] state, device in
            Task { @MainActor in self?.update(state, device: device?.value) }
        }
        zoomRelay = Relay { [weak self] zoom in self?.state.zoom = zoom }
        readingsWatch = ReadingsWatch { [weak self] readings in
            if self?.readings != readings { self?.readings = readings }
        }
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
            core.run { $0.startRunning() }
        }
    }

    private func denied() {
        state.problem = "Halden may not use the camera. Allow it in Settings › Halden."
    }

    func stop() {
        core.run { $0.stopRunning() }
    }

    func setMode(_ mode: CameraMode, options video: CaptureOptions) {
        self.mode = mode
        self.video = video
        Task {
            // Sound for videos and Live Photos; without the microphone they are silent.
            let sound = mode == .video || mode == .slowMotion || (mode == .photo && video.live)
            if sound, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            core.run { $0.change(mode: mode, video: video) }
        }
    }

    func flip() {
        let side: CameraSide = state.side == .back ? .front : .back
        let (mode, video) = (mode, video)
        core.run { $0.configure(side: side, mode: mode, video: video) }
    }

    /// The zoom shown follows the camera itself (see `update`), so it moves along with a glide
    /// instead of jumping to where it is going.
    func zoom(to factor: Double, glide: Bool) {
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

    func takePhoto(_ request: PhotoRequest) async -> TakenPhoto? {
        let angle = captureAngle
        return await withCheckedContinuation { continuation in
            core.run { $0.takePhoto(request, angle: angle) { continuation.resume(returning: $0) } }
        }
    }

    func startRecording(_ request: VideoRequest) -> Bool {
        guard state.ready else { return false }
        let angle = captureAngle
        core.run { $0.startRecording(request, angle: angle) }
        return true
    }

    func stopRecording() async -> URL? {
        let (url, plan): (URL?, TimeLapsePlan?) = await withCheckedContinuation { continuation in
            core.run { $0.stopRecording { url, plan in continuation.resume(returning: (url, plan)) } }
        }
        guard let url else { return nil }
        if let plan, plan.stretches.count > 1 { return await Self.evenOut(url, plan) ?? url }
        return url
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
        // The zoom comes from the camera as it changes (below); a state sent before that is older.
        if device == nil { new.zoom = state.zoom }
        state = new
        guard let device, device !== rotation?.device else { return }
        if let zoomRelay { zoomObservation = Self.follow(zoomOf: device, into: zoomRelay) }
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
    nonisolated private static func follow(zoomOf device: AVCaptureDevice, into relay: Relay<Double>)
        -> NSKeyValueObservation
    {
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        return device.observe(\.videoZoomFactor, options: [.initial, .new]) { @Sendable device, change in
            relay.send(Double(change.newValue ?? device.videoZoomFactor) * multiplier)
        }
    }

    /// The camera's picture.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
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

/// Everything that touches AVFoundation. Only ever used on `queue` (that is what makes the
/// `@unchecked Sendable` true).
final class CaptureCore: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.camera", qos: .userInitiated)
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    /// Time-lapses: the frames, of which `timeLapse` keeps a few.
    private let frameOutput = AVCaptureVideoDataOutput()
    private let timeLapse = TimeLapseRecorder()
    private var timeLapsing = false
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
    private var wantRunning = false
    private var observers: [NSObjectProtocol] = []
    /// Gets every new state (and the camera, when it changed).
    var changed: (@Sendable (CameraState, Carry<AVCaptureDevice>?) -> Void)?

    override init() {
        super.init()
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.setSampleBufferDelegate(timeLapse, queue: timeLapse.queue)
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

    /// The back camera with the most lenses there are, or the front camera. For slow motion the
    /// first that can record that fast (not every camera made of several lenses can).
    static func camera(_ side: CameraSide, mode: CameraMode = .photo, options: CaptureOptions? = nil)
        -> AVCaptureDevice?
    {
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

    func startRunning() {
        wantRunning = true
        if !session.isRunning { session.startRunning() }
    }

    func stopRunning() {
        wantRunning = false
        if movieOutput.isRecording { movieOutput.stopRecording() }
        if timeLapsing {
            timeLapsing = false
            timeLapse.finish { _, _ in }
        }
        if session.isRunning { session.stopRunning() }
    }

    private func publish(device: AVCaptureDevice?) {
        changed?(state, device.map(Carry.init))
    }

    /// Only this output in the session.
    private func use(_ output: AVCaptureOutput) {
        for other in [photoOutput, movieOutput, frameOutput] as [AVCaptureOutput] where other !== output {
            if session.outputs.contains(other) { session.removeOutput(other) }
        }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
    }

    /// Photo: the photo output in the best quality the camera has. Video and slow motion: the
    /// movie output with the chosen format, HEVC, stabilized, with sound when allowed. Time-lapse:
    /// the frames, without sound.
    private func apply(mode: CameraMode, on device: AVCaptureDevice) {
        session.automaticallyConfiguresCaptureDeviceForWideColor = mode == .photo
        switch mode {
        case .photo:
            use(photoOutput)
            // Live Photos record sound; plain photos need no microphone.
            let live = video?.live == true
            if live {
                addMicrophone()
            } else if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            photoOutput.maxPhotoQualityPrioritization = .quality
            if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                $0.width * $0.height < $1.width * $1.height
            }) {
                photoOutput.maxPhotoDimensions = largest
            }
            if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
            photoOutput.isLivePhotoCaptureEnabled = live && photoOutput.isLivePhotoCaptureSupported
            if photoOutput.isLivePhotoCaptureEnabled { photoOutput.isLivePhotoAutoTrimmingEnabled = true }
            state.videoFormat = nil
        case .video, .slowMotion:
            use(movieOutput)
            addMicrophone()
            if let video {
                if mode == .slowMotion {
                    applyVideoFormat(
                        sizes: [(1920, 1080)], rate: Double(video.slowMotionRate), hdr: false, on: device)
                } else {
                    applyVideoFormat(
                        sizes: video.resolution == .uhd4K ? [(3840, 2160), (1920, 1080)] : [(1920, 1080)],
                        rate: Double(video.frameRate), hdr: video.hdr, on: device)
                }
            }
            if let connection = movieOutput.connection(with: .video) {
                if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        case .timeLapse:
            use(frameOutput)
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if let video {
                applyVideoFormat(
                    sizes: video.resolution == .uhd4K ? [(3840, 2160), (1920, 1080)] : [(1920, 1080)], rate: 30,
                    hdr: false, on: device)
                state.videoFormat = video.timeLapseInterval.map { "every \(CameraMode.intervalText($0))" } ?? "Auto"
            }
            if let connection = frameOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
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
    /// bit with HLG) or not. What was actually chosen is shown on the camera screen.
    private func applyVideoFormat(sizes: [(Int, Int)], rate: Double, hdr wantHDR: Bool, on device: AVCaptureDevice) {
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
            pool.first { wantHDR ? tenBit($0) && $0.supportedColorSpaces.contains(.HLG_BT2020) : !tenBit($0) }
            ?? pool[0]
        let used = min(rate, maxRate(format)).rounded()
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        let frame = CMTime(value: 1, timescale: CMTimeScale(used))
        device.activeVideoMinFrameDuration = frame
        device.activeVideoMaxFrameDuration = frame
        if wantHDR, format.supportedColorSpaces.contains(.HLG_BT2020) {
            device.activeColorSpace = .HLG_BT2020
        } else if format.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        device.unlockForConfiguration()
        let (width, _) = dimensions(format)
        let hdr = device.activeColorSpace == .HLG_BT2020
        state.videoFormat = "\(width >= 3840 ? "4K" : "1080p") · \(Int(used)) fps\(hdr ? " · HDR" : "")"
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
        var described = CameraState()
        described.ready = true
        described.side = side
        described.canFlip = Self.camera(side == .back ? .front : .back) != nil
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
        let highest = min(Double(device.maxAvailableVideoZoomFactor) * multiplier, max(10, (presets.max() ?? 1) * 5))
        described.presets = presets.filter { $0 <= highest }.sorted()
        described.zoomRange = lowest...max(lowest, highest)
        described.zoom = Double(device.videoZoomFactor) * multiplier
        described.hasFlash = device.hasFlash
        described.hasTorch = device.hasTorch
        described.canLive = mode == .photo && photoOutput.isLivePhotoCaptureSupported
        described.manualLimits = limits(of: device)
        described.focusLocked = state.focusLocked
        described.videoFormat = state.videoFormat
        return described
    }

    /// Always a ramp: a glide for the lens buttons (about the same time for any distance), and
    /// a quick one that follows a finger smoothly. The camera switches lenses on the way where
    /// Apple's camera does.
    func zoom(to shown: Double, glide: Bool) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
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
            canSetWhiteBalance: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported)
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
        if let focus = set.focus {
            device.setFocusModeLocked(lensPosition: Float(focus))
        } else if device.focusMode == .locked, !state.focusLocked,
            device.isFocusModeSupported(.continuousAutoFocus)
        {
            device.focusMode = .continuousAutoFocus
        }
    }

    /// `point` in the camera's coordinates (0…1). Locked: focus and expose once, then keep.
    /// What is set by hand stays.
    func focus(at point: CGPoint, lock: Bool) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
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

    func takePhoto(_ request: PhotoRequest, angle: CGFloat, done: @escaping @Sendable (TakenPhoto?) -> Void) {
        guard mode == .photo, session.isRunning, let connection = photoOutput.connection(with: .video) else {
            return done(nil)
        }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        let heic = request.format == .heic && photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: heic ? AVVideoCodecType.hevc : .jpeg])
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        let flash: AVCaptureDevice.FlashMode =
            switch request.flash {
            case .auto: .auto
            case .on: .on
            case .off: .off
            }
        if photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        if request.live, photoOutput.isLivePhotoCaptureEnabled {
            settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mov")
            if photoOutput.availableLivePhotoVideoCodecTypes.contains(.hevc) {
                settings.livePhotoVideoCodecType = .hevc
            }
            settings.livePhotoMovieMetadata = VideoMetadata.items(
                location: request.location, takenAt: request.takenAt, timeZone: .current)
        }
        let id = settings.uniqueID
        let capture = PhotoCapture(request: request, heic: heic) { [weak self] photo in
            self?.run { $0.photos[id] = nil }
            done(photo)
        }
        photos[id] = capture
        photoOutput.capturePhoto(with: settings, delegate: capture)
    }

    func startRecording(_ request: VideoRequest, angle: CGFloat) {
        let metadata = VideoMetadata.items(
            location: request.location, takenAt: request.takenAt, timeZone: request.timeZone)
        if mode == .timeLapse {
            guard session.isRunning, !timeLapsing, let connection = frameOutput.connection(with: .video) else { return }
            // The frames come upright, so the file needs no turning.
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            timeLapsing = true
            timeLapse.begin(url: request.url, fixedInterval: video?.timeLapseInterval, metadata: metadata)
            return
        }
        guard mode.records, session.isRunning, !movieOutput.isRecording,
            let connection = movieOutput.connection(with: .video)
        else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        movieOutput.metadata = metadata
        let recording = Recording()
        self.recording = recording
        movieOutput.startRecording(to: request.url, recordingDelegate: recording)
    }

    /// The finished file, and for a time-lapse which stretches were taken how often.
    func stopRecording(done: @escaping @Sendable (URL?, TimeLapsePlan?) -> Void) {
        if timeLapsing {
            timeLapsing = false
            return timeLapse.finish { url, plan in done(url, plan) }
        }
        guard let recording else { return done(nil, nil) }
        self.recording = nil
        recording.whenFinished { done($0, nil) }
        if movieOutput.isRecording { movieOutput.stopRecording() }
    }
}

/// One photo on its way out of the camera.
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let request: PhotoRequest
    let heic: Bool
    let done: @Sendable (TakenPhoto?) -> Void
    private var photo: TakenPhoto?
    private var movie: URL?

    init(request: PhotoRequest, heic: Bool, done: @escaping @Sendable (TakenPhoto?) -> Void) {
        self.request = request
        self.heic = heic
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
            let data = photo.fileDataRepresentation(
                with: GPSWriter(location: request.location, trueNorth: request.trueNorth, at: request.takenAt))
        else { return }
        let size = Thumbnails.shownSize(of: data)
        let dimensions = photo.resolvedSettings.photoDimensions
        self.photo = TakenPhoto(
            data: data, heic: heic, width: size?.width ?? Int(dimensions.width),
            height: size?.height ?? Int(dimensions.height))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
    ) {
        if error == nil { movie = outputFileURL }
    }

    /// Called last, after the photo and (for a Live Photo) its video.
    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if var photo, let movie, FileManager.default.fileExists(atPath: movie.path) {
            photo.liveVideo = movie
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

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let location else { return nil }
        var metadata = photo.metadata
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(location.latitude),
            kCGImagePropertyGPSLatitudeRef as String: location.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(location.longitude),
            kCGImagePropertyGPSLongitudeRef as String: location.longitude >= 0 ? "E" : "W",
        ]
        let utc = TimeZone(identifier: "UTC")!
        let time = DateFormatter()
        time.timeZone = utc
        time.dateFormat = "HH:mm:ss.SS"
        let day = DateFormatter()
        day.timeZone = utc
        day.dateFormat = "yyyy:MM:dd"
        gps[kCGImagePropertyGPSTimeStamp as String] = time.string(from: moment)
        gps[kCGImagePropertyGPSDateStamp as String] = day.string(from: moment)
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
