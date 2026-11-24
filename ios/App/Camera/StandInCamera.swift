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
        hasFlash: true, hasTorch: true)
    @ObservationIgnored let previewView: UIView = StandInPreview()
    @ObservationIgnored private var taken = 0
    @ObservationIgnored private var recording: (request: VideoRequest, started: Date)?
    @ObservationIgnored private var mode = CameraMode.photo

    func prepare(mode: CameraMode, video: VideoOptions) {
        self.mode = mode
    }

    func start() {}
    func stop() {}

    func setMode(_ mode: CameraMode, video: VideoOptions) {
        self.mode = mode
        state.videoFormat =
            mode == .video ? "\(video.resolution == .uhd4K ? "4K" : "1080p") · \(video.frameRate) fps" : nil
    }

    func flip() {
        state.side = state.side == .back ? .front : .back
        state.presets = state.side == .back ? [0.5, 1, 2] : [1]
        state.zoomRange = state.side == .back ? 0.5...10 : 1...5
        state.zoom = 1
        state.hasFlash = state.side == .back
    }

    func zoom(to factor: Double, smoothly: Bool) {
        state.zoom = min(max(factor, state.zoomRange.lowerBound), state.zoomRange.upperBound)
    }

    func focus(at point: CGPoint, lock: Bool) {
        state.focusLocked = lock
    }

    func setTorch(_ on: Bool) {}

    /// A seed that differs between photos and between runs of the app.
    private func nextSeed() -> Int {
        taken += 1
        return Int(Date().timeIntervalSince1970 * 1000) &* 31 &+ taken
    }

    func takePhoto(_ request: PhotoRequest) async -> TakenPhoto? {
        guard mode == .photo else { return nil }
        let seed = nextSeed()
        let data = await Task.detached { SampleMedia.photo(seed: seed) }.value
        guard let data else { return nil }
        return TakenPhoto(data: data, heic: false, width: 1600, height: 1200)
    }

    func startRecording(_ request: VideoRequest) -> Bool {
        guard mode == .video, recording == nil else { return false }
        recording = (request, Date())
        return true
    }

    func stopRecording() async -> URL? {
        guard let (request, started) = recording else { return nil }
        recording = nil
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

/// What the stand-in camera "sees".
final class StandInPreview: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor]
        layer.addSublayer(gradient)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}
