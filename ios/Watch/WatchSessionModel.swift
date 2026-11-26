import HaldenWatchProtocol
import Observation
import SwiftUI
import UIKit
@preconcurrency import WatchConnectivity

/// Watch-side camera remote state backed by `WatchConnectivity` (with a built-in stand-in mode
/// for `HaldenWatchUITests` via `-ui-testing`).
@MainActor
@Observable
final class WatchSessionModel: NSObject, WCSessionDelegate {
    var state = WatchCameraState()
    var previewImage: UIImage?
    var lastPhotoImage: UIImage?
    var showingLastPhoto = false
    var crownZoom: Double = 1.0
    private let uiTesting: Bool

    override init() {
        uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        super.init()
        if uiTesting {
            state = WatchCameraState(
                cameraOpen: true, mode: "photo", zoom: 1.0, minZoom: 0.5, maxZoom: 10.0,
                isFront: false, isRecording: false, countdown: nil)
            crownZoom = 1.0
            previewImage = Self.syntheticImage(accent: .blue)
            return
        }
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    func send(_ command: WatchCommand) {
        if uiTesting {
            handleStandIn(command)
            return
        }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(command.toMessage(), replyHandler: nil, errorHandler: nil)
    }

    func updateZoomFromCrown(_ value: Double) {
        let clamped = WatchCrownZoom.clamped(value, minZoom: state.minZoom, maxZoom: state.maxZoom)
        guard abs(clamped - state.zoom) >= 0.05 else { return }
        state.zoom = clamped
        send(.setZoom(clamped))
    }

    private func handleStandIn(_ command: WatchCommand) {
        switch command {
        case .shutter:
            lastPhotoImage = Self.syntheticImage(accent: state.isFront ? .orange : .green)
            showingLastPhoto = true
        case .timer3s:
            state.countdown = 3
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.state.countdown = nil
                self?.lastPhotoImage = Self.syntheticImage(accent: .purple)
                self?.showingLastPhoto = true
            }
        case .flipCamera:
            state.isFront.toggle()
            previewImage = Self.syntheticImage(accent: state.isFront ? .orange : .blue)
        case .setZoom(let factor):
            state.zoom = WatchCrownZoom.clamped(factor, minZoom: state.minZoom, maxZoom: state.maxZoom)
        case .requestState:
            break
        }
    }

    private static func syntheticImage(accent: UIColor) -> UIImage {
        let width = 180
        let height = 220
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return UIImage() }
        ctx.setFillColor(accent.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        Task { @MainActor in
            if let ctx = WatchCameraState.fromMessage(session.receivedApplicationContext) {
                self.state = ctx
                self.crownZoom = ctx.zoom
            }
            self.send(.requestState)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let state = WatchCameraState.fromMessage(applicationContext) {
            Task { @MainActor in
                self.state = state
                self.crownZoom = state.zoom
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let state = WatchCameraState.fromMessage(message) {
            Task { @MainActor in
                self.state = state
                self.crownZoom = state.zoom
            }
        } else if let data = message[WatchMessageKey.previewJPEG] as? Data, let image = UIImage(data: data) {
            Task { @MainActor in
                self.state.cameraOpen = true
                self.previewImage = image
            }
        } else if let data = message[WatchMessageKey.lastPhotoJPEG] as? Data, let image = UIImage(data: data) {
            Task { @MainActor in
                self.lastPhotoImage = image
                self.showingLastPhoto = true
            }
        }
    }
}
