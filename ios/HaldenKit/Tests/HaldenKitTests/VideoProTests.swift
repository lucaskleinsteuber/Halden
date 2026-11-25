import CoreImage
import Foundation
import Testing

@testable import HaldenKit

@Suite struct VideoProTests {
    @Test func actionModeCinematicRulesAndPreserveSettings() throws {
        #expect(!ActionModeRules.needsMoreLight(actionMode: false, iso: 3200))
        #expect(!ActionModeRules.needsMoreLight(actionMode: true, iso: 800))
        #expect(ActionModeRules.needsMoreLight(actionMode: true, iso: 2000))

        #expect(CinematicRules.clampedAperture(0.5) == 2.0)
        #expect(CinematicRules.clampedAperture(22.0) == 16.0)
        #expect(CinematicRules.formatAperture(2.8) == "f/2.8")
        #expect(CinematicRules.formatAperture(16.0) == "f/16")

        // Preserve Action Mode toggle resets Action Mode unless preserved.
        var settings = AppSettings()
        settings.actionMode = true
        settings.preserveActionMode = false
        #expect(CameraControls.resetUnpreserved(in: settings).actionMode == false)
        settings.preserveActionMode = true
        #expect(CameraControls.resetUnpreserved(in: settings).actionMode == true)

        // Cinematic edit recipe round-trips cleanly.
        var recipe = EditRecipe()
        recipe.cinematicAperture = 2.2
        recipe.cinematicFocusPoints = [CinematicFocusPoint(timeMs: 1200, x: 0.4, y: 0.6)]
        #expect(!recipe.isEmpty)
        #expect(recipe.hasCinematicEdit)
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded.cinematicAperture == 2.2)
        #expect(decoded.cinematicFocusPoints?.first?.timeMs == 1200)
    }

    @Test func liveScopesDistinguishDarkBrightAndHorizontalGradients() {
        // Dark red image: low luma, red channel above blue channel.
        let redImg = CIImage(color: CIColor(red: 0.85, green: 0.1, blue: 0.1)).cropped(
            to: CGRect(x: 0, y: 0, width: 128, height: 72))
        let redScopes = LiveScopesAnalyzer.analyze(redImg)
        let peakRedBin = redScopes.red.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let peakBlueBin = redScopes.blue.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        #expect(peakRedBin > peakBlueBin + 12)
        #expect(redScopes.clippedHighlights < 0.05)

        // Pure white image reports clipped highlights.
        let whiteImg = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
        let whiteScopes = LiveScopesAnalyzer.analyze(whiteImg)
        #expect(whiteScopes.clippedHighlights > 0.95)
        #expect(whiteScopes.waveformMean.first ?? 0 > 0.95)

        // Horizontal black-to-white ramp rises left-to-right across waveform columns.
        let w = 64
        let h = 16
        var ramp = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt8((x * 255) / (w - 1))
                let idx = (y * w + x) * 4
                ramp[idx] = v
                ramp[idx + 1] = v
                ramp[idx + 2] = v
            }
        }
        let rampScopes = LiveScopesAnalyzer.analyzeRGBA(bytes: ramp, width: w, height: h)
        #expect((rampScopes.waveformMean.first ?? 1) < 0.1)
        #expect((rampScopes.waveformMean.last ?? 0) > 0.9)
    }

    @Test func cinematicVideoCaptureModeSyncsThroughRealServer() async throws {
        guard RealServer.available else { return }
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "cinematic", platform: "ios", installationId: "install-e2e-cinematic"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        let stored = StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil)
        try database.save(server: stored)

        let id = UUID().uuidString.lowercased()
        let videoURL = files.original("\(id).mov")
        try await SampleMedia.video(at: videoURL, seed: 77, seconds: 1)
        var meta = UploadMetadata(takenAt: 1_795_443_730_000, width: 640, height: 360, durationMs: 1000)
        meta.captureMode = "cinematic"
        try Uploader.enqueue(
            database: database, files: files, assetId: id, fileName: "\(id).mov", kind: "video",
            mimeType: "video/quicktime", metadata: meta)

        await Uploader(database: database, files: files, client: client).drain()
        let other = try HaldenDatabase()
        try other.save(server: stored)
        _ = try await Syncer(database: other, client: client).run()
        let local = try #require(try other.asset(id))
        #expect(local.isCinematic)
        #expect(local.captureMode == "cinematic")
    }
}
