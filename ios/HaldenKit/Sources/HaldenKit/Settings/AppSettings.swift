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
    /// Which copy of a video plays when it isn't on this iPhone.
    public enum VideoCopy: String, Codable, Sendable, CaseIterable {
        /// The small copy on cellular and away from home, the original at home.
        case automatic
        case small
        case original
    }

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
    public var photoAspectRatio = PhotoAspectRatio.fourByThree
    public var photoResolution = PhotoResolution.mp24
    /// Capture Bayer RAW (DNG) alongside the processed photo, when supported by the camera.
    public var captureRAW = false
    public var videoResolution = VideoResolution.uhd4K
    public var videoFrameRate = 60
    public var videoHDR = false
    /// Automatically lower the video frame rate in low light when supported.
    public var autoLowLightFPS = false
    /// Keep the active camera lens locked while recording video (no automatic lens switching).
    public var lockVideoCamera = false
    /// Lock white balance at the start of a video recording.
    public var lockVideoWhiteBalance = false
    public var flash = Flash.auto
    public var showGrid = false
    /// Show the horizon / flat-lay level in the camera.
    public var showLevel = false
    /// Mirror front-camera photos to match the preview.
    public var mirrorFrontCamera = false
    /// Geometric lens distortion correction on ultra wide / front cameras.
    public var lensCorrection = true
    /// Photos with a short video before and after, like Apple's camera; on by default there too.
    public var livePhotos = true
    /// Frames a second for slow motion: 120 or 240.
    public var slowMotionRate = 240
    /// Seconds between the pictures of a time-lapse; 0 for automatic (the video stays 20–40 s).
    public var timeLapseInterval = 0.0
    /// Prioritize faster capture (`photoQualityPrioritization` / Responsive Capture).
    public var prioritizeFasterShooting = true
    /// Allow music or podcasts to keep playing while filming.
    public var allowAudioPlayback = true
    /// Default main-camera focal length (24 / 28 / 35 mm).
    public var defaultFocalLength = FocalLength.mm24
    /// Hold Volume Up to take a burst of photos.
    public var volumeUpForBurst = true
    /// Which controls are pinned to the camera's top bar.
    public var topBarControls = CameraControls.defaultTopBarControls
    /// Active photographic style in the camera (`nil` or default standard = none).
    public var photographicStyle: PhotographicStyle?
    /// Active camera filter (`nil` = original).
    public var photoFilter: PhotoFilter?
    /// Portrait mode depth-of-field f-stop (1.4…16).
    public var portraitAperture = PortraitMath.defaultAperture
    /// Portrait mode lighting style.
    public var portraitLighting = PortraitLighting.natural
    // Preserve Settings
    public var preserveMode = false
    public var keptMode: String?
    public var preserveStyle = false
    public var preservePortraitZoom = false
    public var preserveExposure = false
    public var keptExposureBias = 0.0
    public var preserveLivePhoto = true
    public var preserveResolution = false
    /// Manual camera values stay when the camera closes (else everything goes back to automatic).
    public var keepManualSettings = false
    /// The manual values kept, when they are.
    public var keptManual: ManualSettings?
    /// Photos farther from home than this make a trip.
    public var tripKilometres = 50.0
    /// Which copy of a video plays from the server.
    public var videoCopy = VideoCopy.automatic
    /// This iPhone makes the small copies of its videos (else the server does).
    public var makeSmallCopies = true

    // Place
    public var locationAccuracyLimit = 50.0
    public var inaccurateLocation = InaccurateLocation.mark
    /// Screenshots (and screen recordings) without GPS get an estimated place in Halden.
    public var locateScreenshots = true
    /// Use this iPhone's current place for screenshots taken within this many minutes; older ones
    /// take the place of the nearest photo within two hours.
    public var screenshotPlaceMaxMinutes = 30
    /// Give screen recordings an estimated place the same way as screenshots.
    public var locateScreenRecordings = true

    // Apple Photos
    /// Photos and videos from other apps (Apple's camera, screenshots, …) come into Halden.
    public var importFromPhotos = true
    /// Photos taken with Halden go into Apple Photos too.
    public var saveToPhotos = true
    /// Deleting in one place offers to delete in the other.
    public var syncDeletionsWithPhotos = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case uploadOverCellular, videosOnlyOnWiFi, onlyOnHomeNetwork, keepLocalCopies
        case photoFormat, photoAspectRatio, photoResolution, captureRAW
        case videoResolution, videoFrameRate, videoHDR, autoLowLightFPS, lockVideoCamera, lockVideoWhiteBalance
        case flash, showGrid, showLevel, mirrorFrontCamera, lensCorrection
        case livePhotos, slowMotionRate, timeLapseInterval
        case prioritizeFasterShooting, allowAudioPlayback, defaultFocalLength, volumeUpForBurst
        case topBarControls, photographicStyle, photoFilter, portraitAperture, portraitLighting
        case preserveMode, keptMode, preserveStyle, preservePortraitZoom, preserveExposure, keptExposureBias,
            preserveLivePhoto, preserveResolution
        case keepManualSettings, keptManual, tripKilometres, videoCopy, makeSmallCopies
        case locationAccuracyLimit, inaccurateLocation
        case locateScreenshots, screenshotPlaceMaxMinutes, locateScreenRecordings
        case importFromPhotos, saveToPhotos, syncDeletionsWithPhotos
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
        read(.photoAspectRatio, into: &settings.photoAspectRatio)
        read(.photoResolution, into: &settings.photoResolution)
        read(.captureRAW, into: &settings.captureRAW)
        read(.videoResolution, into: &settings.videoResolution)
        read(.videoFrameRate, into: &settings.videoFrameRate)
        read(.videoHDR, into: &settings.videoHDR)
        read(.autoLowLightFPS, into: &settings.autoLowLightFPS)
        read(.lockVideoCamera, into: &settings.lockVideoCamera)
        read(.lockVideoWhiteBalance, into: &settings.lockVideoWhiteBalance)
        read(.flash, into: &settings.flash)
        read(.showGrid, into: &settings.showGrid)
        read(.showLevel, into: &settings.showLevel)
        read(.mirrorFrontCamera, into: &settings.mirrorFrontCamera)
        read(.lensCorrection, into: &settings.lensCorrection)
        read(.livePhotos, into: &settings.livePhotos)
        read(.slowMotionRate, into: &settings.slowMotionRate)
        read(.timeLapseInterval, into: &settings.timeLapseInterval)
        read(.prioritizeFasterShooting, into: &settings.prioritizeFasterShooting)
        read(.allowAudioPlayback, into: &settings.allowAudioPlayback)
        read(.defaultFocalLength, into: &settings.defaultFocalLength)
        read(.volumeUpForBurst, into: &settings.volumeUpForBurst)
        read(.topBarControls, into: &settings.topBarControls)
        settings.topBarControls = CameraControls.sanitizedTopBar(settings.topBarControls)
        read(.photographicStyle, into: &settings.photographicStyle)
        read(.photoFilter, into: &settings.photoFilter)
        read(.portraitAperture, into: &settings.portraitAperture)
        read(.portraitLighting, into: &settings.portraitLighting)
        read(.preserveMode, into: &settings.preserveMode)
        read(.keptMode, into: &settings.keptMode)
        read(.preserveStyle, into: &settings.preserveStyle)
        read(.preservePortraitZoom, into: &settings.preservePortraitZoom)
        read(.preserveExposure, into: &settings.preserveExposure)
        read(.keptExposureBias, into: &settings.keptExposureBias)
        read(.preserveLivePhoto, into: &settings.preserveLivePhoto)
        read(.preserveResolution, into: &settings.preserveResolution)
        read(.keepManualSettings, into: &settings.keepManualSettings)
        read(.keptManual, into: &settings.keptManual)
        read(.tripKilometres, into: &settings.tripKilometres)
        read(.videoCopy, into: &settings.videoCopy)
        read(.makeSmallCopies, into: &settings.makeSmallCopies)
        read(.locationAccuracyLimit, into: &settings.locationAccuracyLimit)
        read(.inaccurateLocation, into: &settings.inaccurateLocation)
        read(.locateScreenshots, into: &settings.locateScreenshots)
        read(.screenshotPlaceMaxMinutes, into: &settings.screenshotPlaceMaxMinutes)
        read(.locateScreenRecordings, into: &settings.locateScreenRecordings)
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
