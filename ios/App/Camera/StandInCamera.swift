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
    private(set) var state = CameraState(
        ready: true, side: .back, canFlip: true, presets: [0.5, 1, 2], zoom: 1, zoomRange: 0.5...10,
        hasFlash: true, hasTorch: true, canLive: true, canRAW: true,
        availableResolutions: [.mp12, .mp24, .mp48],
        lensSmudged: ProcessInfo.processInfo.arguments.contains("-ui-testing-smudge"),
        canDepth: true,
        subjectDetected: ProcessInfo.processInfo.arguments.contains("-ui-testing-subject"),
        manualLimits: ManualLimits(shutter: (1.0 / 8000)...1, iso: 50...3200, exposureBias: -8...8))
    private(set) var readings =
        ProcessInfo.processInfo.arguments.contains("-ui-testing-night")
        ? CameraReadings(shutter: 1.0 / 15, iso: 2000, kelvin: 4800, tint: 0, focus: 0.5)
        : CameraReadings(shutter: 1.0 / 120, iso: 100, kelvin: 5200, tint: 0, focus: 0.5)
    @ObservationIgnored private let standInPreview = StandInPreview()
    var previewView: UIView { standInPreview }
    @ObservationIgnored private var taken = 0
    @ObservationIgnored private var recording: (request: VideoRequest, started: Date)?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var quickTaking = false
    @ObservationIgnored private var mode = CameraMode.photo
    @ObservationIgnored private var gliding: Task<Void, Never>?

    func prepare(mode: CameraMode, options video: CaptureOptions) {
        self.mode = mode
        updatePreviewLook(mode: mode, options: video)
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-smudge") {
            state.lensSmudged = true
        }
    }

    private func updatePreviewLook(mode: CameraMode, options video: CaptureOptions) {
        let custom =
            mode.isStill
            && LookRenderer.needsCustomPreview(
                style: video.style, filter: video.filter, isPortrait: mode == .portrait)
        state.customPreviewActive = custom
        standInPreview.applyLook(
            style: mode.isStill ? video.style : nil, filter: mode.isStill ? video.filter : nil,
            portraitAperture: mode == .portrait ? video.portraitAperture : nil,
            portraitLighting: mode == .portrait ? video.portraitLighting : nil)
    }

    func start() {}
    func stop() {}

    /// Takes about as long as the real camera to change its format.
    func setMode(_ mode: CameraMode, options video: CaptureOptions) async {
        try? await Task.sleep(for: .milliseconds(250))
        self.mode = mode
        updatePreviewLook(mode: mode, options: video)
        state.canLive = mode == .photo
        state.canRAW = mode == .photo
        state.canDepth = mode.isStill
        state.portraitHint =
            mode == .portrait && ProcessInfo.processInfo.arguments.contains("-ui-testing-portrait-hint")
            ? .moveFartherAway : nil
        state.availableResolutions = [.mp12, .mp24, .mp48]
        let fpsText = CameraControls.frameRateLabel(video.frameRate)
        let hdrSuffix = video.hdr ? " · HDR" : ""
        let autoSuffix = video.autoLowLightFPS ? " · Auto" : ""
        state.videoFormat =
            switch mode {
            case .photo, .portrait: nil
            case .video: "\(video.resolution == .uhd4K ? "4K" : "1080p") · \(fpsText)\(hdrSuffix)\(autoSuffix)"
            case .slowMotion: "1080p · \(video.slowMotionRate) fps"
            case .timeLapse: video.timeLapseInterval.map { "every \(CameraMode.intervalText($0))" } ?? "Auto"
            }
    }

    func flip() {
        state.side = state.side == .back ? .front : .back
        state.presets = state.side == .back ? [0.5, 1, 2] : [1]
        state.zoomRange = state.side == .back ? 0.5...10 : 1...5
        state.zoom = 1
        state.hasFlash = state.side == .back
    }

    /// Glides like the real camera, in doublings, so the screen can be tried in the simulator.
    func zoom(to factor: Double, glide: Bool) {
        let target = min(max(factor, state.zoomRange.lowerBound), state.zoomRange.upperBound)
        gliding?.cancel()
        guard glide else {
            state.zoom = target
            return
        }
        let start = state.zoom
        gliding = Task { [weak self] in
            let steps = 18
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(Zoom.glideSeconds / Double(steps)))
                if Task.isCancelled { return }
                self?.state.zoom = start * pow(target / start, Double(step) / Double(steps))
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

    func takePhoto(_ request: PhotoRequest) async -> TakenPhoto? {
        guard mode.isStill else { return nil }
        let seed = nextSeed()
        let data = await Task.detached { SampleMedia.photo(seed: seed) }.value
        guard let data else { return nil }
        var photo = TakenPhoto(data: data, heic: false, width: 1600, height: 1200)
        if request.raw {
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
}

/// What the stand-in camera "sees", rendering active Photographic Styles and Filters with Core Image.
final class StandInPreview: UIView {
    private let gradient = CAGradientLayer()
    private let lookImageView = UIImageView()
    private static let ciContext = CIContext()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor]
        layer.addSublayer(gradient)
        lookImageView.contentMode = .scaleAspectFill
        lookImageView.clipsToBounds = true
        lookImageView.isHidden = true
        lookImageView.frame = bounds
        lookImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(lookImageView)
        let label = UILabel()
        label.text = "Stand-in camera"
        label.textColor = .white.withAlphaComponent(0.8)
        label.font = .preferredFont(forTextStyle: .headline)
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
        style: PhotographicStyle?, filter: PhotoFilter?,
        portraitAperture: Double? = nil, portraitLighting: PortraitLighting? = nil
    ) {
        let isPortrait = portraitAperture != nil || (portraitLighting != nil && portraitLighting != .natural)
        guard LookRenderer.needsCustomPreview(style: style, filter: filter, isPortrait: isPortrait) else {
            lookImageView.isHidden = true
            lookImageView.image = nil
            return
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320))
        let base = renderer.image { ctx in
            let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
            if let cgGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                ctx.cgContext.drawLinearGradient(
                    cgGradient, start: .zero, end: CGPoint(x: 0, y: 320), options: [])
            }
        }
        if var ci = CIImage(image: base) {
            if isPortrait {
                ci = PortraitRenderer.apply(to: ci, aperture: portraitAperture, lighting: portraitLighting)
            }
            let styled = LookRenderer.apply(style: style, filter: filter, to: ci)
            if let cg = Self.ciContext.createCGImage(styled, from: styled.extent) {
                lookImageView.image = UIImage(cgImage: cg)
                lookImageView.isHidden = false
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}
