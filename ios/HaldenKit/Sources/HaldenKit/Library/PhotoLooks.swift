import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Halden's photographic style presets (inspired by Apple's Photographic Styles, implemented
/// non-destructively with Core Image so they can be changed before or after capture).
public enum PhotographicStylePreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard
    case amber
    case gold
    case roseGold
    case neutral
    case coolRose
    case vibrant
    case natural
    case luminous
    case dramatic
    case quiet
    case cozy
    case ethereal
    case mutedBW
    case starkBW

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .amber: "Amber"
        case .gold: "Gold"
        case .roseGold: "Rose Gold"
        case .neutral: "Neutral"
        case .coolRose: "Cool Rose"
        case .vibrant: "Vibrant"
        case .natural: "Natural"
        case .luminous: "Luminous"
        case .dramatic: "Dramatic"
        case .quiet: "Quiet"
        case .cozy: "Cozy"
        case .ethereal: "Ethereal"
        case .mutedBW: "Muted B&W"
        case .starkBW: "Stark B&W"
        }
    }

    public var isMonochrome: Bool {
        self == .mutedBW || self == .starkBW
    }

    /// Base recipe parameters for this style before tone/color/palette adjustments.
    struct Profile {
        var exposure: Double = 0
        var contrast: Double = 0
        var shadows: Double = 0
        var highlights: Double = 0
        var saturation: Double = 0
        var vibrance: Double = 0
        var warmth: Double = 0
        var tint: Double = 0
        var monochrome: Bool = false
    }

    var profile: Profile {
        switch self {
        case .standard:
            Profile()
        case .amber:
            Profile(contrast: 0.06, shadows: 0.05, saturation: 0.12, vibrance: 0.14, warmth: 0.34, tint: 0.04)
        case .gold:
            Profile(exposure: 0.08, contrast: 0.04, highlights: 0.08, saturation: 0.08, vibrance: 0.12, warmth: 0.28)
        case .roseGold:
            Profile(exposure: 0.05, shadows: 0.08, saturation: 0.06, vibrance: 0.12, warmth: 0.18, tint: 0.22)
        case .neutral:
            Profile(contrast: -0.06, shadows: 0.06, saturation: -0.08, warmth: -0.04)
        case .coolRose:
            Profile(contrast: 0.04, saturation: 0.04, vibrance: 0.08, warmth: -0.38, tint: 0.14)
        case .vibrant:
            Profile(contrast: 0.14, shadows: 0.06, saturation: 0.24, vibrance: 0.34, warmth: 0.05)
        case .natural:
            Profile(contrast: 0.06, shadows: 0.08, highlights: -0.06, vibrance: 0.10)
        case .luminous:
            Profile(exposure: 0.22, contrast: -0.04, shadows: 0.20, highlights: 0.12, vibrance: 0.12, warmth: 0.08)
        case .dramatic:
            Profile(
                exposure: -0.16, contrast: 0.34, shadows: -0.26, highlights: 0.06, saturation: -0.08, vibrance: 0.06)
        case .quiet:
            Profile(exposure: -0.08, contrast: -0.10, shadows: 0.04, saturation: -0.26, warmth: -0.10)
        case .cozy:
            Profile(exposure: -0.06, contrast: 0.08, shadows: 0.10, highlights: -0.10, saturation: 0.08, warmth: 0.32)
        case .ethereal:
            Profile(
                exposure: 0.18, contrast: -0.14, shadows: 0.24, highlights: 0.18, saturation: -0.12, vibrance: 0.08,
                warmth: -0.08, tint: 0.10)
        case .mutedBW:
            Profile(contrast: 0.06, shadows: 0.10, highlights: -0.08, monochrome: true)
        case .starkBW:
            Profile(exposure: -0.06, contrast: 0.42, shadows: -0.28, highlights: 0.12, monochrome: true)
        }
    }
}

