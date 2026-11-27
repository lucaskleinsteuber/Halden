import Foundation

/// Photo aspect ratios in the camera. Halden always captures the full sensor frame and applies
/// non-4:3 ratios non-destructively as `EditRecipe.crop` (Apple Photos receives the cropped copy).
public enum PhotoAspectRatio: String, Codable, Sendable, CaseIterable, Identifiable {
    case fourByThree = "4:3"
    case sixteenByNine = "16:9"
    case square = "1:1"

    public var id: String { rawValue }

    /// Portrait viewfinder width / height ratio on screen.
    public var portraitRatio: Double {
        switch self {
        case .fourByThree: 3.0 / 4.0
        case .sixteenByNine: 9.0 / 16.0
        case .square: 1.0
        }
    }

    public var label: String { rawValue }

    /// Centered non-destructive crop for a photo of `width` × `height` pixels, or `nil` when the
    /// ratio already matches (such as native 4:3). Keeps the photo's orientation (landscape stays
    /// landscape, portrait stays portrait).
    public func crop(forWidth width: Int, height: Int) -> EditRecipe.Crop? {
        guard width > 0, height > 0, self != .fourByThree else { return nil }
        let current = Double(width) / Double(height)
        let target: Double
        switch self {
        case .fourByThree: return nil
        case .square: target = 1.0
        case .sixteenByNine: target = width >= height ? (16.0 / 9.0) : (9.0 / 16.0)
        }
        if abs(current - target) < 0.01 { return nil }
        if current > target {
            let croppedWidth = target / current
            return EditRecipe.Crop(x: (1 - croppedWidth) / 2, y: 0, width: croppedWidth, height: 1).fitted
        } else {
            let croppedHeight = current / target
            return EditRecipe.Crop(x: 0, y: (1 - croppedHeight) / 2, width: 1, height: croppedHeight).fitted
        }
    }
}

/// Photo capture resolution targets (12 / 24 / 48 MP "HEIF Max").
public enum PhotoResolution: Int, Codable, Sendable, CaseIterable, Identifiable {
    case mp12 = 12
    case mp24 = 24
    case mp48 = 48

    public var id: Int { rawValue }
    public var label: String { "\(rawValue) MP" }
    public var shortLabel: String { "\(rawValue)" }

    /// Megapixels rounded to the nearest integer (e.g. 4032 × 3024 ≈ 12 MP).
    public static func megapixels(width: Int, height: Int) -> Double {
        Double(width) * Double(height) / 1_000_000.0
    }

    /// Which resolution options the camera's supported photo dimensions allow: only those it
    /// really has (a camera with 12 and 48 MP but nothing near 24 MP doesn't offer 24 MP, which
    /// would silently become 12 MP).
    public static func available(for dimensions: [(width: Int, height: Int)]) -> [PhotoResolution] {
        let sizes = dimensions.map { megapixels(width: $0.width, height: $0.height) }
        var found: [PhotoResolution] = [.mp12]
        if sizes.contains(where: { (21.5...27).contains($0) }) { found.append(.mp24) }
        if sizes.contains(where: { (43...53).contains($0) }) { found.append(.mp48) }
        return found
    }

    /// The resolution to use when `wanted` isn't available: the largest one below it.
    public static func fitted(_ wanted: PhotoResolution, in available: [PhotoResolution]) -> PhotoResolution {
        if available.contains(wanted) { return wanted }
        return available.filter { $0.rawValue < wanted.rawValue }.max { $0.rawValue < $1.rawValue } ?? .mp12
    }

    /// Index into `dimensions` that best matches `wanted`: highest dimension not exceeding
    /// `wanted` (+10% margin), falling back to the closest available dimension.
    public static func bestDimensionIndex(
        wanted: PhotoResolution, in dimensions: [(width: Int, height: Int)]
    ) -> Int? {
        guard !dimensions.isEmpty else { return nil }
        let target = Double(wanted.rawValue)
        let scored = dimensions.enumerated().map {
            ($0.offset, megapixels(width: $0.element.width, height: $0.element.height))
        }
        let fitting = scored.filter { $0.1 <= target * 1.12 }
        if let best = fitting.max(by: { $0.1 < $1.1 }) { return best.0 }
        return scored.min(by: { abs($0.1 - target) < abs($1.1 - target) })?.0
    }
}

/// Main-camera focal length presets (24 / 28 / 35 mm), mapped to zoom on the 1× lens.
public enum FocalLength: Int, Codable, Sendable, CaseIterable, Identifiable {
    case mm24 = 24
    case mm28 = 28
    case mm35 = 35

    public var id: Int { rawValue }
    public var label: String { "\(rawValue) mm" }

    /// Equivalent zoom factor on a 24 mm main lens.
    public var zoomFactor: Double {
        switch self {
        case .mm24: 1.0
        case .mm28: 1.2
        case .mm35: 1.5
        }
    }

    /// Next focal length when cycling on the 1× button.
    public var next: FocalLength {
        switch self {
        case .mm24: .mm28
        case .mm28: .mm35
        case .mm35: .mm24
        }
    }

    /// Recognises a zoom factor as one of the main-camera focal lengths (within tolerance).
    public static func matching(zoom: Double) -> FocalLength? {
        allCases.first { abs($0.zoomFactor - zoom) < 0.06 }
    }
}

