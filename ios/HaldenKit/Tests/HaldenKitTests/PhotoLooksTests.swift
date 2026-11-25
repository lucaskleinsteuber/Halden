import CoreImage
import Foundation
import Testing

@testable import HaldenKit

@Suite struct PhotoLooksTests {
    let context = CIContext()

    private func sampleImage() -> CIImage {
        // Warm-neutral skin/sky test patch (400 × 300).
        CIImage(color: CIColor(red: 0.55, green: 0.45, blue: 0.40)).cropped(
            to: CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    private func averageRGB(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])!
        context.render(
            average.outputImage!, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    @Test func customPreviewOnlyActivatesWhenLookPortraitOrScopesNeedIt() {
        #expect(!LookRenderer.needsCustomPreview(style: nil, filter: nil))
        #expect(!LookRenderer.needsCustomPreview(style: PhotographicStyle(preset: .standard), filter: nil))
        #expect(LookRenderer.needsCustomPreview(style: PhotographicStyle(preset: .amber), filter: nil))
        #expect(
            LookRenderer.needsCustomPreview(style: PhotographicStyle(preset: .standard, tone: 0.3), filter: nil))
        #expect(LookRenderer.needsCustomPreview(style: nil, filter: .vivid))
        #expect(LookRenderer.needsCustomPreview(style: nil, filter: nil, isPortrait: true))
        #expect(LookRenderer.needsCustomPreview(style: nil, filter: nil, showScopes: true))
    }

    @Test func stylesAndFiltersChangePixelsPredictably() {
        let base = sampleImage()
        let baseRGB = averageRGB(base)

        // Monochrome style & Noir filter produce greyscale output (R ≈ G ≈ B).
        let stark = averageRGB(LookRenderer.apply(style: PhotographicStyle(preset: .starkBW), filter: nil, to: base))
        #expect(abs(stark.r - stark.g) < 0.02 && abs(stark.g - stark.b) < 0.02)

        let noir = averageRGB(LookRenderer.apply(style: nil, filter: .noir, to: base))
        #expect(abs(noir.r - noir.g) < 0.02 && abs(noir.g - noir.b) < 0.02)

        // Amber / Vivid Warm shifts red/blue balance warmer; Cool Rose / Vivid Cool shifts cooler.
        let amber = averageRGB(LookRenderer.apply(style: PhotographicStyle(preset: .amber), filter: nil, to: base))
        let cool = averageRGB(LookRenderer.apply(style: PhotographicStyle(preset: .coolRose), filter: nil, to: base))
        #expect((amber.r - amber.b) > (baseRGB.r - baseRGB.b))
        #expect((cool.b - cool.r) > (baseRGB.b - baseRGB.r))

        let vividWarm = averageRGB(LookRenderer.apply(style: nil, filter: .vividWarm, to: base))
        let vividCool = averageRGB(LookRenderer.apply(style: nil, filter: .vividCool, to: base))
        #expect((vividWarm.r - vividWarm.b) > (vividCool.r - vividCool.b))

        // Positive tone lifts brightness relative to negative tone.
        let brightTone = averageRGB(
            LookRenderer.apply(style: PhotographicStyle(preset: .standard, tone: 0.8), filter: nil, to: base))
        let darkTone = averageRGB(
            LookRenderer.apply(style: PhotographicStyle(preset: .standard, tone: -0.8), filter: nil, to: base))
        #expect(brightTone.g > darkTone.g + 0.05)
    }

    @Test func recipeVersion2RoundTripsAndRespectsPreserveStyle() throws {
        var recipe = EditRecipe()
        #expect(recipe.version == 2)
        recipe.style = PhotographicStyle(preset: .cozy, tone: 1.8, color: -2.0, palette: 1.5)
        recipe.filter = .dramaticWarm
        let fitted = recipe.fitted
        #expect(fitted.style?.tone == 1.0 && fitted.style?.color == -1.0 && fitted.style?.palette == 1.0)
        #expect(!fitted.isEmpty && fitted.changesColour)

        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(fitted))
        #expect(decoded == fitted)

        // Default Standard (0, 0) collapses back to empty recipe.
        var defaultOnly = EditRecipe()
        defaultOnly.style = PhotographicStyle(preset: .standard, tone: 0, color: 0, palette: 0.5)
        #expect(defaultOnly.isEmpty)

        // Preserve Settings resets style & filter unless preserveStyle is true.
        var settings = AppSettings()
        settings.photographicStyle = PhotographicStyle(preset: .gold)
        settings.photoFilter = .vivid
        settings.preserveStyle = false
        let reset = CameraControls.resetUnpreserved(in: settings)
        #expect(reset.photographicStyle == nil && reset.photoFilter == nil)

        settings.preserveStyle = true
        let kept = CameraControls.resetUnpreserved(in: settings)
        #expect(kept.photographicStyle?.preset == .gold && kept.photoFilter == .vivid)
    }

    @Test func recipeV2StyleAndFilterSyncThroughRealServer() async throws {
        guard RealServer.available else { return }
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "styles", platform: "ios", installationId: "install-e2e-styles"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        let stored = StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil)
        try database.save(server: stored)

        let assetId = UUID().uuidString.lowercased()
        let jpeg = try #require(SampleMedia.photo(seed: 21))
        try jpeg.write(to: files.original("\(assetId).jpg"))
        try Uploader.enqueue(
            database: database, files: files, assetId: assetId, fileName: "\(assetId).jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1_795_443_730_000))
        await Uploader(database: database, files: files, client: client).drain()

        var recipe = EditRecipe()
        recipe.style = PhotographicStyle(preset: .luminous, tone: 0.2, color: 0.3, palette: 0.65)
        recipe.filter = .vividWarm
        let actions = Actions(database: database)
        try actions.correct(assetId, AssetCorrection(edit: .set(recipe)))
        _ = await actions.send(with: client)

        let other = try HaldenDatabase()
        try other.save(server: stored)
        _ = try await Syncer(database: other, client: client).run()
        let synced = try #require(try other.asset(assetId))
        #expect(synced.edit?.version == 2)
        #expect(synced.edit?.style?.preset == .luminous)
        #expect(synced.edit?.filter == .vividWarm)
    }

    @Test func lookRendererThroughputAt1080p() throws {
        // Real textured bitmap (not constant color, so Core Image cannot constant-fold).
        let jpeg = try #require(SampleMedia.photo(seed: 99, width: 1920, height: 1080))
        let frame = try #require(CIImage(data: jpeg))
        let style = PhotographicStyle(preset: .amber, tone: 0.25, color: 0.35, palette: 0.7)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
        // Warm-up pass
        let warm = LookRenderer.apply(style: style, filter: .vividWarm, to: frame)
        context.render(
            warm, toBitmap: &buffer, rowBytes: 1920 * 4, bounds: frame.extent, format: .RGBA8, colorSpace: colorSpace)

        let frames = 20
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<frames {
            let rendered = LookRenderer.apply(style: style, filter: .vividWarm, to: frame)
            context.render(
                rendered, toBitmap: &buffer, rowBytes: 1920 * 4, bounds: frame.extent, format: .RGBA8,
                colorSpace: colorSpace)
        }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let msPerFrame = elapsedMs / Double(frames)
        print(String(format: "BENCH_C6_1080P: %.2f ms/frame (%.1f fps)", msPerFrame, 1000 / max(msPerFrame, 0.01)))
        #expect(msPerFrame < 100, "1080p style+filter render stayed well within real-time budget")
    }
}
