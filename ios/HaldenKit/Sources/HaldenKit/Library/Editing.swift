import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An edit, kept as what was set, never as pixels: light, colour, crop and turn for photos,
/// trimming for videos. The original stays as it is; the edit is applied whenever the photo is
/// shown or exported, and can always be taken back. Kept on the server as the asset's `edit`
/// (a correction with its history), so every device shows the same.
public struct EditRecipe: Codable, Sendable, Hashable {
    /// Version 2 adds photographic `style` and `filter` (version 1 edits still decode cleanly).
    public static let currentVersion = 2

    /// The values live in a box shared by copies until one changes (copy on write): the library
    /// holds one recipe per photo, and most photos have none, so a recipe costs a pointer there.
    struct Values: Codable, Hashable, Sendable {
        var version: Int = EditRecipe.currentVersion
        var exposure: Double = 0
        var brightness: Double = 0
        var contrast: Double = 0
        var highlights: Double = 0
        var shadows: Double = 0
        var saturation: Double = 0
        var vibrance: Double = 0
        var warmth: Double = 0
        var tint: Double = 0
        var style: PhotographicStyle? = nil
        var filter: PhotoFilter? = nil
        var portraitAperture: Double? = nil
        var portraitLighting: PortraitLighting? = nil
        var cinematicAperture: Double? = nil
        var cinematicFocusPoints: [CinematicFocusPoint]? = nil
        var quarterTurns: Int = 0
        var straighten: Double = 0
        var crop: Crop? = nil
        var trimStartMs: Int64? = nil
        var trimEndMs: Int64? = nil

        enum CodingKeys: String, CodingKey {
            case version, exposure, brightness, contrast, highlights, shadows, saturation, vibrance, warmth, tint
            case style, filter, portraitAperture, portraitLighting, cinematicAperture, cinematicFocusPoints
            case quarterTurns, straighten, crop, trimStartMs, trimEndMs
        }

        init() {}