/// A photographic style with its preset, 2D tone/color control-pad offsets (−1…+1), and palette
/// strength (0…1). Stored non-destructively in `EditRecipe` (version 2).
public struct PhotographicStyle: Codable, Sendable, Hashable {
    public var preset: PhotographicStylePreset
    /// Vertical axis on the control pad: −1 (deeper/moodier) to +1 (brighter/softer).
    public var tone: Double
    /// Horizontal axis on the control pad: −1 (muted) to +1 (richer color).
    public var color: Double
    /// Palette intensity: 0 (subtle) to 1 (full strength), default 0.5.
    public var palette: Double

    public init(
        preset: PhotographicStylePreset = .standard, tone: Double = 0, color: Double = 0, palette: Double = 0.5
    ) {
        self.preset = preset
        self.tone = tone
        self.color = color
        self.palette = palette
    }

    public var isDefault: Bool {
        preset == .standard && abs(tone) < 0.005 && abs(color) < 0.005
    }

    public var fitted: PhotographicStyle {
        PhotographicStyle(
            preset: preset,
            tone: min(max(tone, -1), 1),
            color: min(max(color, -1), 1),
            palette: min(max(palette, 0), 1))
    }

    enum CodingKeys: String, CodingKey {
        case preset, tone, color, palette
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? container.decode(PhotographicStylePreset.self, forKey: .preset)) ?? .standard
        tone = (try? container.decodeIfPresent(Double.self, forKey: .tone)) ?? 0
        color = (try? container.decodeIfPresent(Double.self, forKey: .color)) ?? 0
        palette = (try? container.decodeIfPresent(Double.self, forKey: .palette)) ?? 0.5
    }
}

/// Classic camera filters, stored non-destructively in `EditRecipe` (version 2).
public enum PhotoFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case vivid
    case vividWarm
    case vividCool
    case dramatic
    case dramaticWarm
    case dramaticCool
    case mono
    case silvertone
    case noir

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vivid: "Vivid"
        case .vividWarm: "Vivid Warm"
        case .vividCool: "Vivid Cool"
        case .dramatic: "Dramatic"
        case .dramaticWarm: "Dramatic Warm"
        case .dramaticCool: "Dramatic Cool"
        case .mono: "Mono"
        case .silvertone: "Silvertone"
        case .noir: "Noir"
        }
    }
}

/// GPU Core Image renderer for Photographic Styles and Filters, shared by the live Metal camera
/// viewfinder (`MetalPreviewView`) and non-destructive editing (`EditRenderer`).
public enum LookRenderer {
    /// Whether the custom Metal + Core Image viewfinder must run instead of the lighter system
    /// `AVCaptureVideoPreviewLayer`.
    public static func needsCustomPreview(
        style: PhotographicStyle?, filter: PhotoFilter?, isPortrait: Bool = false, showScopes: Bool = false
    ) -> Bool {
        if isPortrait || showScopes { return true }
        if filter != nil { return true }
        if let style, !style.isDefault { return true }
        return false
    }

    /// Applies photographic `style` and/or `filter` to `image`. Returns `image` untouched if both
    /// are inactive.
    public static func apply(style: PhotographicStyle?, filter: PhotoFilter?, to image: CIImage) -> CIImage {
        var output = image
        if let style = style?.fitted, !style.isDefault {
            output = applyStyle(style, to: output)
        }
        if let filter {
            output = applyFilter(filter, to: output)
        }
        return output
    }

    private static func applyStyle(_ style: PhotographicStyle, to image: CIImage) -> CIImage {
        var output = image
        let p = style.preset.profile
        // Palette scales the preset's signature character from 0.25× (at 0) to 1.5× (at 1);
        // 0.5 gives 1.0× natural preset strength.
        let strength = 0.25 + style.palette * 1.25

        let exposure = p.exposure * strength + style.tone * 0.45
        if abs(exposure) > 0.005 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(exposure)
            output = filter.outputImage ?? output
        }

