import CoreGraphics
import HaldenKit
import HaldenWatchProtocol
import UIKit
@preconcurrency import WatchConnectivity

/// Connects the live Halden iPhone camera to the Apple Watch companion app over `WatchConnectivity`:
/// forwards shutter, 3-second timer, flip, and Digital Crown zoom commands to `CameraModel`, and
/// streams throttled (~8 fps) low-resolution JPEG previews directly from camera pixel buffers.
@MainActor
final class WatchCameraBridge: NSObject, WCSessionDelegate {
    private weak var camera: CameraModel?
    private var throttler = WatchFrameThrottler(maxFPS: 8.0)
    private var inFlight = false
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
        updatePreviewStream()
    }

    func detach() {
        isActive = false
        camera?.backend.setWatchFrameHandler(nil)
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
        updatePreviewStream()
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
        let isFront = camera.mode == .dual ? camera.dualSwapped : (s.side == .front)
        return WatchCameraState(
            cameraOpen: true,
            mode: camera.mode.rawValue,
            zoom: camera.zoom,
            minZoom: s.zoomRange.lowerBound,
            maxZoom: s.zoomRange.upperBound,
            isFront: isFront,
            isRecording: camera.recording,
            countdown: camera.countdown)
    }

    private func updatePreviewStream() {
        guard let camera else { return }
        guard isActive, WCSession.isSupported(),
            WCSession.default.activationState == .activated,
            WCSession.default.isReachable
        else {
            camera.backend.setWatchFrameHandler(nil)
            return
        }
        camera.backend.setWatchFrameHandler { [weak self] jpeg in
            Task { @MainActor in self?.deliverPreviewJPEG(jpeg) }
        }
    }

    private func deliverPreviewJPEG(_ jpeg: Data) {
        guard isActive, WCSession.isSupported() else { return }
        let session = WCSession.default
        let now = ProcessInfo.processInfo.systemUptime
        guard session.activationState == .activated,
            throttler.shouldSendFrame(now: now, isReachable: session.isReachable, inFlight: inFlight)
        else { return }

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
            camera.triggerFromWatch(delay: 0)
        case .timer3s:
            camera.triggerFromWatch(delay: 3)
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

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.updatePreviewStream() }
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