        /// Missing values (an edit from an older version) are unchanged; unknown ones (from a
        /// newer version) are left out.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
                if let found = try? container.decodeIfPresent(T.self, forKey: key) { value = found }
            }
            read(.version, &version)
            read(.exposure, &exposure)
            read(.brightness, &brightness)
            read(.contrast, &contrast)
            read(.highlights, &highlights)
            read(.shadows, &shadows)
            read(.saturation, &saturation)
            read(.vibrance, &vibrance)
            read(.warmth, &warmth)
            read(.tint, &tint)
            style = try? container.decodeIfPresent(PhotographicStyle.self, forKey: .style)
            filter = try? container.decodeIfPresent(PhotoFilter.self, forKey: .filter)
            portraitAperture = try? container.decodeIfPresent(Double.self, forKey: .portraitAperture)
            portraitLighting = try? container.decodeIfPresent(PortraitLighting.self, forKey: .portraitLighting)
            cinematicAperture = try? container.decodeIfPresent(Double.self, forKey: .cinematicAperture)
            cinematicFocusPoints = try? container.decodeIfPresent(
                [CinematicFocusPoint].self, forKey: .cinematicFocusPoints)
            read(.quarterTurns, &quarterTurns)
            read(.straighten, &straighten)
            crop = try? container.decodeIfPresent(Crop.self, forKey: .crop)
            trimStartMs = try? container.decodeIfPresent(Int64.self, forKey: .trimStartMs)
            trimEndMs = try? container.decodeIfPresent(Int64.self, forKey: .trimEndMs)
        }
    }

    /// Changed only while nobody else holds it (see `change`).
    private final class Box: @unchecked Sendable {
        var values: Values
        init(_ values: Values) { self.values = values }
    }

    private var box: Box

    private mutating func change(_ update: (inout Values) -> Void) {
        if !isKnownUniquelyReferenced(&box) { box = Box(box.values) }
        update(&box.values)
    }

    public var version: Int {
        get { box.values.version }
        set { change { $0.version = newValue } }
    }
    // Light, each -1…1 (exposure in stops, -3…3).
    public var exposure: Double {
        get { box.values.exposure }
        set { change { $0.exposure = newValue } }
    }
    public var brightness: Double {
        get { box.values.brightness }
        set { change { $0.brightness = newValue } }
    }
    public var contrast: Double {
        get { box.values.contrast }
        set { change { $0.contrast = newValue } }
    }
    public var highlights: Double {
        get { box.values.highlights }
        set { change { $0.highlights = newValue } }
    }
    public var shadows: Double {
        get { box.values.shadows }
        set { change { $0.shadows = newValue } }
    }
    // Colour, each -1…1.
    public var saturation: Double {
        get { box.values.saturation }
        set { change { $0.saturation = newValue } }
    }
    public var vibrance: Double {
        get { box.values.vibrance }
        set { change { $0.vibrance = newValue } }
    }
    public var warmth: Double {
        get { box.values.warmth }
        set { change { $0.warmth = newValue } }
    }
    public var tint: Double {
        get { box.values.tint }
        set { change { $0.tint = newValue } }
    }
    /// Non-destructive photographic style (version 2).
    public var style: PhotographicStyle? {
        get { box.values.style }
        set { change { $0.style = newValue } }
    }
    /// Non-destructive colour or monochrome filter (version 2).
    public var filter: PhotoFilter? {
        get { box.values.filter }
        set { change { $0.filter = newValue } }
    }
    /// Portrait depth-of-field f-stop (1.4…16), when captured as or converted to Portrait.
    public var portraitAperture: Double? {
        get { box.values.portraitAperture }
        set { change { $0.portraitAperture = newValue } }
    }
    /// Portrait lighting effect (`natural` collapses to `nil`).
    public var portraitLighting: PortraitLighting? {
        get { box.values.portraitLighting }
        set { change { $0.portraitLighting = newValue } }
    }
    public var hasPortraitEdit: Bool {
        portraitAperture != nil || (portraitLighting != nil && portraitLighting != .natural)
    }
    /// Simulated depth-of-field f-stop for Cinematic videos (2.0…16), editable after capture.
    public var cinematicAperture: Double? {
        get { box.values.cinematicAperture }
        set { change { $0.cinematicAperture = newValue } }
    }
    /// User-chosen focus transition points for Cinematic videos.
    public var cinematicFocusPoints: [CinematicFocusPoint]? {
        get { box.values.cinematicFocusPoints }
        set { change { $0.cinematicFocusPoints = newValue } }
    }
    public var hasCinematicEdit: Bool {
        cinematicAperture != nil || !(cinematicFocusPoints?.isEmpty ?? true)
    }
    // Shape: quarter turns clockwise, straightening in degrees (-45…45), and the part kept
    // (0…1 of the turned and straightened picture).
    public var quarterTurns: Int {
        get { box.values.quarterTurns }
        set { change { $0.quarterTurns = newValue } }
    }
    public var straighten: Double {
        get { box.values.straighten }
        set { change { $0.straighten = newValue } }
    }
    public var crop: Crop? {
        get { box.values.crop }
        set { change { $0.crop = newValue } }
    }
    // Videos: the part kept, in milliseconds.
    public var trimStartMs: Int64? {
        get { box.values.trimStartMs }
        set { change { $0.trimStartMs = newValue } }
    }
    public var trimEndMs: Int64? {
        get { box.values.trimEndMs }
        set { change { $0.trimEndMs = newValue } }
    }

    public struct Crop: Codable, Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        /// Inside the picture and not smaller than a twentieth of it.
        public var fitted: Crop {
            let width = min(max(self.width, 0.05), 1)
            let height = min(max(self.height, 0.05), 1)
            return Crop(
                x: min(max(x, 0), 1 - width), y: min(max(y, 0), 1 - height), width: width, height: height)
        }
    }

    public init() {
        box = Box(Values())
    }

    public init(from decoder: Decoder) throws {
        box = Box(try Values(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try box.values.encode(to: encoder)
    }

    public static func == (lhs: EditRecipe, rhs: EditRecipe) -> Bool {
        lhs.box === rhs.box || lhs.box.values == rhs.box.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(box.values)
    }

    /// Nothing changed: the same as no edit.
    public var isEmpty: Bool {
        let normalized = fitted.withoutVersion
        return normalized == EditRecipe().withoutVersion
    }

    private var withoutVersion: EditRecipe {
        var copy = self
        copy.version = 0
        return copy
    }

    /// Changes the light, colour, photographic style, filter or portrait depth/lighting (not the shape).
    public var changesColour: Bool {
        [exposure, brightness, contrast, highlights, shadows, saturation, vibrance, warmth, tint].contains { $0 != 0 }
            || (style.map { !$0.isDefault } ?? false)
            || filter != nil
            || hasPortraitEdit
    }

    /// Everything within its range.
    public var fitted: EditRecipe {
        var fitted = self
        func clamp(_ value: Double, _ limit: Double = 1) -> Double { min(max(value, -limit), limit) }
        fitted.exposure = clamp(exposure, 3)
        fitted.brightness = clamp(brightness)
        fitted.contrast = clamp(contrast)
        fitted.highlights = clamp(highlights)
        fitted.shadows = clamp(shadows)
        fitted.saturation = clamp(saturation)
        fitted.vibrance = clamp(vibrance)
        fitted.warmth = clamp(warmth)
        fitted.tint = clamp(tint)
        if let style = style?.fitted, !style.isDefault {
            fitted.style = style
        } else {
            fitted.style = nil
        }
        fitted.portraitAperture = portraitAperture.map(PortraitMath.clampedAperture)
        fitted.portraitLighting = portraitLighting == .natural ? nil : portraitLighting
        fitted.cinematicAperture = cinematicAperture.map { CinematicRules.clampedAperture($0) }
        if let pts = cinematicFocusPoints, !pts.isEmpty {
            fitted.cinematicFocusPoints = pts.map(\.fitted).sorted { $0.timeMs < $1.timeMs }
        } else {
            fitted.cinematicFocusPoints = nil
        }
        fitted.quarterTurns = ((quarterTurns % 4) + 4) % 4
        fitted.straighten = clamp(straighten, 45)
        fitted.crop = crop?.fitted
        return fitted
    }
}

/// Applies an edit with Core Image: the same on every device, at any size.
public enum EditRenderer {
    /// The edited picture (using embedded depth & portrait effects matte when passed).
    public static func apply(
        _ recipe: EditRecipe, to image: CIImage, depthMap: CIImage? = nil, matte: CIImage? = nil
    ) -> CIImage {
        let recipe = recipe.fitted
        var output =
            recipe.hasPortraitEdit
            ? PortraitRenderer.apply(
                to: image, depthMap: depthMap, matte: matte,
                aperture: recipe.portraitAperture, lighting: recipe.portraitLighting)
            : image
        output = LookRenderer.apply(style: recipe.style, filter: nil, to: output)
        if recipe.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(recipe.exposure)
            output = filter.outputImage ?? output
        }
        if recipe.brightness != 0 || recipe.contrast != 0 || recipe.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = Float(recipe.brightness * 0.25)
            filter.contrast = Float(1 + recipe.contrast * 0.5)
            filter.saturation = Float(1 + recipe.saturation)
            output = filter.outputImage ?? output
        }
        if recipe.highlights != 0 || recipe.shadows != 0 {
            // Dark tones lifted or lowered by the shadows, bright ones by the highlights.
            let filter = CIFilter.toneCurve()
            filter.inputImage = output
            filter.point0 = CGPoint(x: 0, y: 0)
            filter.point1 = CGPoint(x: 0.25, y: 0.25 + recipe.shadows * 0.15)
            filter.point2 = CGPoint(x: 0.5, y: 0.5 + (recipe.shadows + recipe.highlights) * 0.03)
            filter.point3 = CGPoint(x: 0.75, y: 0.75 + recipe.highlights * 0.15)
            filter.point4 = CGPoint(x: 1, y: 1)
            output = filter.outputImage ?? output
        }
        if recipe.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(recipe.vibrance)
            output = filter.outputImage ?? output
        }
        if recipe.warmth != 0 || recipe.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 - recipe.warmth * 2500, y: -recipe.tint * 60)
            output = filter.outputImage ?? output
        }
        if let photoFilter = recipe.filter {
            output = LookRenderer.apply(style: nil, filter: photoFilter, to: output)
        }
        if recipe.quarterTurns != 0 {
            let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][recipe.quarterTurns]
            output = output.oriented(orientation)
        }
        if recipe.straighten != 0 {
            let filter = CIFilter.straighten()
            filter.inputImage = output
            filter.angle = Float(-recipe.straighten * .pi / 180)
            output = filter.outputImage?.cropped(to: output.extent) ?? output
        }
        if let crop = recipe.crop {
            let extent = output.extent
            // Core Image counts from the bottom; the crop from the top.
            let rect = CGRect(
                x: extent.minX + crop.x * extent.width,
                y: extent.minY + (1 - crop.y - crop.height) * extent.height,
                width: crop.width * extent.width, height: crop.height * extent.height
            ).integral
            output = output.cropped(to: rect)
        }
        // Start at the corner again, as a picture should.
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
    }

    /// Light and colour that make a picture look its best, as a starting point to change further:
    /// the exposure brought towards a middle brightness, a little more contrast and vibrance.
    public static func automatic(for image: CIImage, context: CIContext = CIContext()) -> EditRecipe {
        var recipe = EditRecipe()
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        var pixel = [UInt8](repeating: 0, count: 4)
        if let output = average.outputImage {
            context.render(
                output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let luminance = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
        if luminance > 0.01 {
            recipe.exposure = (min(max(log2(0.46 / luminance), -1.5), 1.5) * 10).rounded() / 10
        }
        recipe.contrast = 0.1
        recipe.vibrance = 0.2
        recipe.shadows = luminance < 0.35 ? 0.2 : 0
        recipe.highlights = luminance > 0.6 ? -0.2 : 0
        return recipe
    }

    /// The edited photo as a file: full size, JPEG or HEIC like the original, with the original's
    /// metadata (the orientation now upright).
    public static func render(
        _ original: URL, with recipe: EditRecipe, to destination: URL, context: CIContext = CIContext()
    ) throws {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
            let image = CIImage(contentsOf: original, options: [.applyOrientationProperty: true])
        else { throw CocoaError(.fileReadCorruptFile) }
        let aux: (depth: CIImage?, matte: CIImage?) =
            recipe.hasPortraitEdit ? PortraitRenderer.extractAuxiliary(from: original) : (nil, nil)
        let edited = apply(recipe, to: image, depthMap: aux.depth, matte: aux.matte)
        guard let cgImage = context.createCGImage(edited, from: edited.extent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let heic = (CGImageSourceGetType(source) as String?) == UTType.heic.identifier
        let type = (heic ? UTType.heic : UTType.jpeg).identifier as CFString
        guard let target = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImagePropertyPixelWidth as String] = cgImage.width
        properties[kCGImagePropertyPixelHeight as String] = cgImage.height
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92
        CGImageDestinationAddImage(target, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A small edited picture (thumbnail or preview): JPEG, longest side `edge`.
    public static func picture(of original: URL, with recipe: EditRecipe, edge: Int, context: CIContext = CIContext())
        -> MadeImage?
    {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else { return nil }
        // Scaled down first (fast), then edited.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge * 2,
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var edited = apply(recipe, to: CIImage(cgImage: small))
        let longest = max(edited.extent.width, edited.extent.height)
        if longest > CGFloat(edge) {
            let scale = CGFloat(edge) / longest
            edited = edited.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = context.createCGImage(edited, from: edited.extent.integral) else { return nil }
        return Thumbnails.jpeg(cgImage, quality: 0.8)
    }
}
