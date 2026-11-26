import Foundation

/// Hardware capabilities found only on newer or Pro iPhones. Halden shows Pro controls only on
/// devices that support them (`StandInCamera` advertises `.all` in tests unless `-ui-testing-basic-device`
/// is passed).
public struct DeviceCapabilities: Codable, Sendable, Equatable {
    public var canProRAW = false
    public var canProRes = false
    public var canAppleLog = false
    public var canExternalStorage = false
    public var canSpatialVideo = false
    public var canMacroControl = false
    public var canCameraControl = false
    public var canSpatialAudio = false
    public var canAudioMix = false

    public init(
        canProRAW: Bool = false, canProRes: Bool = false, canAppleLog: Bool = false,
        canExternalStorage: Bool = false, canSpatialVideo: Bool = false, canMacroControl: Bool = false,
        canCameraControl: Bool = false, canSpatialAudio: Bool = false, canAudioMix: Bool = false
    ) {
        self.canProRAW = canProRAW
        self.canProRes = canProRes
        self.canAppleLog = canAppleLog
        self.canExternalStorage = canExternalStorage
        self.canSpatialVideo = canSpatialVideo
        self.canMacroControl = canMacroControl
        self.canCameraControl = canCameraControl
        self.canSpatialAudio = canSpatialAudio
        self.canAudioMix = canAudioMix
    }

    public static let basic = DeviceCapabilities()

    public static let all = DeviceCapabilities(
        canProRAW: true, canProRes: true, canAppleLog: true, canExternalStorage: true,
        canSpatialVideo: true, canMacroControl: true, canCameraControl: true,
        canSpatialAudio: true, canAudioMix: true)

    public var hasProVideo: Bool { canProRes || canAppleLog }
}

/// Video codec & colour pipeline options on Pro iPhones (HEVC standard, Apple ProRes 422, ProRes Log).
public enum ProVideoFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard
    case proRes = "prores"
    case proResLog = "prores_log"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard (HEVC)"
        case .proRes: "Apple ProRes"
        case .proResLog: "Apple ProRes Log"
        }
    }

    public var shortLabel: String {
        switch self {
        case .standard: "HEVC"
        case .proRes: "ProRes"
        case .proResLog: "LOG"
        }
    }

    public static func available(for capabilities: DeviceCapabilities) -> [ProVideoFormat] {
        var list: [ProVideoFormat] = [.standard]
        if capabilities.canProRes { list.append(.proRes) }
        if capabilities.canProRes && capabilities.canAppleLog { list.append(.proResLog) }
        return list
    }
}

/// Post-capture Spatial Audio mixing styles (maps directly to `CNSpatialAudioRenderingStyle`).
public enum AudioMixStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard
    case inFrame = "in_frame"
    case studio
    case cinematic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .inFrame: "In-Frame"
        case .studio: "Studio"
        case .cinematic: "Cinematic"
        }
    }

    public var detail: String {
        switch self {
        case .standard: "Play the original Spatial Audio mix as recorded."
        case .inFrame: "Focus on voices inside the camera frame and reduce off-camera sound."
        case .studio: "Reduce background noise and reverberation like a close studio mic."
        case .cinematic: "Bring voices forward and keep ambient sound in the surround bed."
        }
    }

    public var symbol: String {
        switch self {
        case .standard: "waveform"
        case .inFrame: "person.and.background.dotted"
        case .studio: "mic.fill"
        case .cinematic: "film"
        }
    }
}

/// Macro switching behavior on iPhones with an autofocus Ultra Wide camera.
public enum MacroMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case on
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .on: "On"
        case .off: "Off"
        }
    }
}

/// Information about a connected USB-C external storage device (`AVExternalStorageDevice`).
public struct ExternalStorageInfo: Codable, Sendable, Equatable {
    public var displayName: String
    public var freeBytes: Int64

    public init(displayName: String, freeBytes: Int64) {
        self.displayName = displayName
        self.freeBytes = max(0, freeBytes)
    }

    public var badgeLabel: String { "USB-C" }

    public var formattedFreeSpace: String {
        ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
    }
}

/// Pure rules for newer-iPhone features: strict capability gating, format fallbacks, external
/// storage routing, and Audio Mix validation.
public enum ProDeviceRules {
    public static let defaultAudioMixIntensity = 0.5
    public static let minimumExternalStorageBytes: Int64 = 64 * 1024 * 1024

    public static func clampAudioMixIntensity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultAudioMixIntensity }
        let clamped = min(max(value, 0), 1)
        return (clamped * 100).rounded() / 100
    }

    public static func effectiveProRAW(enabled: Bool, capabilities: DeviceCapabilities) -> Bool {
        enabled && capabilities.canProRAW
    }

    public static func effectiveVideoFormat(
        wanted: ProVideoFormat, capabilities: DeviceCapabilities
    ) -> ProVideoFormat {
        switch wanted {
        case .standard: .standard
        case .proRes: capabilities.canProRes ? .proRes : .standard
        case .proResLog:
            if capabilities.canProRes && capabilities.canAppleLog {
                .proResLog
            } else if capabilities.canProRes {
                .proRes
            } else {
                .standard
            }
        }
    }

    public static func effectiveAudioChannel(
        wanted: AudioChannelMode, capabilities: DeviceCapabilities
    ) -> AudioChannelMode {
        if wanted == .spatial && !capabilities.canSpatialAudio { return .stereo }
        return wanted
    }

    public static func shouldRecordToExternalStorage(
        enabled: Bool, storage: ExternalStorageInfo?, format: ProVideoFormat
    ) -> Bool {
        guard let storage, storage.freeBytes >= minimumExternalStorageBytes else { return false }
        return enabled || format != .standard
    }
}
