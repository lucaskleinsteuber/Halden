import Foundation

/// How much of the camera a settings change touches, from nothing to a rebuilt capture session.
/// The camera does only what a change needs: a filter or style is drawn into the next frame,
/// lens correction or QR scanning is set on the device, and only formats, outputs and the like
/// rebuild the session (with the short blur while it does).
public enum CameraChangeScope: Int, Comparable, Sendable {
    /// Nothing the camera itself uses (flash, grid, timer, …: read when taking a photo).
    case none
    /// Only how the picture looks: style, filter, portrait depth and light.
    case look
    /// Set on the camera without rebuilding the session.
    case device
    /// Outputs, formats or resolution: the session is reconfigured.
    case session

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The widest scope among the settings that differ.
    public static func between(_ old: AppSettings, _ new: AppSettings) -> CameraChangeScope {
        if old == new { return .none }
        if sessionChanged(old, new) { return .session }
        if deviceChanged(old, new) { return .device }
        if lookChanged(old, new) { return .look }
        return .none
    }

    static func lookChanged(_ a: AppSettings, _ b: AppSettings) -> Bool {
        a.photographicStyle != b.photographicStyle || a.photoFilter != b.photoFilter
            || a.filterIntensity != b.filterIntensity || a.portraitAperture != b.portraitAperture
            || a.portraitLighting != b.portraitLighting
    }

    static func deviceChanged(_ a: AppSettings, _ b: AppSettings) -> Bool {
        a.lensCorrection != b.lensCorrection || a.macroMode != b.macroMode || a.macroControl != b.macroControl
            || a.mirrorFrontCamera != b.mirrorFrontCamera || a.cinematicAperture != b.cinematicAperture
            || a.windNoiseRemoval != b.windNoiseRemoval || a.scanQRCodes != b.scanQRCodes
            || a.showLiveText != b.showLiveText || a.lockVideoCamera != b.lockVideoCamera
            || a.lockVideoWhiteBalance != b.lockVideoWhiteBalance
    }

    static func sessionChanged(_ a: AppSettings, _ b: AppSettings) -> Bool {
        a.photoResolution != b.photoResolution || a.captureRAW != b.captureRAW
            || a.captureProRAW != b.captureProRAW || a.livePhotos != b.livePhotos
            || a.videoResolution != b.videoResolution || a.videoFrameRate != b.videoFrameRate
            || a.videoHDR != b.videoHDR || a.autoLowLightFPS != b.autoLowLightFPS
            || a.proVideoFormat != b.proVideoFormat || a.actionMode != b.actionMode
            || a.slowMotionRate != b.slowMotionRate || a.timeLapseInterval != b.timeLapseInterval
            || a.prioritizeFasterShooting != b.prioritizeFasterShooting || a.autoDepth != b.autoDepth
            || a.showHistogram != b.showHistogram || a.showWaveform != b.showWaveform
            || a.audioChannelMode != b.audioChannelMode || a.allowAudioPlayback != b.allowAudioPlayback
            || a.allowAirPodsMic != b.allowAirPodsMic || a.recordToExternalStorage != b.recordToExternalStorage
    }
}

/// What the camera measures about itself, shown in Settings › About › Camera Timings so a real
/// iPhone's numbers can be compared with the targets.
public enum CameraTimingKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Opening the camera tab until the first picture.
    case open
    /// A mode change (photo ↔ video …) until the first picture in the new mode.
    case modeSwitch
    /// Turning the camera around until the first picture.
    case flip
    /// A filter, style or slider until the picture shows it.
    case look
    /// The shutter until the small picture next to it.
    case shutterToThumbnail
    /// The shutter until the camera can take the next photo.
    case shutterToReady

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .open: "Open camera"
        case .modeSwitch: "Change mode"
        case .flip: "Turn camera around"
        case .look: "Filter or style"
        case .shutterToThumbnail: "Shutter to thumbnail"
        case .shutterToReady: "Shutter to next photo"
        }
    }

    /// The target on an iPhone 15, in milliseconds.
    public var targetMilliseconds: Double {
        switch self {
        case .open: 300
        case .modeSwitch: 350
        case .flip: 450
        case .look: 34
        case .shutterToThumbnail: 300
        case .shutterToReady: 150
        }
    }
}

/// The last measurements of each kind (up to 30), kept across launches.
public final class CameraTimingLog: @unchecked Sendable {
    public struct Summary: Sendable, Equatable {
        public var last: Double
        public var median: Double
        public var count: Int
    }

    public static let shared = CameraTimingLog()
    static let keep = 30

    private let lock = NSLock()
    private var values: [CameraTimingKind: [Double]]
    private let defaults: UserDefaults?
    private let key = "cameraTimings"

    /// `defaults` nil keeps the log in memory only (tests).
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: key),
            let saved = try? JSONDecoder().decode([String: [Double]].self, from: data)
        {
            var restored: [CameraTimingKind: [Double]] = [:]
            for (name, list) in saved {
                if let kind = CameraTimingKind(rawValue: name) { restored[kind] = list }
            }
            values = restored
        } else {
            values = [:]
        }
    }

    /// Adds one measurement (negative or absurd values are ignored).
    public func record(_ kind: CameraTimingKind, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 60_000 else { return }
        let snapshot: [String: [Double]] = lock.withLock {
            var list = values[kind] ?? []
            list.append((milliseconds * 10).rounded() / 10)
            if list.count > Self.keep { list.removeFirst(list.count - Self.keep) }
            values[kind] = list
            return Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        }
        if let defaults, let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
    }

    public func summary(_ kind: CameraTimingKind) -> Summary? {
        lock.withLock {
            guard let list = values[kind], let last = list.last else { return nil }
            return Summary(last: last, median: Self.median(list), count: list.count)
        }
    }

    public func clear() {
        lock.withLock { values = [:] }
        defaults?.removeObject(forKey: key)
    }

    static func median(_ list: [Double]) -> Double {
        let sorted = list.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
