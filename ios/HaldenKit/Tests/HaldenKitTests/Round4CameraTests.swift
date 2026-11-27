import CoreImage
import Foundation
import Testing

@testable import HaldenKit

/// Round 4: the camera knows its iPhone, does only what a change needs, and its looks differ.
@Suite struct Round4CameraTests {
    let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: Device profile

    @Test func knowsTheIPhone15AndWhatItCannotDo() throws {
        let profile = try #require(DeviceProfile.named("iPhone15,4"))
        #expect(profile.name == "iPhone 15")
        #expect(profile.chip == "A16")
        #expect(profile.title == "iPhone 15 · A16")
        #expect(profile.backZoomPresets == [0.5, 1, 2])
        #expect(profile.has48MP)
        #expect(!profile.proRAW && !profile.proRes && !profile.appleLog)
        #expect(!profile.macro && !profile.spatialVideo && !profile.cameraControl && !profile.externalRecording)
        #expect(profile.actionMode && profile.cinematic)
        #expect(profile.featureList.contains("Action mode"))
        #expect(!profile.featureList.contains { $0.contains("ProRes") })
    }

    @Test func proModelsHaveTheirTele() throws {
        #expect(DeviceProfile.named("iPhone16,2")?.backZoomPresets == [0.5, 1, 2, 5])
        #expect(DeviceProfile.named("iPhone15,2")?.backZoomPresets == [0.5, 1, 2, 3])
        #expect(DeviceProfile.named("iPhone13,3")?.backZoomPresets == [0.5, 1, 2])
        #expect(DeviceProfile.named("iPhone17,5")?.backZoomPresets == [1, 2])
        #expect(DeviceProfile.named("iPhone99,9") == nil)
        // Identifiers are unique.
        let identifiers = DeviceProfile.known.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func profileVetoesWhatTheRuntimeOverstatesButNeverAddsAnything() throws {
        let iPhone15 = try #require(DeviceProfile.named("iPhone15,4"))
        let merged = DeviceProfile.effective(runtime: .all, profile: iPhone15)
        #expect(!merged.canProRAW && !merged.canProRes && !merged.canAppleLog)
        #expect(!merged.canExternalStorage && !merged.canSpatialVideo && !merged.canMacroControl)
        #expect(!merged.canCameraControl && !merged.canSpatialAudio && !merged.canAudioMix)
        #expect(merged.canActionMode && merged.canCinematic && merged.canDepth && merged.canBayerRAW)

        // The runtime has the last word: a profile never turns on what the camera doesn't find.
        let pro = try #require(DeviceProfile.named("iPhone16,1"))
        #expect(DeviceProfile.effective(runtime: .basic, profile: pro) == .basic)
        // Unknown models use the runtime checks as they are.
        #expect(DeviceProfile.effective(runtime: .all, profile: nil) == .all)
    }

    @Test func capabilitiesSavedByAnOlderVersionStillDecode() throws {
        let old = Data(#"{"canProRAW":true,"canProRes":false}"#.utf8)
        let decoded = try JSONDecoder().decode(DeviceCapabilities.self, from: old)
        #expect(decoded.canProRAW)
        #expect(!decoded.canActionMode && !decoded.canCinematic)
        let roundTrip = try JSONDecoder().decode(
            DeviceCapabilities.self, from: JSONEncoder().encode(DeviceCapabilities.all))
        #expect(roundTrip == .all)
    }

    // MARK: What a change touches

    @Test func aFilterOrStyleNeverRebuildsTheSession() {
        let base = AppSettings()
        var look = base
        look.photoFilter = .film
        look.filterIntensity = 0.6
        look.photographicStyle = PhotographicStyle(preset: .amber, tone: 0.2)
        look.portraitAperture = 2.8
        #expect(CameraChangeScope.between(base, look) == .look)

        var device = base
        device.lensCorrection = false
        device.scanQRCodes = false
        #expect(CameraChangeScope.between(base, device) == .device)

        var session = base
        session.photoResolution = .mp48
        #expect(CameraChangeScope.between(base, session) == .session)

        var both = look
        both.livePhotos.toggle()
        #expect(CameraChangeScope.between(base, both) == .session)

        var nothing = base
        nothing.flash = .on
        nothing.showGrid = true
        #expect(CameraChangeScope.between(base, nothing) == .none)
        #expect(CameraChangeScope.between(base, base) == .none)
    }

    // MARK: Timings

    @Test func timingLogKeepsTheLastThirtyAndTheirMedian() throws {
        let log = CameraTimingLog(defaults: nil)
        #expect(log.summary(.open) == nil)
        for value in [100.0, 300, 200] { log.record(.open, milliseconds: value) }
        let summary = try #require(log.summary(.open))
        #expect(summary.last == 200)
        #expect(summary.median == 200)
        #expect(summary.count == 3)
        log.record(.open, milliseconds: -5)
        log.record(.open, milliseconds: .nan)
        #expect(log.summary(.open)?.count == 3)
        for index in 0..<40 { log.record(.look, milliseconds: Double(index)) }
        #expect(log.summary(.look)?.count == 30)
        #expect(log.summary(.look)?.last == 39)
        #expect(CameraTimingLog.median([1, 2, 3, 4]) == 2.5)
        log.clear()
        #expect(log.summary(.look) == nil)
    }

    // MARK: Looks that can be told apart

    /// A colourful test picture: every hue from left to right, dark to light from bottom to top,
    /// with grey on the right edge.
    private func testPicture() -> CIImage {
        let width = 96
        let height = 64
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = 0.15 + 0.8 * Double(y) / Double(height - 1)
                let index = (y * width + x) * 4
                if x >= width - 16 {
                    let grey = UInt8(value * 255)
                    bytes[index] = grey
                    bytes[index + 1] = grey
                    bytes[index + 2] = grey
                    continue
                }
                let hue = Double(x) / Double(width - 16) * 6
                let chroma = value * 0.7
                let second = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
                let (r, g, b): (Double, Double, Double) =
                    switch Int(hue) {
                    case 0: (chroma, second, 0)
                    case 1: (second, chroma, 0)
                    case 2: (0, chroma, second)
                    case 3: (0, second, chroma)
                    case 4: (second, 0, chroma)
                    default: (chroma, 0, second)
                    }
                let lift = value - chroma
                bytes[index] = UInt8(min(1, r + lift) * 255)
                bytes[index + 1] = UInt8(min(1, g + lift) * 255)
                bytes[index + 2] = UInt8(min(1, b + lift) * 255)
            }
        }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Mean lightness, mean a/b, lightness spread and colourfulness (Lab-like), the numbers
    /// people see when two looks differ.
    private func signature(_ image: CIImage) -> [Double] {
        let extent = CGRect(x: 0, y: 0, width: 96, height: 64)
        var pixels = [UInt8](repeating: 0, count: 96 * 64 * 4)
        context.render(
            image.cropped(to: extent), toBitmap: &pixels, rowBytes: 96 * 4, bounds: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var sumL = 0.0
        var sumA = 0.0
        var sumB = 0.0
        var sumL2 = 0.0
        var sumChroma = 0.0
        let count = Double(96 * 64)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let l = (0.2126 * r + 0.7152 * g + 0.0722 * b) * 100
            let a = (r - g) * 100
            let bb = ((r + g) / 2 - b) * 100
            sumL += l
            sumL2 += l * l
            sumA += a
            sumB += bb
            sumChroma += (a * a + bb * bb).squareRoot()
        }
        let meanL = sumL / count
        let spread = (sumL2 / count - meanL * meanL).squareRoot()
        return [meanL, sumA / count, sumB / count, spread, sumChroma / count]
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }

    @Test func everyFilterLooksDifferentFromEveryOtherAndTheOriginal() {
        let picture = testPicture()
        var looks: [(String, [Double])] = [("Original", signature(picture))]
        for filter in PhotoFilter.allCases {
            looks.append((filter.title, signature(LookRenderer.apply(style: nil, filter: filter, to: picture))))
        }
        for i in looks.indices {
            for j in looks.indices where j > i {
                let apart = distance(looks[i].1, looks[j].1)
                #expect(apart >= 4, "\(looks[i].0) and \(looks[j].0) look alike (\(apart))")
            }
        }
    }

    @Test func everyStylePresetLooksDifferent() {
        let picture = testPicture()
        var looks: [(String, [Double])] = [("Standard", signature(picture))]
        for preset in PhotographicStylePreset.allCases where preset != .standard {
            let styled = LookRenderer.apply(style: PhotographicStyle(preset: preset), filter: nil, to: picture)
            looks.append((preset.title, signature(styled)))
        }
        for i in looks.indices {
            for j in looks.indices where j > i {
                let apart = distance(looks[i].1, looks[j].1)
                #expect(apart >= 2.5, "\(looks[i].0) and \(looks[j].0) look alike (\(apart))")
            }
        }
    }

    @Test func warmIsWarmerAndCoolIsCoolerThanTheOriginal() {
        let picture = testPicture()
        let original = signature(picture)
        let warm = signature(LookRenderer.apply(style: nil, filter: .warm, to: picture))
        let cool = signature(LookRenderer.apply(style: nil, filter: .cool, to: picture))
        // Index 2 is yellow (+) to blue (−).
        #expect(warm[2] > original[2] + 3)
        #expect(cool[2] < original[2] - 3)
        let amber = signature(LookRenderer.apply(style: PhotographicStyle(preset: .amber), filter: nil, to: picture))
        let coolRose = signature(
            LookRenderer.apply(style: PhotographicStyle(preset: .coolRose), filter: nil, to: picture))
        #expect(amber[2] > original[2])
        #expect(coolRose[2] < original[2])
    }

    @Test func filterIntensityBlendsWithTheOriginal() {
        let picture = testPicture()
        let original = signature(picture)
        let none = signature(LookRenderer.apply(style: nil, filter: .mono, filterIntensity: 0, to: picture))
        let half = signature(LookRenderer.apply(style: nil, filter: .mono, filterIntensity: 0.5, to: picture))
        let full = signature(LookRenderer.apply(style: nil, filter: .mono, filterIntensity: 1, to: picture))
        #expect(distance(none, original) < 0.5)
        // Colourfulness falls with the intensity of a mono filter.
        #expect(full[4] < half[4] && half[4] < original[4])
        #expect(PhotoFilter.clampedIntensity(1.7) == 1)
        #expect(PhotoFilter.clampedIntensity(-1) == 0)
        #expect(PhotoFilter.clampedIntensity(.infinity) == 1)
    }

    @Test func thePaletteOfStandardDoesNothingAndDefaultsToFullPresetStrength() {
        let picture = testPicture()
        let original = signature(picture)
        let standard = signature(
            LookRenderer.apply(style: PhotographicStyle(preset: .standard, palette: 0.9), filter: nil, to: picture))
        #expect(distance(standard, original) < 0.5)
        let subtle = signature(
            LookRenderer.apply(style: PhotographicStyle(preset: .vibrant, palette: 0), filter: nil, to: picture))
        let strong = signature(
            LookRenderer.apply(style: PhotographicStyle(preset: .vibrant, palette: 1), filter: nil, to: picture))
        #expect(distance(strong, subtle) > 5)
        #expect(strong[4] > subtle[4])
    }

    @Test func filterIntensityIsKeptInTheEditOnlyWhenItMatters() throws {
        var recipe = EditRecipe()
        recipe.filter = .film
        recipe.filterIntensity = 0.4
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded.filterIntensity == 0.4)
        #expect(decoded.fitted.filterIntensity == 0.4)

        var full = recipe
        full.filterIntensity = 1
        #expect(full.fitted.filterIntensity == nil)

        var noFilter = recipe
        noFilter.filter = nil
        #expect(noFilter.fitted.filterIntensity == nil)
        #expect(noFilter.isEmpty)

        // Older edits with a filter of an earlier version still decode and render.
        let old = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"version":2,"filter":"vividWarm"}"#.utf8))
        #expect(old.filter == .vividWarm)
        #expect(!PhotoFilter.allCases.contains(.vividWarm))
    }

    @Test func settingsKeepTheFilterIntensityAndAutoDepth() throws {
        var settings = AppSettings()
        #expect(settings.filterIntensity == 1)
        #expect(settings.autoDepth)
        settings.filterIntensity = 0.35
        settings.autoDepth = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.filterIntensity == 0.35)
        #expect(!decoded.autoDepth)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(older.filterIntensity == 1 && older.autoDepth)
    }
}
