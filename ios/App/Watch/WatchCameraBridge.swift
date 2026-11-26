import CoreGraphics
import HaldenKit
import HaldenWatchProtocol
import UIKit
@preconcurrency import WatchConnectivity

/// Connects the live Halden iPhone camera to the Apple Watch companion app over `WatchConnectivity`:
/// forwards shutter, 3-second timer, flip, and Digital Crown zoom commands to `CameraModel`, and
/// streams throttled (~8 fps) low-resolution JPEG previews plus post-capture thumbnails to the Watch.
@MainActor
final class WatchCameraBridge: NSObject, WCSessionDelegate {
    private weak var camera: CameraModel?
    private var throttler = WatchFrameThrottler(maxFPS: 8.0)
    private var inFlight = false
    private var previewTask: Task<Void, Never>?
    private var isActive = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    func attach(to camera: CameraModel) {
        self.camera = camera
        isActive = true
        throttler.reset()
        sendState()
        startPreviewStream()
    }

    func detach() {
        isActive = false
        previewTask?.cancel()
        previewTask = nil
        sendState()
        camera = nil
    }

    func sendState() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let state = currentState()
        let msg = state.toMessage()
        if session.isReachable {
            session.sendMessage(msg, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(msg)
        }
    }

    func sendLastPhoto(_ image: CGImage) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        guard let data = Self.jpeg(from: image, maxEdge: 320, quality: 0.6) else { return }
        session.sendMessage([WatchMessageKey.kind: "photo", WatchMessageKey.lastPhotoJPEG: data], replyHandler: nil)
    }

    private func currentState() -> WatchCameraState {
        guard isActive, let camera else {
            return WatchCameraState(cameraOpen: false)
        }
        let s = camera.backend.state
        return WatchCameraState(
            cameraOpen: true,
            mode: camera.mode.rawValue,
            zoom: camera.zoom,
            minZoom: s.zoomRange.lowerBound,
            maxZoom: s.zoomRange.upperBound,
            isFront: s.side == .front,
            isRecording: camera.recording,
            countdown: camera.countdown)
    }

    private func startPreviewStream() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(125))
                guard let self, self.isActive else { break }
                self.sendLivePreviewFrameIfNeeded()
            }
        }
    }

    private func sendLivePreviewFrameIfNeeded() {
        guard WCSession.isSupported(), let camera else { return }
        let session = WCSession.default
        let now = ProcessInfo.processInfo.systemUptime
        guard session.activationState == .activated,
            throttler.shouldSendFrame(now: now, isReachable: session.isReachable, inFlight: inFlight)
        else { return }

        let view = camera.backend.previewView
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let targetSize = CGSize(
            width: CGFloat(WatchFrameThrottler.targetWidth),
            height: CGFloat(WatchFrameThrottler.targetHeight))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let snapshot = renderer.image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: false)
        }
        guard let jpeg = snapshot.jpegData(compressionQuality: throttler.jpegQuality) else { return }
        throttler.recordPayloadSize(jpeg.count)
        inFlight = true
        session.sendMessage(
            [WatchMessageKey.kind: "frame", WatchMessageKey.previewJPEG: jpeg],
            replyHandler: nil,
            errorHandler: { [weak self] _ in
                Task { @MainActor in self?.inFlight = false }
            })
        // Release the in-flight latch cleanly after one frame interval in case no replyHandler runs.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            self?.inFlight = false
        }
    }

    private static func jpeg(from image: CGImage, maxEdge: CGFloat, quality: CGFloat) -> Data? {
        let ui = UIImage(cgImage: image)
        let scale = min(1, maxEdge / max(ui.size.width, ui.size.height))
        let size = CGSize(
            width: max(1, (ui.size.width * scale).rounded()), height: max(1, (ui.size.height * scale).rounded()))
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: quality)
    }

    private func handle(_ command: WatchCommand) {
        guard isActive, let camera else {
            sendState()
            return
        }
        switch command {
        case .shutter:
            camera.timer = 0
            camera.shutter()
        case .timer3s:
            camera.timer = 3
            camera.shutter()
        case .flipCamera:
            camera.flip()
        case .setZoom(let factor):
            camera.zoom(to: factor, glide: false)
        case .requestState:
            break
        }
        sendState()
    }

    // MARK: WCSessionDelegate

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        Task { @MainActor in self.sendState() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = WatchCommand.fromMessage(message) else { return }
        Task { @MainActor in self.handle(cmd) }
    }
}
