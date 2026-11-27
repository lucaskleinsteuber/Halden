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

    /// Each preset has a character of its own at the default palette: warm tones differ in hue
    /// (amber orange, gold yellow, rose pink, cozy dark), the quiet ones in contrast and colour.
    var profile: Profile {
        switch self {
        case .standard:
            Profile()
        case .amber:
            Profile(contrast: 0.08, shadows: 0.05, saturation: 0.10, vibrance: 0.12, warmth: 0.48, tint: 0.10)
        case .gold:
            Profile(
                exposure: 0.14, contrast: 0.04, highlights: 0.12, saturation: 0.16, vibrance: 0.12, warmth: 0.34,
                tint: -0.22)
        case .roseGold:
            Profile(exposure: 0.06, shadows: 0.10, saturation: 0.04, vibrance: 0.10, warmth: 0.18, tint: 0.48)
        case .neutral:
            Profile(contrast: -0.14, shadows: 0.16, highlights: -0.06, saturation: -0.28, warmth: -0.16)
        case .coolRose:
            Profile(contrast: 0.06, saturation: 0.04, vibrance: 0.10, warmth: -0.50, tint: 0.30)
        case .vibrant:
            Profile(contrast: 0.20, shadows: 0.04, saturation: 0.42, vibrance: 0.45, warmth: 0.04)
        case .natural:
            Profile(contrast: -0.06, shadows: 0.22, highlights: -0.18, saturation: -0.06, vibrance: 0.22)
        case .luminous:
            Profile(exposure: 0.32, contrast: -0.10, shadows: 0.30, highlights: 0.14, vibrance: 0.16, warmth: 0.06)
        case .dramatic:
            Profile(
                exposure: -0.22, contrast: 0.48, shadows: -0.36, highlights: 0.08, saturation: -0.16, vibrance: 0.04)
        case .quiet:
            Profile(exposure: -0.06, contrast: -0.20, shadows: 0.10, saturation: -0.42, warmth: -0.06)
        case .cozy:
            Profile(exposure: -0.16, contrast: 0.14, shadows: 0.06, highlights: -0.18, saturation: 0.06, warmth: 0.56)
        case .ethereal:
            Profile(
                exposure: 0.26, contrast: -0.26, shadows: 0.32, highlights: 0.16, saturation: -0.22, vibrance: 0.06,
                warmth: -0.16, tint: 0.22)
        case .mutedBW:
            Profile(contrast: -0.12, shadows: 0.18, highlights: -0.12, monochrome: true)
        case .starkBW:
            Profile(exposure: -0.06, contrast: 0.58, shadows: -0.38, highlights: 0.16, monochrome: true)
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

/// Camera filters, stored non-destructively in `EditRecipe` (version 2). Each one is strong
/// enough to recognise at a glance; `filterIntensity` blends it with the original.
public enum PhotoFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case vivid
    case warm
    case cool
    case dramatic
    case film
    case faded
    case mono
    case noir
    case sepia
    // Filters of earlier versions: still shown on photos that have them, no longer offered.
    case vividWarm
    case vividCool
    case dramaticWarm
    case dramaticCool
    case silvertone

    /// The filters offered in the camera and the editor, in this order.
    public static let allCases: [PhotoFilter] = [.vivid, .warm, .cool, .dramatic, .film, .faded, .mono, .noir, .sepia]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .dramatic: "Dramatic"
        case .film: "Film"
        case .faded: "Faded"
        case .mono: "Mono"
        case .noir: "Noir"
        case .sepia: "Sepia"
        case .vividWarm: "Vivid Warm"
        case .vividCool: "Vivid Cool"
        case .dramaticWarm: "Dramatic Warm"
        case .dramaticCool: "Dramatic Cool"
        case .silvertone: "Silvertone"
        }
    }

    public var isMonochrome: Bool {
        self == .mono || self == .noir || self == .silvertone
    }

    /// How strongly a filter is applied: 0 (the original) to 1 (full), default 1.
    public static func clampedIntensity(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return (min(max(value, 0), 1) * 100).rounded() / 100
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

    /// Applies photographic `style` and/or `filter` (blended with what is underneath by
    /// `filterIntensity`, 0…1) to `image`. Returns `image` untouched if both are inactive.
    public static func apply(
        style: PhotographicStyle?, filter: PhotoFilter?, filterIntensity: Double = 1, to image: CIImage
    ) -> CIImage {
        var output = image
        if let style = style?.fitted, !style.isDefault {
            output = applyStyle(style, to: output)
        }
        if let filter {
            let intensity = PhotoFilter.clampedIntensity(filterIntensity)
            guard intensity > 0.005 else { return output }
            let filtered = applyFilter(filter, to: output).cropped(to: output.extent)
            if intensity >= 0.995 { return filtered }
            let blend = CIFilter.dissolveTransition()
            blend.inputImage = output
            blend.targetImage = filtered
            blend.time = Float(intensity)
            output = blend.outputImage?.cropped(to: output.extent) ?? filtered
        }
        return output
    }

    private static func applyStyle(_ style: PhotographicStyle, to image: CIImage) -> CIImage {
        var output = image
        let p = style.preset.profile
        // Palette scales the preset's signature character from 0.2× (at 0) to 1.8× (at 1);
        // the default 0.5 gives exactly the preset's own strength.
        let strength = 0.2 + style.palette * 1.6

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
            filter.contrast = Float(max(0.5, 1 + contrast * 0.8))
            filter.saturation = Float(max(0, 1 + saturation))
            output = filter.outputImage ?? output
        }

        let shadows = p.shadows * strength + style.tone * 0.28
        let highlights = p.highlights * strength + style.tone * 0.12
        if abs(shadows) > 0.005 || abs(highlights) > 0.005 {
            let filter = CIFilter.toneCurve()
            filter.inputImage = output
            filter.point0 = CGPoint(x: 0, y: 0)
            filter.point1 = CGPoint(x: 0.25, y: min(max(0.25 + shadows * 0.22, 0.05), 0.48))
            filter.point2 = CGPoint(x: 0.5, y: min(max(0.5 + (shadows + highlights) * 0.06, 0.25), 0.75))
            filter.point3 = CGPoint(x: 0.75, y: min(max(0.75 + highlights * 0.2, 0.52), 0.97))
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
                filter.targetNeutral = CIVector(x: 6500 - warmth * 3000, y: -tint * 70)
                output = filter.outputImage ?? output
            }
        }
        return output
    }

    private static func applyFilter(_ kind: PhotoFilter, to image: CIImage) -> CIImage {
        switch kind {
        case .vivid:
            let punchy = colorControls(image, contrast: 1.16, saturation: 1.5)
            return vibrance(punchy, 0.35)
        case .warm:
            let golden = temperature(image, to: 4500, tint: -6)
            return colorControls(exposure(golden, 0.06), contrast: 1.04, saturation: 1.12)
        case .cool:
            let blue = temperature(image, to: 9500, tint: 6)
            return colorControls(blue, contrast: 1.06, saturation: 0.92)
        case .dramatic:
            let curved = toneCurve(
                exposure(image, -0.18), [(0, 0), (0.25, 0.14), (0.5, 0.44), (0.75, 0.8), (1, 1)])
            return vignette(colorControls(curved, contrast: 1.28, saturation: 0.72), intensity: 0.9)
        case .film:
            // Lifted blacks, softened whites, a little warmth and grain.
            let faded = toneCurve(image, [(0, 0.08), (0.25, 0.27), (0.5, 0.52), (0.75, 0.76), (1, 0.93)])
            let tinted = colorControls(temperature(faded, to: 5700, tint: -4), contrast: 1.04, saturation: 0.86)
            return grain(tinted, amount: 0.06)
        case .faded:
            let lifted = toneCurve(image, [(0, 0.16), (0.25, 0.32), (0.5, 0.53), (0.75, 0.74), (1, 0.9)])
            return colorControls(temperature(lifted, to: 7200, tint: 0), contrast: 0.9, saturation: 0.55)
        case .mono:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            return colorControls(mono.outputImage ?? image, contrast: 1.08, saturation: 0)
        case .noir:
            let noir = CIFilter.photoEffectNoir()
            noir.inputImage = image
            return vignette(noir.outputImage ?? image, intensity: 1.0)
        case .sepia:
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = image
            sepia.intensity = 0.9
            return colorControls(sepia.outputImage ?? image, contrast: 1.06, saturation: 1)
        case .vividWarm:
            return temperature(legacyVivid(image), to: 5400, tint: -8)
        case .vividCool:
            return temperature(legacyVivid(image), to: 7600, tint: 6)
        case .dramaticWarm:
            return temperature(legacyDramatic(image), to: 5300, tint: -10)
        case .dramaticCool:
            return temperature(legacyDramatic(image), to: 7800, tint: 8)
        case .silvertone:
            let tonal = CIFilter.photoEffectTonal()
            tonal.inputImage = image
            return colorControls(tonal.outputImage ?? image, contrast: 1.15, saturation: 0)
        }
    }

    private static func legacyVivid(_ image: CIImage) -> CIImage {
        vibrance(colorControls(image, contrast: 1.12, saturation: 1.28), 0.25)
    }

    private static func legacyDramatic(_ image: CIImage) -> CIImage {
        let curved = toneCurve(image, [(0, 0), (0.25, 0.16), (0.5, 0.46), (0.75, 0.78), (1, 1)])
        return colorControls(curved, contrast: 1.22, saturation: 0.85)
    }

    private static func colorControls(_ image: CIImage, contrast: Float, saturation: Float) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = contrast
        filter.saturation = saturation
        return filter.outputImage ?? image
    }

    private static func vibrance(_ image: CIImage, _ amount: Float) -> CIImage {
        let filter = CIFilter.vibrance()
        filter.inputImage = image
        filter.amount = amount
        return filter.outputImage ?? image
    }

    private static func exposure(_ image: CIImage, _ ev: Float) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = ev
        return filter.outputImage ?? image
    }

    /// Lower `kelvin` than 6500 is warmer, higher cooler; negative `tint` is magenta.
    private static func temperature(_ image: CIImage, to kelvin: Double, tint: Double) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: kelvin, y: tint)
        return filter.outputImage ?? image
    }

    private static func toneCurve(_ image: CIImage, _ points: [(Double, Double)]) -> CIImage {
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        let p = points.map { CGPoint(x: $0.0, y: $0.1) }
        filter.point0 = p[0]
        filter.point1 = p[1]
        filter.point2 = p[2]
        filter.point3 = p[3]
        filter.point4 = p[4]
        return filter.outputImage ?? image
    }

    private static func vignette(_ image: CIImage, intensity: Float) -> CIImage {
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = intensity
        filter.radius = Float(max(image.extent.width, image.extent.height) / 1.6)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    /// Fine monochrome grain, the same pattern every time (so a photo always looks the same).
    private static func grain(_ image: CIImage, amount: Double) -> CIImage {
        guard image.extent.width.isFinite, image.extent.height.isFinite else { return image }
        let noise = CIFilter.randomGenerator().outputImage ?? image
        let scale = max(1, min(image.extent.width, image.extent.height) / 1200)
        let gray = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount)),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ]
            )
            .cropped(to: image.extent)
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = gray
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }
}
