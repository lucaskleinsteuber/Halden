import CoreImage
import Foundation
import Testing

@testable import HaldenKit

@Suite struct PortraitTests {
    let context = CIContext()

    private func testPhoto() throws -> CIImage {
        let jpeg = try #require(SampleMedia.photo(seed: 42, width: 320, height: 240))
        return try #require(CIImage(data: jpeg))
    }

    private func averageLuma(_ image: CIImage, in rect: CGRect) -> Double {
        let cropped = image.cropped(to: rect)
        var pixel = [UInt8](repeating: 0, count: 4)
        let avg = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: cropped, kCIInputExtentKey: CIVector(cgRect: cropped.extent)])!
        context.render(
            avg.outputImage!, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    @Test func apertureClampingFormattingBlurAndHints() {
        #expect(PortraitMath.clampedAperture(0.5) == 1.4)
        #expect(PortraitMath.clampedAperture(22.0) == 16.0)
        #expect(PortraitMath.formatAperture(1.4) == "f/1.4")
        #expect(PortraitMath.formatAperture(4.5) == "f/4.5")
        #expect(PortraitMath.formatAperture(16.0) == "f/16")

        // Wider aperture (f/1.4) produces noticeably stronger blur than narrow aperture (f/16).
        #expect(PortraitMath.blurRadius(forAperture: 1.4) > PortraitMath.blurRadius(forAperture: 8.0))
        #expect(PortraitMath.blurRadius(forAperture: 16.0) == 0)

        // Guidance hints match distance and low-light thresholds.
        #expect(PortraitMath.hint(distanceMeters: 0.25, iso: 100) == .moveFartherAway)
        #expect(PortraitMath.hint(distanceMeters: 3.2, iso: 100) == .placeSubjectCloser)
        #expect(PortraitMath.hint(distanceMeters: 1.2, iso: 3200) == .moreLightRequired)
        #expect(PortraitMath.hint(distanceMeters: 1.2, iso: 200) == nil)
    }

    @Test func portraitLightingStageDarkensAndHighKeyBrightensBackground() throws {
        let photo = try testPhoto()
        let corner = CGRect(x: 0, y: 0, width: 40, height: 40)
        let baseCorner = averageLuma(photo, in: corner)

        let stage = PortraitRenderer.apply(to: photo, aperture: 2.8, lighting: .stage)
        let highKey = PortraitRenderer.apply(to: photo, aperture: 2.8, lighting: .highKeyMono)

        #expect(averageLuma(stage, in: corner) < baseCorner * 0.35, "Stage lighting turns background near black")
        #expect(
            averageLuma(highKey, in: corner) > max(baseCorner + 0.15, 0.75), "High-Key Mono turns background bright")
    }

    @Test func portraitRecipeRoundTripsAndPreservesSettings() throws {
        var recipe = EditRecipe()
        recipe.portraitAperture = 2.0
        recipe.portraitLighting = .contour
        let fitted = recipe.fitted
        #expect(fitted.portraitAperture == 2.0 && fitted.portraitLighting == .contour)
        #expect(!fitted.isEmpty && fitted.changesColour)

        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(fitted))
        #expect(decoded == fitted)

        var naturalOnly = EditRecipe()
        naturalOnly.portraitLighting = .natural
        #expect(naturalOnly.isEmpty, "natural lighting alone equals no edit")
    }
}
