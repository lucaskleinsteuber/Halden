import CoreImage
import HaldenKit
import Observation
import UIKit

/// A camera for the simulator (which has none) and the UI tests: it behaves like the real one
/// (lenses, zoom, flash, photo and video) and delivers made-up photos and short videos, each one
/// different, so the whole way from the shutter to the server can be tested.
@MainActor
@Observable
final class StandInCamera: CaptureBackend {
    private static var basicDevice: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-basic-device")
    }

    /// The iPhone the stand-in pretends to be (`-ui-testing-device iPhone15,4`), if any.
    static let profile: DeviceProfile? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ui-testing-device"), index + 1 < arguments.count else {
            return nil
        }
        return DeviceProfile.named(arguments[index + 1])
    }()

    private static var capabilities: DeviceCapabilities {
        if let profile { return profile.capabilities }
        return basicDevice ? .basic : .all
    }

    private static var backPresets: [Double] { profile?.backZoomPresets ?? [0.5, 1, 2] }

    private static var backRange: ClosedRange<Double> {
        (backPresets.first ?? 1)...10
    }

    private static var resolutions: [PhotoResolution] {
        if let profile { return profile.has48MP ? [.mp12, .mp24, .mp48] : [.mp12] }
        return [.mp12, .mp24, .mp48]
    }

    private(set) var state = CameraState(
        ready: true, side: .back, canFlip: true, presets: StandInCamera.backPresets,
        zoomRange: StandInCamera.backRange,
        hasFlash: true, hasTorch: true, canLive: true, canRAW: StandInCamera.capabilities.canBayerRAW,
        availableResolutions: StandInCamera.resolutions,
        lensSmudged: ProcessInfo.processInfo.arguments.contains("-ui-testing-smudge"),
        canDepth: true,
        subjectDetected: ProcessInfo.processInfo.arguments.contains("-ui-testing-subject"),
        canCinematic: StandInCamera.capabilities.canCinematic || StandInCamera.basicDevice,
        canMultiCam: (StandInCamera.profile?.multiCam ?? true) && !StandInCamera.basicDevice,
        canWindNoiseRemoval: StandInCamera.capabilities.canWindNoiseRemoval,
        capabilities: StandInCamera.capabilities,
        externalStorage: ProcessInfo.processInfo.arguments.contains("-ui-testing-ssd")
            && StandInCamera.capabilities.canExternalStorage
            ? ExternalStorageInfo(displayName: "Halden SSD", freeBytes: 512 * 1024 * 1024 * 1024) : nil,
        macroActive: ProcessInfo.processInfo.arguments.contains("-ui-testing-macro")
            && StandInCamera.capabilities.canMacroControl,
        manualLimits: ManualLimits(
            shutter: (1.0 / 8000)...1, iso: 50...3200, exposureBias: -8...8, kelvin: 2500...9500))
    private(set) var zoomNow = 1.0
    private(set) var lookSample: CGImage?
    private(set) var reconfigurations = 0
    private(set) var readings =
        ProcessInfo.processInfo.arguments.contains("-ui-testing-night")
            || ProcessInfo.processInfo.arguments.contains("-ui-testing-low-light")
        ? CameraReadings(shutter: 1.0 / 15, iso: 2000, kelvin: 4800, tint: 0, focus: 0.5)
        : CameraReadings(shutter: 1.0 / 120, iso: 100, kelvin: 5200, tint: 0, focus: 0.5)
    private(set) var liveScopes: LiveScopesData?
    private(set) var dualPipImage: UIImage?
    @ObservationIgnored private let standInPreview = StandInPreview()
    var previewView: UIView { standInPreview }
    @ObservationIgnored private var taken = 0
    @ObservationIgnored private var recording: (request: VideoRequest, started: Date)?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var quickTaking = false
    @ObservationIgnored private var mode = CameraMode.photo
    @ObservationIgnored private var panoramaDirection: PanoramaDirection?
    @ObservationIgnored private var dualSwapped = false
    @ObservationIgnored private var gliding: Task<Void, Never>?
    @ObservationIgnored private var watchFrameTask: Task<Void, Never>?
    @ObservationIgnored private var options: CaptureOptions?

    func prepare(mode: CameraMode, options video: CaptureOptions) {
        self.mode = mode
        options = video
        updatePreviewLook(mode: mode, options: video)
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-smudge") {
            state.lensSmudged = true
        }
    }

    private func updatePreviewLook(mode: CameraMode, options video: CaptureOptions) {
        let scopesOn = video.showHistogram || video.showWaveform
        liveScopes = scopesOn ? LiveScopesAnalyzer.sample() : nil
        let filter = video.filterIntensity > 0.005 ? video.filter : nil
        let custom = LookRenderer.needsCustomPreview(
            style: mode.isStill ? video.style : nil, filter: mode.isStill ? filter : nil,
            isPortrait: mode == .portrait, showScopes: scopesOn)
        state.customPreviewActive = custom
        let args = ProcessInfo.processInfo.arguments
        state.detectedQR =
            mode == .photo && video.scanQRCodes && args.contains("-ui-testing-qr")
            ? QRPayloadParser.parse("https://halden.example/visit")
            : nil
        state.detectedText =
            mode == .photo && video.showLiveText && args.contains("-ui-testing-text")
            ? "Halden Cafe\nOpen 08:00 - 19:00"
            : nil
        standInPreview.applyLook(
            style: mode.isStill ? video.style : nil, filter: mode.isStill ? video.filter : nil,
            filterIntensity: video.filterIntensity, portraitAperture: mode == .portrait ? video.portraitAperture : nil,
            portraitLighting: mode == .portrait ? video.portraitLighting : nil)
    }

    func start() {}
    func stop() {
        watchFrameTask?.cancel()
        watchFrameTask = nil
    }

    func applyLook(_ options: CaptureOptions) {
        self.options = options
        updatePreviewLook(mode: mode, options: options)
    }

    func applyDevice(_ options: CaptureOptions) {
        self.options = options
        updatePreviewLook(mode: mode, options: options)
    }

    func sampleLooks(_ on: Bool) {
        lookSample = on ? StandInPreview.scene : nil
    }

    /// Takes about as long as the real camera to change its format.
    func setMode(_ mode: CameraMode, options video: CaptureOptions) async {
        reconfigurations += 1
        options = video
        try? await Task.sleep(for: .milliseconds(200))
        self.mode = mode
        updatePreviewLook(mode: mode, options: video)
        state.canLive = mode == .photo
        state.canRAW = mode == .photo
        state.canDepth = mode.isStill
        if mode == .dual {
            state.presets = dualSwapped ? [1] : [1, 2]
            state.zoomRange = dualSwapped ? 1...1 : 1...5
            zoomNow = 1
        } else {
            state.presets = state.side == .back ? Self.backPresets : [1]
            state.zoomRange = state.side == .back ? Self.backRange : 1...5
            zoomNow = min(max(zoomNow, state.zoomRange.lowerBound), state.zoomRange.upperBound)
        }
        state.portraitHint =
            mode == .portrait && ProcessInfo.processInfo.arguments.contains("-ui-testing-portrait-hint")
            ? .moveFartherAway : nil
        state.availableResolutions = Self.resolutions
        let fpsText = CameraControls.frameRateLabel(video.frameRate)
        let hdrSuffix = video.hdr ? " · HDR" : ""
        let autoSuffix = video.autoLowLightFPS ? " · Auto" : ""
        let proFormat = ProDeviceRules.effectiveVideoFormat(
            wanted: video.proVideoFormat, capabilities: state.capabilities)
        let proSuffix =
            switch proFormat {
            case .standard: ""
            case .proRes: " · ProRes"
            case .proResLog: " · ProRes Log"
            }
        state.videoFormat =
            switch mode {
            case .photo, .portrait, .panorama, .dual: nil
            case .video:
                "\(video.resolution == .uhd4K ? "4K" : "1080p") · \(fpsText)\(proSuffix)\(hdrSuffix)\(autoSuffix)"
                    + (video.actionMode && state.capabilities.canActionMode ? " · Action" : "")
            case .cinematic: "Cinematic · \(CinematicRules.formatAperture(video.cinematicAperture))"
            case .slowMotion: "1080p · \(video.slowMotionRate) fps"
            case .timeLapse: video.timeLapseInterval.map { "every \(CameraMode.intervalText($0))" } ?? "Auto"
            case .spatial: "Spatial · 1080p · 30 fps"
            }
    }

    func flip() async {
        reconfigurations += 1
        try? await Task.sleep(for: .milliseconds(150))
        state.side = state.side == .back ? .front : .back
        state.presets = state.side == .back ? Self.backPresets : [1]
        state.zoomRange = state.side == .back ? Self.backRange : 1...5
        zoomNow = 1
        state.hasFlash = state.side == .back
    }

    /// Glides like the real camera, in doublings, so the screen can be tried in the simulator.
    func zoom(to factor: Double, glide: Bool) {
        let target = min(max(factor, state.zoomRange.lowerBound), state.zoomRange.upperBound)
        gliding?.cancel()
        guard glide else {
            zoomNow = target
            return
        }
        let start = zoomNow
        gliding = Task { [weak self] in
            let steps = 18
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(Zoom.glideSeconds / Double(steps)))
                if Task.isCancelled { return }
                self?.zoomNow = start * pow(target / start, Double(step) / Double(steps))
            }
        }
    }

    func focus(at point: CGPoint, lock: Bool) {
        state.focusLocked = lock
    }

    func setTorch(_ on: Bool) {}

    func setManual(_ settings: ManualSettings) {
        readings.shutter = settings.shutter ?? 1.0 / 120
        readings.iso = settings.iso ?? 100
        readings.kelvin = settings.whiteBalance?.kelvin ?? 5200
        readings.focus = settings.focus ?? 0.5
    }

    /// A seed that differs between photos and between runs of the app.
    private func nextSeed() -> Int {
        taken += 1
        return Int(Date().timeIntervalSince1970 * 1000) &* 31 &+ taken
    }

    func takePhoto(_ request: PhotoRequest, preview: (@Sendable (CGImage) -> Void)?) async -> TakenPhoto? {
        guard mode.isStill else { return nil }
        let seed = nextSeed()
        let data = await Task.detached { SampleMedia.photo(seed: seed) }.value
        guard let data else { return nil }
        if let preview, let small = PhotoCapture.small(data) { preview(small) }
        var photo = TakenPhoto(data: data, heic: false, width: 1600, height: 1200)
        if request.raw || request.proRAW {
            photo.rawData = data
        } else if request.live {
            let movie = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            if (try? await SampleMedia.video(at: movie, seed: seed, seconds: 1)) != nil { photo.liveVideo = movie }
        }
        return photo
    }

    func takeNightBurst(
        count: Int, request: PhotoRequest, onFrame: @MainActor @escaping (Int, Int) -> Void
    ) async -> [Data] {
        guard mode == .photo else { return [] }
        let total = max(1, count)
        let baseSeed = nextSeed()
        var frames: [Data] = []
        frames.reserveCapacity(total)
        for index in 0..<total {
            try? await Task.sleep(for: .milliseconds(45))
            if let data = await Task.detached(operation: {
                SampleMedia.photo(seed: baseSeed, width: 640, height: 480)
            }).value {
                frames.append(data)
            }
            onFrame(index + 1, total)
        }
        return frames
    }

    func takeStillWhileRecording(_ request: PhotoRequest) async -> TakenPhoto? {
        guard recording != nil else { return nil }
        let seed = nextSeed()
        let data = await Task.detached { SampleMedia.photo(seed: seed) }.value
        guard let data else { return nil }
        return TakenPhoto(data: data, heic: false, width: 1600, height: 1200)
    }

    func startRecording(_ request: VideoRequest) -> Bool {
        guard mode.records, recording == nil else { return false }
        paused = false
        quickTaking = false
        recording = (request, Date())
        return true
    }

    func startQuickTake(_ request: VideoRequest) -> Bool {
        guard mode == .photo, recording == nil else { return false }
        paused = false
        quickTaking = true
        recording = (request, Date())
        return true
    }

    func pauseRecording() {
        guard recording != nil else { return }
        paused = true
    }

    func resumeRecording() {
        guard recording != nil else { return }
        paused = false
    }

    func stopRecording() async -> URL? {
        guard let (request, started) = recording else { return nil }
        recording = nil
        paused = false
        quickTaking = false
        let seconds = min(max(Date().timeIntervalSince(started), 1), 5)
        let seed = nextSeed()
        do {
            try await SampleMedia.video(
                at: request.url, seed: seed, seconds: seconds,
                metadata: VideoMetadata.items(
                    location: request.location, takenAt: request.takenAt, timeZone: request.timeZone))
            return request.url
        } catch {
            return nil
        }
    }

    func takeDualPhoto(_ request: PhotoRequest, corner: PiPCorner, swapped: Bool) async -> TakenPhoto? {
        guard mode == .dual else { return nil }
        let preferHEIC = request.format == .heic
        return await Task.detached(priority: .userInitiated) {
            let back = CIImage(color: CIColor(red: 0.14, green: 0.32, blue: 0.62, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 960, height: 1280))
            let front = CIImage(color: CIColor(red: 0.85, green: 0.42, blue: 0.25, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 480, height: 640))
            let primary = swapped ? front : back
            let secondary = swapped ? back : front
            guard
                let encoded = DualCompositor.encodePhoto(
                    primary: primary, secondary: secondary, corner: corner, preferHEIC: preferHEIC)
            else { return nil }
            return TakenPhoto(data: encoded.data, heic: encoded.heic, width: encoded.width, height: encoded.height)
        }.value
    }

    func startDualRecording(_ request: VideoRequest, corner: PiPCorner, swapped: Bool) -> Bool {
        guard mode == .dual, recording == nil else { return false }
        paused = false
        quickTaking = false
        recording = (request, Date())
        return true
    }

    func updateDualLayout(corner: PiPCorner, swapped: Bool) {
        dualSwapped = swapped
        if mode == .dual {
            state.presets = swapped ? [1] : [1, 2]
            state.zoomRange = swapped ? 1...1 : 1...5
            zoomNow = 1
        }
    }

    func setWatchFrameHandler(_ handler: (@Sendable (Data) -> Void)?) {
        watchFrameTask?.cancel()
        watchFrameTask = nil
        guard let handler else { return }
        watchFrameTask = Task { [weak self] in
            let context = CIContext(options: [.cacheIntermediates: false])
            while !Task.isCancelled {
                let isFront = self?.state.side == .front
                let jpeg = await Task.detached(priority: .utility) { () -> Data? in
                    let color =
                        isFront
                        ? CIColor(red: 0.85, green: 0.45, blue: 0.25) : CIColor(red: 0.16, green: 0.52, blue: 0.85)
                    let ci = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 180, height: 240))
                    guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
                    return UIImage(cgImage: cg).jpegData(compressionQuality: 0.45)
                }.value
                if let jpeg, !Task.isCancelled { handler(jpeg) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func startPanorama(direction: PanoramaDirection) -> Bool {
        guard mode == .panorama, panoramaDirection == nil else { return false }
        panoramaDirection = direction
        return true
    }

    func stopPanorama(request: PhotoRequest) async -> TakenPhoto? {
        guard let direction = panoramaDirection else { return nil }
        panoramaDirection = nil
        let preferHEIC = request.format == .heic
        return await Task.detached(priority: .userInitiated) {
            let sceneW = direction.isVertical ? 320 : 960
            let sceneH = direction.isVertical ? 960 : 320
            var bytes = [UInt8](repeating: 255, count: sceneW * sceneH * 4)
            var rng: UInt64 = 0x517C_C1B7_2722_0A95
            for y in 0..<sceneH {
                for x in 0..<sceneW {
                    let idx = (y * sceneW + x) * 4
                    bytes[idx] = UInt8(60 + (x * 110) / sceneW)
                    bytes[idx + 1] = UInt8(85 + (y * 90) / sceneH)
                    bytes[idx + 2] = UInt8(140 - (x * 40) / sceneW)
                }
            }
            for _ in 0..<70 {
                rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let rw = 16 + Int((rng >> 32) % 36)
                let rh = 16 + Int((rng >> 40) % 36)
                rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let rx = Int((rng >> 32) % UInt64(max(1, sceneW - rw)))
                let ry = Int((rng >> 40) % UInt64(max(1, sceneH - rh)))
                let r = UInt8(40 + (rng >> 16) % 200)
                let g = UInt8(40 + (rng >> 24) % 200)
                let b = UInt8(40 + (rng >> 8) % 200)
                for y in ry..<(ry + rh) {
                    for x in rx..<(rx + rw) {
                        let idx = (y * sceneW + x) * 4
                        bytes[idx] = r
                        bytes[idx + 1] = g
                        bytes[idx + 2] = b
                    }
                }
            }
            let scene = CIImage(
                bitmapData: Data(bytes), bytesPerRow: sceneW * 4,
                size: CGSize(width: sceneW, height: sceneH), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            var tiles: [CIImage] = []
            for i in 0..<4 {
                if direction.isVertical {
                    let y = i * 160
                    tiles.append(scene.cropped(to: CGRect(x: 0, y: y, width: 320, height: 420)))
                } else {
                    let x = i * 160
                    tiles.append(scene.cropped(to: CGRect(x: x, y: 0, width: 420, height: 320)))
                }
            }
            let ordered = (direction == .rightToLeft || direction == .topToBottom) ? Array(tiles.reversed()) : tiles
            guard
                let stitched = PanoramaStitcher.stitch(
                    frames: ordered, direction: direction, preferHEIC: preferHEIC)
            else { return nil }
            return TakenPhoto(
                data: stitched.data, heic: stitched.heic, width: stitched.width, height: stitched.height)
        }.value
    }
}

/// What the stand-in camera "sees": a small made-up landscape with sky, sun, hills and a face,
/// so styles and filters can be judged in the simulator; looks are drawn with Core Image.
final class StandInPreview: UIView {
    private let sceneView = UIImageView()
    private let lookImageView = UIImageView()
    private static let ciContext = CIContext()

    /// The scene, 360 × 480 points.
    static let scene: CGImage? = {
        let size = CGSize(width: 360, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky =
                [
                    UIColor(red: 0.28, green: 0.55, blue: 0.92, alpha: 1).cgColor,
                    UIColor(red: 0.98, green: 0.78, blue: 0.55, alpha: 1).cgColor,
                ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: sky, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 300), options: [])
            }
            cg.setFillColor(UIColor(red: 1, green: 0.86, blue: 0.4, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 240, y: 70, width: 70, height: 70))
            cg.setFillColor(UIColor(red: 0.22, green: 0.52, blue: 0.25, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: -120, y: 250, width: 420, height: 300))
            cg.setFillColor(UIColor(red: 0.35, green: 0.62, blue: 0.3, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 120, y: 290, width: 400, height: 280))
            cg.setFillColor(UIColor(red: 0.85, green: 0.25, blue: 0.22, alpha: 1).cgColor)
            cg.fill(CGRect(x: 40, y: 330, width: 90, height: 70))
            cg.setFillColor(UIColor(red: 0.93, green: 0.73, blue: 0.6, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 170, y: 330, width: 90, height: 110))
            cg.setFillColor(UIColor(red: 0.25, green: 0.18, blue: 0.14, alpha: 1).cgColor)
            cg.fill(CGRect(x: 165, y: 320, width: 100, height: 30))
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: 60, y: 120, width: 110, height: 28))
        }
        return image.cgImage
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        for view in [sceneView, lookImageView] {
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        sceneView.image = Self.scene.map { UIImage(cgImage: $0) }
        lookImageView.isHidden = true
        let label = UILabel()
        label.text = "Stand-in camera"
        label.textColor = .white.withAlphaComponent(0.8)
        label.shadowColor = .black.withAlphaComponent(0.65)
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        accessibilityIdentifier = "stand-in-camera"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyLook(
        style: PhotographicStyle?, filter: PhotoFilter?, filterIntensity: Double = 1,
        portraitAperture: Double? = nil, portraitLighting: PortraitLighting? = nil
    ) {
        let isPortrait = portraitAperture != nil || (portraitLighting != nil && portraitLighting != .natural)
        let shownFilter = filterIntensity > 0.005 ? filter : nil
        guard LookRenderer.needsCustomPreview(style: style, filter: shownFilter, isPortrait: isPortrait),
            let scene = Self.scene
        else {
            lookImageView.isHidden = true
            lookImageView.image = nil
            return
        }
        var image = CIImage(cgImage: scene)
        if isPortrait {
            image = PortraitRenderer.apply(to: image, aperture: portraitAperture, lighting: portraitLighting)
        }
        let styled = LookRenderer.apply(
            style: style, filter: shownFilter, filterIntensity: filterIntensity, to: image
        ).cropped(to: image.extent)
        if let cg = Self.ciContext.createCGImage(styled, from: image.extent) {
            lookImageView.image = UIImage(cgImage: cg)
            lookImageView.isHidden = false
        }
    }
}
