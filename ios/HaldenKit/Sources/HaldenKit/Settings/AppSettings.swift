import Foundation

/// The app's own settings (what the server keeps per account, like the preferred formats, lives
/// there). Every one has a sensible default; a setting added later simply takes its default when
/// older saved settings are read.
public struct AppSettings: Codable, Sendable, Equatable {
    public enum PhotoFormat: String, Codable, Sendable, CaseIterable {
        case heic, jpeg
    }

    public enum VideoResolution: String, Codable, Sendable, CaseIterable {
        case hd1080 = "1080p"
        case uhd4K = "4k"
    }

    public enum Flash: String, Codable, Sendable, CaseIterable {
        case auto, on, off
    }

    /// What happens to a place measured less precisely than `locationAccuracyLimit`.
    public enum InaccurateLocation: String, Codable, Sendable, CaseIterable {
        /// Kept, with its accuracy, so the app can show it as imprecise.
        case mark
        /// Left out: no place rather than a wrong one.
        case omit
    }

    // Uploads
    public var uploadOverCellular = true
    public var videosOnlyOnWiFi = true
    /// Only on Wi-Fi where the server answers at its home-network address (not over Tailscale).
    public var onlyOnHomeNetwork = false

    // Copies on this iPhone
    /// Keep originals on the iPhone after they are safely on the server.
    public var keepLocalCopies = true

    // Camera
    public var photoFormat = PhotoFormat.heic
    public var videoResolution = VideoResolution.uhd4K
    public var videoFrameRate = 60
    public var videoHDR = false
    public var flash = Flash.auto
    public var showGrid = false

    // Place
    public var locationAccuracyLimit = 50.0
    public var inaccurateLocation = InaccurateLocation.mark

    // Apple Photos
    /// Photos and videos from other apps (Apple's camera, screenshots, …) come into Halden.
    public var importFromPhotos = true
    /// Photos taken with Halden go into Apple Photos too.
    public var saveToPhotos = true
    /// Deleting in one place offers to delete in the other.
    public var syncDeletionsWithPhotos = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case uploadOverCellular, videosOnlyOnWiFi, onlyOnHomeNetwork, keepLocalCopies, photoFormat
        case videoResolution, videoFrameRate, videoHDR, flash, showGrid, locationAccuracyLimit
        case inaccurateLocation, importFromPhotos, saveToPhotos, syncDeletionsWithPhotos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var settings = AppSettings()
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            // A value that no longer decodes (an option that went away) falls back to the default.
            if let found = try? container.decodeIfPresent(T.self, forKey: key) { value = found }
        }
        read(.uploadOverCellular, into: &settings.uploadOverCellular)
        read(.videosOnlyOnWiFi, into: &settings.videosOnlyOnWiFi)
        read(.onlyOnHomeNetwork, into: &settings.onlyOnHomeNetwork)
        read(.keepLocalCopies, into: &settings.keepLocalCopies)
        read(.photoFormat, into: &settings.photoFormat)
        read(.videoResolution, into: &settings.videoResolution)
        read(.videoFrameRate, into: &settings.videoFrameRate)
        read(.videoHDR, into: &settings.videoHDR)
        read(.flash, into: &settings.flash)
        read(.showGrid, into: &settings.showGrid)
        read(.locationAccuracyLimit, into: &settings.locationAccuracyLimit)
        read(.inaccurateLocation, into: &settings.inaccurateLocation)
        read(.importFromPhotos, into: &settings.importFromPhotos)
        read(.saveToPhotos, into: &settings.saveToPhotos)
        read(.syncDeletionsWithPhotos, into: &settings.syncDeletionsWithPhotos)
        self = settings
    }
}

/// Where the settings are kept.
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// The settings in `UserDefaults`, as JSON.
public struct DefaultsSettingsStore: SettingsStore {
    let key: String
    let suite: String?

    public init(key: String = "settings", suite: String? = nil) {
        self.key = key
        self.suite = suite
    }

    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Settings that live only as long as the app (UI tests, previews).
public final class MemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    public init(_ settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    public func load() -> AppSettings {
        lock.withLock { settings }
    }

    public func save(_ settings: AppSettings) {
        lock.withLock { self.settings = settings }
    }
}
