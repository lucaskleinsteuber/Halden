import Foundation

/// Message keys exchanged over `WatchConnectivity` between the iPhone Halden app and Apple Watch.
public enum WatchMessageKey {
    public static let kind = "kind"
    public static let command = "command"
    public static let zoom = "zoom"
    public static let state = "state"
    public static let previewJPEG = "previewJPEG"
    public static let lastPhotoJPEG = "lastPhotoJPEG"
}

/// Commands sent from Apple Watch to the live Halden camera on iPhone.
public enum WatchCommand: Equatable, Sendable {
    case shutter
    case timer3s
    case flipCamera
    case setZoom(Double)
    case requestState

    public func toMessage() -> [String: Any] {
        switch self {
        case .shutter:
            return [WatchMessageKey.kind: "cmd", WatchMessageKey.command: "shutter"]
        case .timer3s:
            return [WatchMessageKey.kind: "cmd", WatchMessageKey.command: "timer3s"]
        case .flipCamera:
            return [WatchMessageKey.kind: "cmd", WatchMessageKey.command: "flip"]
        case .setZoom(let factor):
            return [WatchMessageKey.kind: "cmd", WatchMessageKey.command: "zoom", WatchMessageKey.zoom: factor]
        case .requestState:
            return [WatchMessageKey.kind: "cmd", WatchMessageKey.command: "state"]
        }
    }

    public static func fromMessage(_ message: [String: Any]) -> WatchCommand? {
        guard message[WatchMessageKey.kind] as? String == "cmd",
            let cmd = message[WatchMessageKey.command] as? String
        else { return nil }
        switch cmd {
        case "shutter": return .shutter
        case "timer3s": return .timer3s
        case "flip": return .flipCamera
        case "state": return .requestState
        case "zoom":
            guard let zoom = message[WatchMessageKey.zoom] as? Double, zoom.isFinite else { return nil }
            return .setZoom(zoom)
        default:
            return nil
        }
    }
}

/// Snapshot of the iPhone camera state mirrored onto Apple Watch.
public struct WatchCameraState: Codable, Equatable, Sendable {
    public var cameraOpen: Bool
    public var mode: String
    public var zoom: Double
    public var minZoom: Double
    public var maxZoom: Double
    public var isFront: Bool
    public var isRecording: Bool
    public var countdown: Int?

    public init(
        cameraOpen: Bool = false, mode: String = "photo", zoom: Double = 1.0,
        minZoom: Double = 0.5, maxZoom: Double = 10.0, isFront: Bool = false,
        isRecording: Bool = false, countdown: Int? = nil
    ) {
        self.cameraOpen = cameraOpen
        self.mode = mode
        self.zoom = zoom
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.isFront = isFront
        self.isRecording = isRecording
        self.countdown = countdown
    }

    public func toMessage() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [WatchMessageKey.kind: "state", WatchMessageKey.state: data]
    }

    public static func fromMessage(_ message: [String: Any]) -> WatchCameraState? {
        guard message[WatchMessageKey.kind] as? String == "state",
            let data = message[WatchMessageKey.state] as? Data
        else { return nil }
        return try? JSONDecoder().decode(WatchCameraState.self, from: data)
    }
}

/// Throttles Watch live-preview JPEG frames to ~8 fps and keeps payloads small so WatchConnectivity
/// never queues up or stalls the iPhone camera shutter.
public struct WatchFrameThrottler: Equatable, Sendable {
    public static let defaultMaxFPS: Double = 8.0
    public static let maxPayloadBytes = 28_000
    public static let targetWidth = 240
    public static let targetHeight = 320

    public let minInterval: TimeInterval
    public private(set) var lastSentAt: TimeInterval = -1000
    public private(set) var jpegQuality: Double = 0.45
    public private(set) var sentCount = 0
    public private(set) var droppedCount = 0

    public init(maxFPS: Double = defaultMaxFPS) {
        self.minInterval = 1.0 / max(1.0, min(maxFPS, 15.0))
    }

    /// Returns `true` only when reachable, no previous frame is in flight, and `minInterval` elapsed.
    public mutating func shouldSendFrame(now: TimeInterval, isReachable: Bool, inFlight: Bool) -> Bool {
        guard isReachable, !inFlight else {
            droppedCount += 1
            return false
        }
        guard now - lastSentAt >= minInterval - 0.0005 else {
            droppedCount += 1
            return false
        }
        lastSentAt = now
        sentCount += 1
        return true
    }

    /// Adapts JPEG compression quality gently based on the encoded byte size of the last frame.
    public mutating func recordPayloadSize(_ bytes: Int) {
        if bytes > Self.maxPayloadBytes {
            jpegQuality = max(0.18, jpegQuality - 0.08)
        } else if bytes < Self.maxPayloadBytes / 2 {
            jpegQuality = min(0.60, jpegQuality + 0.03)
        }
    }

    public mutating func reset() {
        lastSentAt = -1000
        jpegQuality = 0.45
        sentCount = 0
        droppedCount = 0
    }
}

/// Maps Apple Watch Digital Crown rotation smoothly into the iPhone camera's zoom range.
public enum WatchCrownZoom {
    /// Clamps and quantizes a crown zoom target to 0.1× increments within `minZoom...maxZoom`.
    public static func clamped(_ value: Double, minZoom: Double, maxZoom: Double) -> Double {
        let lo = max(0.5, minZoom)
        let hi = max(lo, maxZoom)
        let raw = min(max(value, lo), hi)
        return (raw * 10).rounded() / 10
    }

    /// Formats a compact zoom label for the Watch display (`"0.5×"`, `"1×"`, `"2.4×"`).
    public static func label(for zoom: Double) -> String {
        let rounded = (zoom * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))×"
        }
        return String(format: "%.1f×", rounded)
    }
}
