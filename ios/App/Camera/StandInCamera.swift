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
        hasFlash: true, hasTorch: true, canLive: true)
    @ObservationIgnored let previewView: UIView = StandInPreview()
    @ObservationIgnored private var taken = 0
    @ObservationIgnored private var recording: (request: VideoRequest, started: Date)?
    @ObservationIgnored private var mode = CameraMode.photo
    @ObservationIgnored private var gliding: Task<Void, Never>?

    func prepare(mode: CameraMode, options video: CaptureOptions) {
        self.mode = mode
    }

    func start() {}
    func stop() {}

    func setMode(_ mode: CameraMode, options video: CaptureOptions) {
        self.mode = mode
        state.canLive = mode == .photo
        state.videoFormat =
            switch mode {
            case .photo: nil
            case .video: "\(video.resolution == .uhd4K ? "4K" : "1080p") · \(video.frameRate) fps"
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
        var photo = TakenPhoto(data: data, heic: false, width: 1600, height: 1200)
        if request.live {
            let movie = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            if (try? await SampleMedia.video(at: movie, seed: seed, seconds: 1)) != nil { photo.liveVideo = movie }
        }
        return photo
    }

    func startRecording(_ request: VideoRequest) -> Bool {
        guard mode.records, recording == nil else { return false }
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
