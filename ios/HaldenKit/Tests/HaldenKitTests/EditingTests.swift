import CoreImage
import Foundation
import ImageIO
import Testing

@testable import HaldenKit

@Suite struct EditingTests {
    let context = CIContext()

    /// A grey picture, 400 × 300.
    func grey(_ level: Double = 0.3) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(
            to: CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    func brightness(_ image: CIImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])!
        context.render(
            average.outputImage!, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return Double(pixel[1]) / 255
    }

    @Test func anEditIsWhatWasSetAndReadsAnyVersion() throws {
        #expect(EditRecipe().isEmpty)
        var recipe = EditRecipe()
        recipe.exposure = 0.5
        recipe.crop = .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        #expect(!recipe.isEmpty && recipe.changesColour)
        let back = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(back == recipe)
        // From an older version (few fields) and a newer one (unknown fields).
        let old = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"version":1,"contrast":0.3}"#.utf8))
        #expect(old.contrast == 0.3 && old.exposure == 0)
        let newer = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"version":2,"grain":0.5,"tint":0.1}"#.utf8))
        #expect(newer.version == 2 && newer.tint == 0.1)
        var wild = EditRecipe()
        wild.exposure = 9
        wild.quarterTurns = -1
        wild.crop = .init(x: 0.9, y: -1, width: 0.5, height: 2)
        let fitted = wild.fitted
        #expect(fitted.exposure == 3 && fitted.quarterTurns == 3)
        #expect(fitted.crop == .init(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    /// A copy changed is another recipe; the first stays as it was.
    @Test func copiesStayApart() {
        var first = EditRecipe()
        first.exposure = 0.5
        var second = first
        #expect(second == first && second.hashValue == first.hashValue)
        second.exposure = 1
        second.crop = .init(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(first.exposure == 0.5 && first.crop == nil)
        #expect(second.exposure == 1 && second != first)
        #expect(MemoryLayout<EditRecipe?>.size <= 8, "a pointer in every library row")
    }

    @Test func lightAndColourChangeThePicture() {
        var brighter = EditRecipe()
        brighter.exposure = 1
        #expect(brightness(EditRenderer.apply(brighter, to: grey())) > brightness(grey()) + 0.1)
        var darker = EditRecipe()
        darker.shadows = -1
        darker.brightness = -0.5
        #expect(brightness(EditRenderer.apply(darker, to: grey())) < brightness(grey()))
        #expect(abs(brightness(EditRenderer.apply(EditRecipe(), to: grey())) - brightness(grey())) < 0.01)
        let automatic = EditRenderer.automatic(for: grey(0.1))
        #expect(automatic.exposure > 0, "a dark picture gets brighter")
    }

    @Test func turningStraighteningAndCropping() {
        var turned = EditRecipe()
        turned.quarterTurns = 1
        #expect(EditRenderer.apply(turned, to: grey()).extent.size == CGSize(width: 300, height: 400))
        var straight = EditRecipe()
        straight.straighten = 10
        #expect(EditRenderer.apply(straight, to: grey()).extent.size == CGSize(width: 400, height: 300))
        var cropped = EditRecipe()
        cropped.crop = .init(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let output = EditRenderer.apply(cropped, to: grey())
        #expect(output.extent == CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    /// Written as a file: upright, the size after cropping, the original's metadata kept.
    @Test func theEditedPhotoIsAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("o.jpg")
        try #require(SampleMedia.photo(seed: 3, width: 400, height: 300)).write(to: original)
        var recipe = EditRecipe()
        recipe.crop = .init(x: 0, y: 0, width: 0.5, height: 1)
        recipe.warmth = 0.4
        let edited = folder.appendingPathComponent("e.jpg")
        try EditRenderer.render(original, with: recipe, to: edited)
        let source = try #require(CGImageSourceCreateWithURL(edited as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 200)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 300)
        let small = try #require(EditRenderer.picture(of: original, with: recipe, edge: 100))
        #expect(max(small.width, small.height) == 100 && small.width < small.height)
    }

    /// The grid shows the edited picture: turned and cropped, at the size asked for.
    @Test func thumbnailsShowTheEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let thumbnail = folder.appendingPathComponent("t.jpg")
        try #require(SampleMedia.photo(seed: 5, width: 512, height: 384)).write(to: thumbnail)
        var recipe = EditRecipe()
        recipe.quarterTurns = 1
        let turned = try #require(ImagePipeline.decode(thumbnail, pixels: 300, edit: recipe))
        #expect(turned.cgImage.height == 300 && turned.cgImage.width == 225)
        let plain = try #require(ImagePipeline.decode(thumbnail, pixels: 300, edit: EditRecipe()))
        #expect(plain.cgImage.width == 300)
    }
}