        let contrast = p.contrast * strength - style.tone * 0.14
        let saturation: Double = p.monochrome ? -1.0 : (p.saturation * strength + style.color * 0.45)
        if abs(contrast) > 0.005 || abs(saturation) > 0.005 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.contrast = Float(max(0.5, 1 + contrast * 0.55))
            filter.saturation = Float(max(0, 1 + saturation))
            output = filter.outputImage ?? output
        }

        let shadows = p.shadows * strength + style.tone * 0.28
        let highlights = p.highlights * strength + style.tone * 0.12
        if abs(shadows) > 0.005 || abs(highlights) > 0.005 {
            let filter = CIFilter.toneCurve()
            filter.inputImage = output
            filter.point0 = CGPoint(x: 0, y: 0)
            filter.point1 = CGPoint(x: 0.25, y: min(max(0.25 + shadows * 0.14, 0.05), 0.48))
            filter.point2 = CGPoint(x: 0.5, y: min(max(0.5 + (shadows + highlights) * 0.04, 0.25), 0.75))
            filter.point3 = CGPoint(x: 0.75, y: min(max(0.75 + highlights * 0.14, 0.52), 0.95))
            filter.point4 = CGPoint(x: 1, y: 1)
            output = filter.outputImage ?? output
        }

        if !p.monochrome {
            let vibrance = p.vibrance * strength + style.color * 0.35
            if abs(vibrance) > 0.005 {
                let filter = CIFilter.vibrance()
                filter.inputImage = output
                filter.amount = Float(min(max(vibrance, -1), 1))
                output = filter.outputImage ?? output
            }
            let warmth = p.warmth * strength
            let tint = p.tint * strength
            if abs(warmth) > 0.005 || abs(tint) > 0.005 {
                let filter = CIFilter.temperatureAndTint()
                filter.inputImage = output
                filter.neutral = CIVector(x: 6500, y: 0)
                filter.targetNeutral = CIVector(x: 6500 - warmth * 2200, y: -tint * 55)
                output = filter.outputImage ?? output
            }
        }
        return output
    }

    private static func applyFilter(_ kind: PhotoFilter, to image: CIImage) -> CIImage {
        var output = image
        switch kind {
        case .vivid:
            let cc = CIFilter.colorControls()
            cc.inputImage = output
            cc.contrast = 1.12
            cc.saturation = 1.28
            output = cc.outputImage ?? output
            let vib = CIFilter.vibrance()
            vib.inputImage = output
            vib.amount = 0.25
            return vib.outputImage ?? output
        case .vividWarm:
            output = applyFilter(.vivid, to: output)
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5400, y: -8)
            return temp.outputImage ?? output
        case .vividCool:
            output = applyFilter(.vivid, to: output)
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 7600, y: 6)
            return temp.outputImage ?? output
        case .dramatic:
            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.16)
            curve.point2 = CGPoint(x: 0.5, y: 0.46)
            curve.point3 = CGPoint(x: 0.75, y: 0.78)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
            let cc = CIFilter.colorControls()
            cc.inputImage = output
            cc.contrast = 1.22
            cc.saturation = 0.85
            return cc.outputImage ?? output
        case .dramaticWarm:
            output = applyFilter(.dramatic, to: output)
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 5300, y: -10)
            return temp.outputImage ?? output
        case .dramaticCool:
            output = applyFilter(.dramatic, to: output)
            let temp = CIFilter.temperatureAndTint()
            temp.inputImage = output
            temp.neutral = CIVector(x: 6500, y: 0)
            temp.targetNeutral = CIVector(x: 7800, y: 8)
            return temp.outputImage ?? output
        case .mono:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = output
            return mono.outputImage ?? output
        case .silvertone:
            let tonal = CIFilter.photoEffectTonal()
            tonal.inputImage = output
            output = tonal.outputImage ?? output
            let cc = CIFilter.colorControls()
            cc.inputImage = output
            cc.contrast = 1.15
            return cc.outputImage ?? output
        case .noir:
            let noir = CIFilter.photoEffectNoir()
            noir.inputImage = output
            return noir.outputImage ?? output
        }
    }
}
