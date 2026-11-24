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
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var mode = CameraMode.photo
    @ObservationIgnored private var video: VideoOptions?

    init() {
        preview.previewLayer.session = core.session
        preview.previewLayer.videoGravity = .resizeAspectFill
        core.changed = { [weak self] state, device in
            Task { @MainActor in self?.update(state, device: device?.value) }
        }
    }

    static var allowed: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    func prepare(mode: CameraMode, video: VideoOptions) {
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

    func setMode(_ mode: CameraMode, video: VideoOptions) {
        self.mode = mode
        self.video = video
        Task {
            // Sound for videos; without the microphone they are recorded silent.
            if mode == .video, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
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

    func zoom(to factor: Double, smoothly: Bool) {
        state.zoom = min(max(factor, state.zoomRange.lowerBound), state.zoomRange.upperBound)
        core.run { $0.zoom(to: factor, smoothly: smoothly) }
    }

    func focus(at point: CGPoint, lock: Bool) {
        let devicePoint = preview.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        core.run { $0.focus(at: devicePoint, lock: lock) }
    }

    func setTorch(_ on: Bool) {
        core.run { $0.torch(on) }
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
        await withCheckedContinuation { continuation in
            core.run { $0.stopRecording { continuation.resume(returning: $0) } }
        }
    }

    private func update(_ new: CameraState, device: AVCaptureDevice?) {
        state = new
        guard let device, device !== rotation?.device else { return }
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

/// Everything that touches AVFoundation. Only ever used on `queue` (that is what makes the
/// `@unchecked Sendable` true).
final class CaptureCore: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.camera", qos: .userInitiated)
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var input: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var mode = CameraMode.photo
    private var video: VideoOptions?
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

    /// The back camera with the most lenses there are, or the front camera.
    static func camera(_ side: CameraSide) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] =
            side == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: side == .back ? .back : .front) {
                return device
            }
        }
        return nil
    }

    func configure(side: CameraSide, mode: CameraMode, video: VideoOptions?) {
        self.side = side
        self.mode = mode
        self.video = video
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        input = nil
        guard let device = Self.camera(side), let newInput = try? AVCaptureDeviceInput(device: device),
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

    func change(mode: CameraMode, video: VideoOptions) {
        guard let device, !movieOutput.isRecording else { return }
        self.mode = mode
        self.video = video
        session.beginConfiguration()
        apply(mode: mode, on: device)
        session.commitConfiguration()
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
        if session.isRunning { session.stopRunning() }
    }

    private func publish(device: AVCaptureDevice?) {
        changed?(state, device.map(Carry.init))
    }

    /// Photo: the photo output in the best quality the camera has. Video: the movie output with
    /// the chosen format, HEVC, stabilized, with sound when allowed.
    private func apply(mode: CameraMode, on device: AVCaptureDevice) {
        session.automaticallyConfiguresCaptureDeviceForWideColor = mode == .photo
        switch mode {
        case .photo:
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            if let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            photoOutput.maxPhotoQualityPrioritization = .quality
            if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                $0.width * $0.height < $1.width * $1.height
            }) {
                photoOutput.maxPhotoDimensions = largest
            }
            if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
            state.videoFormat = nil
        case .video:
            if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            if audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                let microphone = AVCaptureDevice.default(for: .audio),
                let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input)
            {
                session.addInput(input)
                audioInput = input
            }
            if let video { applyVideoFormat(video, on: device) }
            if let connection = movieOutput.connection(with: .video) {
                if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                    movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        }
    }

    /// The format closest to what was asked: the size first, then the frame rate, then HDR (10
    /// bit with HLG) or not. What was actually chosen is shown on the camera screen.
    private func applyVideoFormat(_ options: VideoOptions, on device: AVCaptureDevice) {
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
        let sizes: [(Int, Int)] = options.resolution == .uhd4K ? [(3840, 2160), (1920, 1080)] : [(1920, 1080)]
        let sized =
            sizes.lazy.map { size in device.formats.filter { dimensions($0) == size } }.first { !$0.isEmpty }
            ?? []
        guard !sized.isEmpty else {
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            state.videoFormat = nil
            return
        }
        let rate = Double(options.frameRate)
        let fast = sized.filter { maxRate($0) >= rate }
        let pool = fast.isEmpty ? sized : fast
        let format =
            pool.first { options.hdr ? tenBit($0) && $0.supportedColorSpaces.contains(.HLG_BT2020) : !tenBit($0) }
            ?? pool[0]
        let used = min(rate, maxRate(format)).rounded()
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        let frame = CMTime(value: 1, timescale: CMTimeScale(used))
        device.activeVideoMinFrameDuration = frame
        device.activeVideoMaxFrameDuration = frame
        if options.hdr, format.supportedColorSpaces.contains(.HLG_BT2020) {
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
        described.focusLocked = state.focusLocked
        described.videoFormat = state.videoFormat
        return described
    }

    func zoom(to shown: Double, smoothly: Bool) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        let factor = CGFloat(
            min(
                max(shown / multiplier, Double(device.minAvailableVideoZoomFactor)),
                Double(device.maxAvailableVideoZoomFactor)))
        if smoothly {
            device.ramp(toVideoZoomFactor: factor, withRate: 6)
        } else {
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = factor
        }
        device.unlockForConfiguration()
        state.zoom = Double(factor) * multiplier
        publish(device: nil)
    }

    /// `point` in the camera's coordinates (0…1). Locked: focus and expose once, then keep.
    func focus(at point: CGPoint, lock: Bool) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
        let focusMode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
        if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
        let exposureMode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
        if device.isExposureModeSupported(exposureMode) { device.exposureMode = exposureMode }
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
        let id = settings.uniqueID
        let capture = PhotoCapture(request: request, heic: heic) { [weak self] photo in
            self?.run { $0.photos[id] = nil }
            done(photo)
        }
        photos[id] = capture
        photoOutput.capturePhoto(with: settings, delegate: capture)
    }

    func startRecording(_ request: VideoRequest, angle: CGFloat) {
        guard mode == .video, session.isRunning, !movieOutput.isRecording,
            let connection = movieOutput.connection(with: .video)
        else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        movieOutput.metadata = VideoMetadata.items(
            location: request.location, takenAt: request.takenAt, timeZone: request.timeZone)
        let recording = Recording()
        self.recording = recording
        movieOutput.startRecording(to: request.url, recordingDelegate: recording)
    }

    func stopRecording(done: @escaping @Sendable (URL?) -> Void) {
        guard let recording else { return done(nil) }
        self.recording = nil
        recording.whenFinished(done)
        if movieOutput.isRecording { movieOutput.stopRecording() }
    }
}

/// One photo on its way out of the camera.
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let request: PhotoRequest
    let heic: Bool
    let done: @Sendable (TakenPhoto?) -> Void
    private var photo: TakenPhoto?

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
        _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
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
