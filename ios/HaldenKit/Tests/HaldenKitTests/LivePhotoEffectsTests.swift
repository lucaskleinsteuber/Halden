import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import HaldenKit
import ImageIO
import Testing

@Suite("Live Photo Effects")
struct LivePhotoEffectsTests {
    @Test("Bounce indices ping-pong cleanly without duplicating endpoints")
    func bounceIndices() {
        #expect(LivePhotoEffectMath.bounceIndices(frameCount: 0) == [])
        #expect(LivePhotoEffectMath.bounceIndices(frameCount: 1) == [0])
        #expect(LivePhotoEffectMath.bounceIndices(frameCount: 2) == [0, 1])
        #expect(LivePhotoEffectMath.bounceIndices(frameCount: 5) == [0, 1, 2, 3, 4, 3, 2, 1])
    }

    @Test("Key-frame clamping and crossfade counts stay in bounds")
    func clampingAndCrossfade() {
        #expect(LivePhotoEffectMath.clampKeyFrameMs(-50, durationMs: 2000) == 0)
        #expect(LivePhotoEffectMath.clampKeyFrameMs(2500, durationMs: 2000) == 2000)
        #expect(LivePhotoEffectMath.clampKeyFrameMs(750, durationMs: 2000) == 750)
        #expect(LivePhotoEffectMath.clampKeyFrameMs(999_999) == 600_000)
        #expect(LivePhotoEffectMath.loopCrossfadeCount(frameCount: 4) == 0)
        #expect(LivePhotoEffectMath.loopCrossfadeCount(frameCount: 24) == 4)
    }

    @Test("EditRecipe encodes and normalizes liveEffect and liveKeyFrameMs")
    func editRecipeLiveEffect() throws {
        var recipe = EditRecipe()
        recipe.liveEffect = .live
        #expect(recipe.fitted.liveEffect == nil)
        #expect(recipe.isEmpty)

        recipe.liveEffect = .bounce
        recipe.liveKeyFrameMs = 420
        #expect(!recipe.isEmpty)

        let data = try JSONEncoder().encode(recipe.fitted)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded.liveEffect == .bounce)
        #expect(decoded.liveKeyFrameMs == 420)
    }

    @Test("Renderer produces valid Loop MP4, Bounce MP4, Long Exposure HEIC, and Key Photo")
    func renderAllLiveEffects() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halden-live-fx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("paired.mov")
        try await SampleMedia.video(at: source, seed: 42, seconds: 1.0)
        let duration = await LivePhotoEffectRenderer.durationMs(of: source)
        #expect(duration >= 800)

        let loopOut = try await LivePhotoEffectRenderer.renderLoop(
            video: source, to: dir.appendingPathComponent("loop.mp4"))
        #expect(loopOut.mimeType == "video/mp4")
        #expect(loopOut.data.count > 1000)
        #expect(loopOut.width > 0 && loopOut.height > 0)

        let bounceOut = try await LivePhotoEffectRenderer.renderBounce(
            video: source, to: dir.appendingPathComponent("bounce.mp4"))
        #expect(bounceOut.mimeType == "video/mp4")
        let bounceDuration = await LivePhotoEffectRenderer.durationMs(of: bounceOut.url)
        #expect(bounceDuration > duration, "Bounce video should be longer than the forward clip")

        let longOut = try await LivePhotoEffectRenderer.renderLongExposure(
            video: source, to: dir.appendingPathComponent("long.heic"))
        #expect(longOut.mimeType == "image/heic" || longOut.mimeType == "image/jpeg")
        #expect(longOut.data.count > 500)
        let srcRef = CGImageSourceCreateWithData(longOut.data as CFData, nil)
        let longImg = srcRef.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(longImg != nil)

        let keyOut = try await LivePhotoEffectRenderer.extractKeyFrame(
            video: source, atMs: duration / 2, to: dir.appendingPathComponent("key.heic"))
        #expect(keyOut.width > 0 && keyOut.height > 0)
        #expect(keyOut.data.count > 500)

        let thumbs = await LivePhotoEffectRenderer.scrubberFrames(of: source, count: 4)
        #expect(thumbs.count == 4)
    }

    @Test("Live Photo effect uploads as live_effect derived role, syncs, and deletes cleanly against real server")
    func serverLiveEffectRoundtrip() async throws {
        guard RealServer.available else { return }
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "livefx", platform: "ios", installationId: "install-e2e-livefx"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)

        let dir = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: dir, caches: dir.appendingPathComponent("caches"))

        let db = try HaldenDatabase()
        try db.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))

        // Upload original photo + paired Live Photo video.
        let assetId = UUID().uuidString.lowercased()
        let photoBytes = try #require(SampleMedia.photo(seed: 7))
        let photoName = "\(assetId).jpg"
        try photoBytes.write(to: files.original(photoName))
        let videoName = "\(assetId)-live.mov"
        try await SampleMedia.video(at: files.original(videoName), seed: 7, seconds: 1.0)
        try Uploader.enqueue(
            database: db, files: files, assetId: assetId, fileName: photoName,
            kind: "photo", mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1_795_443_730_000))
        try Uploader.enqueuePairedVideo(
            database: db, files: files, assetId: assetId, fileName: videoName, mimeType: "video/quicktime")

        let uploader = Uploader(database: db, files: files, client: client)
        _ = await uploader.drain()

        // Render Bounce effect and upload under `live_effect`.
        let rendered = try await LivePhotoEffectRenderer.renderBounce(
            video: files.original(videoName), to: dir.appendingPathComponent("bounce.mp4"))
        let updated = try await client.put(
            file: rendered.data, role: "live_effect", asset: assetId,
            mimeType: rendered.mimeType, sha256: rendered.sha256,
            width: rendered.width, height: rendered.height)
        #expect(updated.file("live_effect")?.sha256 == rendered.sha256)

        var recipe = EditRecipe()
        recipe.liveEffect = .bounce
        recipe.liveKeyFrameMs = 300
        let actions = Actions(database: db)
        try actions.correct(assetId, AssetCorrection(edit: .set(recipe)))
        _ = await actions.send(with: client)
        _ = try await Syncer(database: db, client: client).run()

        let local = try #require(try db.asset(assetId))
        #expect(local.activeLiveEffect == .bounce)
        #expect(local.edit?.liveKeyFrameMs == 300)
        #expect(local.liveEffectSha256 == rendered.sha256)
        #expect(local.liveEffectMime == "video/mp4")

        // Download through MediaFiles and verify bytes match.
        let media = MediaFiles(files: files, client: client)
        let downloaded = try #require(try await media.liveEffect(of: local))
        #expect(try Data(contentsOf: downloaded) == rendered.data)

        // Delete derived effect and verify sync clears it.
        _ = try await client.deleteDerived(role: "live_effect", asset: assetId)
        _ = try await Syncer(database: db, client: client).run()
        let reverted = try #require(try db.asset(assetId))
        #expect(reverted.liveEffectSha256 == nil)
    }
}