/// Controls that can be pinned to the camera's top bar ("Customizable controls").
public enum TopBarControl: String, Codable, Sendable, CaseIterable, Identifiable {
    case flash
    case manual
    case timer
    case live
    case exposure
    case aspectRatio
    case resolution
    case raw
    case grid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flash: "Flash / Light"
        case .manual: "Manual controls"
        case .timer: "Self-timer"
        case .live: "Live Photo"
        case .exposure: "Exposure (EV)"
        case .aspectRatio: "Aspect ratio"
        case .resolution: "Resolution (MP)"
        case .raw: "RAW"
        case .grid: "Grid"
        }
    }

    public var symbol: String {
        switch self {
        case .flash: "bolt.badge.automatic"
        case .manual: "slider.horizontal.3"
        case .timer: "timer"
        case .live: "livephoto"
        case .exposure: "plusminus"
        case .aspectRatio: "aspectratio"
        case .resolution: "camera.metering.center.weighted"
        case .raw: "r.square"
        case .grid: "grid"
        }
    }

    /// Shown only in photo mode; automatically hidden in video modes.
    public var photoOnly: Bool {
        switch self {
        case .live, .aspectRatio, .resolution, .raw: true
        case .flash, .manual, .timer, .exposure, .grid: false
        }
    }
}

/// Items in the expandable iOS 26 camera control drawer (above the mode strip).
/// Extended in later stages with Night (C8), Styles (C6), Portrait (C7), Action & Audio (C9).
public enum CameraDrawerItem: String, Sendable, Hashable, Identifiable {
    case flash
    case night
    case live
    case style
    case filter
    case exposure
    case aspectRatio
    case timer
    case resolution
    case raw
    case videoResolution
    case videoFrameRate
    case videoHDR
    case autoLowLightFPS

    public var id: String { rawValue }
}

/// Pure rules, limits and defaults for the camera controls and Settings › Camera.
public enum CameraControls {
    /// Self-timer steps in seconds: off, 3, 5, 10.
    public static let timerSteps = [0, 3, 5, 10]

    /// Quick exposure compensation range in the camera drawer (EV −2…+2).
    public static let exposureBiasRange: ClosedRange<Double> = -2.0...2.0

    /// Supported video frame rates; 25 fps is PAL.
    public static let videoFrameRates = [24, 25, 30, 60]

    /// Default buttons pinned to the camera's top bar.
    public static let defaultTopBarControls: [TopBarControl] = [.flash, .manual, .timer, .live]

    /// Maximum buttons pinned to the top bar so nothing crowds or overlaps on 390 pt screens.
    public static let maxTopBarControls = 4

    /// Next self-timer step: 0 → 3 → 5 → 10 → 0.
    public static func nextTimer(after seconds: Int) -> Int {
        guard let index = timerSteps.firstIndex(of: seconds) else { return timerSteps[1] }
        return timerSteps[(index + 1) % timerSteps.count]
    }

    /// Clamps EV to −2…+2 and snaps to thirds of a stop (0.3 / 0.7 / 1.0 …).
    public static func clampedExposureBias(_ value: Double) -> Double {
        let clamped = min(max(value, exposureBiasRange.lowerBound), exposureBiasRange.upperBound)
        let snapped = (clamped * 3).rounded() / 3
        return abs(snapped) < 0.01 ? 0 : snapped
    }

    public static func isPAL(frameRate: Int) -> Bool {
        frameRate == 25
    }

    public static func frameRateLabel(_ frameRate: Int) -> String {
        isPAL(frameRate: frameRate) ? "25 fps (PAL)" : "\(frameRate) fps"
    }

    public static func shortFrameRateLabel(_ frameRate: Int) -> String {
        isPAL(frameRate: frameRate) ? "25 PAL" : "\(frameRate)"
    }

    /// Deduplicates and caps the customizable top bar controls (falls back to default if empty).
    public static func sanitizedTopBar(_ controls: [TopBarControl]) -> [TopBarControl] {
        var unique: [TopBarControl] = []
        for control in controls where !unique.contains(control) {
            unique.append(control)
            if unique.count == maxTopBarControls { break }
        }
        return unique.isEmpty ? defaultTopBarControls : unique
    }

    /// Returns the drawer items shown for a mode and device capabilities.
    public static func drawerItems(isPhoto: Bool, canLive: Bool, canRAW: Bool) -> [CameraDrawerItem] {
        if isPhoto {
            var items: [CameraDrawerItem] = [.flash]
            if canLive { items.append(.live) }
            items += [.style, .filter, .exposure, .aspectRatio, .timer, .resolution]
            if canRAW { items.append(.raw) }
            return items
        }
        return [.videoResolution, .videoFrameRate, .videoHDR, .autoLowLightFPS]
    }

    /// Applies "Preserve Settings" rules when the camera closes or reopens: settings not marked
    /// to preserve return to their sensible defaults.
    public static func resetUnpreserved(in settings: AppSettings) -> AppSettings {
        var next = settings
        if !settings.preserveMode { next.keptMode = nil }
        if !settings.preserveStyle {
            next.photographicStyle = nil
            next.photoFilter = nil
        }
        if !settings.preservePortraitZoom {
            next.portraitAperture = PortraitMath.defaultAperture
            next.portraitLighting = .natural
        }
        if !settings.preserveNightMode { next.nightMode = .auto }
        if !settings.preserveActionMode { next.actionMode = false }
        if !settings.preserveExposure { next.keptExposureBias = 0 }
        if !settings.preserveLivePhoto { next.livePhotos = true }
        if !settings.preserveResolution {
            next.photoResolution = .mp24
            next.captureRAW = false
            next.captureProRAW = false
        }
        if !settings.preserveMacro { next.macroMode = .auto }
        if !settings.keepManualSettings { next.keptManual = nil }
        return next
    }
}
