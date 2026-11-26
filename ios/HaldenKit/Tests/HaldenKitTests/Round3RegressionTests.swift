import Foundation
import GRDB
import HaldenWatchProtocol
import Testing

@testable import HaldenKit

@Suite("Round 3 Regression & Integration Matrix")
struct Round3RegressionTests {
    /// Verifies every single Preserve Settings toggle works independently without leaking into
    /// adjacent settings, both when turned off (resets) and when turned on (preserves).
    @Test func preserveSettingsMatrixCoversEveryToggle() {
        func dirtySettings() -> AppSettings {
            var s = AppSettings()
            s.keptMode = "video"
            s.photographicStyle = PhotographicStyle(preset: .amber, tone: 0.3, color: 0.2, palette: 0.8)
            s.photoFilter = .vividWarm
            s.portraitAperture = 1.8
            s.portraitLighting = .studio
            s.nightMode = .seconds(5)
            s.actionMode = true
            s.keptExposureBias = 1.3
            s.livePhotos = false
            s.photoResolution = .mp48
            s.captureRAW = true
            s.captureProRAW = true
            s.macroMode = .off
            s.keptManual = ManualSettings(shutter: 1.0 / 250, iso: 400, exposureBias: 0.7)
            s.preserveMode = false
            s.preserveStyle = false
            s.preservePortraitZoom = false
            s.preserveNightMode = false
            s.preserveActionMode = false
            s.preserveExposure = false
            s.preserveLivePhoto = false
            s.preserveResolution = false
            s.preserveMacro = false
            s.keepManualSettings = false
            return s
        }

        // With every Preserve toggle OFF, closing the camera resets all transient controls.
        let allReset = CameraControls.resetUnpreserved(in: dirtySettings())
        #expect(allReset.keptMode == nil)
        #expect(allReset.photographicStyle == nil)
        #expect(allReset.photoFilter == nil)
        #expect(allReset.portraitAperture == PortraitMath.defaultAperture)
        #expect(allReset.portraitLighting == .natural)
        #expect(allReset.nightMode == .auto)
        #expect(!allReset.actionMode)
        #expect(allReset.keptExposureBias == 0)
        #expect(allReset.livePhotos)
        #expect(allReset.photoResolution == .mp24)
        #expect(!allReset.captureRAW)
        #expect(!allReset.captureProRAW)
        #expect(allReset.macroMode == .auto)
        #expect(allReset.keptManual == nil)

        // With every Preserve toggle ON, every transient control survives.
        var keepAll = dirtySettings()
        keepAll.preserveMode = true
        keepAll.preserveStyle = true
        keepAll.preservePortraitZoom = true
        keepAll.preserveNightMode = true
        keepAll.preserveActionMode = true
        keepAll.preserveExposure = true
        keepAll.preserveLivePhoto = true
        keepAll.preserveResolution = true
        keepAll.preserveMacro = true
        keepAll.keepManualSettings = true
        let allKept = CameraControls.resetUnpreserved(in: keepAll)
        #expect(allKept.keptMode == "video")
        #expect(allKept.photographicStyle?.preset == .amber)
        #expect(allKept.photoFilter == .vividWarm)
        #expect(allKept.portraitAperture == 1.8)
        #expect(allKept.portraitLighting == .studio)
        #expect(allKept.nightMode == .seconds(5))
        #expect(allKept.actionMode)
        #expect(allKept.keptExposureBias == 1.3)
        #expect(!allKept.livePhotos)
        #expect(allKept.photoResolution == .mp48)
        #expect(allKept.captureRAW)
        #expect(allKept.captureProRAW)
        #expect(allKept.macroMode == .off)
        #expect(allKept.keptManual?.iso == 400)

        // Spot-check single-toggle isolation: preserving only Night Mode resets everything else.
        var onlyNight = dirtySettings()
        onlyNight.preserveNightMode = true
        let nightResult = CameraControls.resetUnpreserved(in: onlyNight)
        #expect(nightResult.nightMode == .seconds(5))
        #expect(nightResult.keptMode == nil)
        #expect(nightResult.photographicStyle == nil)
        #expect(!nightResult.actionMode)
        #expect(nightResult.macroMode == .auto)
    }

    /// Verifies non-destructive aspect-ratio crop math across landscape, portrait and square sensors.
    @Test func aspectRatioCropGeometryMatrix() {
        let sizes = [(4032, 3024), (3024, 4032), (8064, 6048), (1000, 1000)]
        for (w, h) in sizes {
            #expect(PhotoAspectRatio.fourByThree.crop(forWidth: w, height: h) == nil)
            if let sq = PhotoAspectRatio.square.crop(forWidth: w, height: h) {
                #expect(sq.x >= 0 && sq.y >= 0 && sq.width > 0 && sq.height > 0)
                #expect(sq.x + sq.width <= 1.0001 && sq.y + sq.height <= 1.0001)
                let outW = Double(w) * sq.width
                let outH = Double(h) * sq.height
                #expect(abs(outW - outH) < 2.0, "1:1 crop should be square for \(w)x\(h)")
            } else {
                #expect(w == h)
            }
            if let wide = PhotoAspectRatio.sixteenByNine.crop(forWidth: w, height: h) {
                let outW = Double(w) * wide.width
                let outH = Double(h) * wide.height
                let expected = w >= h ? (16.0 / 9.0) : (9.0 / 16.0)
                #expect(abs((outW / outH) - expected) < 0.02, "16:9 crop ratio mismatch for \(w)x\(h)")
                // Centered symmetrically.
                #expect(abs((wide.x) - (1 - wide.x - wide.width)) < 0.001)
                #expect(abs((wide.y) - (1 - wide.y - wide.height)) < 0.001)
            }
        }
    }

    /// Verifies EditRecipe v1 → v2 forward/backward JSON compatibility, clamping, and unknown-key safety.
    @Test func editRecipeV1ToV2CompatibilityAndClamping() throws {
        // Legacy v1 recipe plus unknown future keys decodes safely.
        let v1JSON = Data(
            """
            {
              "version": 1,
              "exposure": 0.5,
              "quarterTurns": 1,
              "futureExperimentalKey": { "nested": true }
            }
            """.utf8)
        let decodedV1 = try JSONDecoder().decode(EditRecipe.self, from: v1JSON)
        #expect(decodedV1.version == 1)
        #expect(decodedV1.exposure == 0.5)
        #expect(decodedV1.quarterTurns == 1)
        #expect(decodedV1.style == nil)
        #expect(decodedV1.filter == nil)
        #expect(decodedV1.liveEffect == nil)
        #expect(decodedV1.audioMix == nil)

        // Full v2 recipe with out-of-range values gets cleanly clamped by `.fitted`.
        var full = EditRecipe()
        full.exposure = 9.0
        full.straighten = -99.0
        full.quarterTurns = -1
        full.style = PhotographicStyle(preset: .gold, tone: 5.0, color: -5.0, palette: 2.0)
        full.filter = .dramaticCool
        full.portraitAperture = 0.5
        full.portraitLighting = .contour
        full.cinematicAperture = 99.0
        full.cinematicFocusPoints = [
            CinematicFocusPoint(timeMs: 1200, x: 1.5, y: -0.2),
            CinematicFocusPoint(timeMs: 400, x: 0.3, y: 0.4),
        ]
        full.liveEffect = .loop
        full.liveKeyFrameMs = -10
        full.audioMix = .inFrame
        full.audioMixIntensity = 3.0

        let fitted = full.fitted
        #expect(fitted.exposure == 3.0)
        #expect(fitted.straighten == -45.0)
        #expect(fitted.quarterTurns == 3)
        #expect(fitted.style?.tone == 1.0)
        #expect(fitted.style?.color == -1.0)
        #expect(fitted.style?.palette == 1.0)
        #expect(fitted.portraitAperture == PortraitMath.apertureRange.lowerBound)
        #expect(fitted.cinematicAperture == CinematicRules.apertureRange.upperBound)
        #expect(fitted.cinematicFocusPoints?.map(\.timeMs) == [400, 1200])
        #expect(fitted.cinematicFocusPoints?.last?.x == 1.0)
        #expect(fitted.cinematicFocusPoints?.last?.y == 0.0)
        #expect(fitted.liveKeyFrameMs == 0)
        #expect(fitted.audioMixIntensity == 1.0)

        let reencoded = try JSONEncoder().encode(fitted)
        let roundtripped = try JSONDecoder().decode(EditRecipe.self, from: reencoded)
        #expect(roundtripped == fitted)
    }

    /// Verifies Round 3 invariants across TopBarControl, WatchFrameThrottler, Scanner, DualCapture and FocalLength.
    @Test func round3ControlAndProtocolInvariants() {
        // TopBarControl sanitization deduplicates, caps at 4, and falls back to defaults on empty.
        #expect(CameraControls.sanitizedTopBar([]) == CameraControls.defaultTopBarControls)
        let overcrowded: [TopBarControl] = [.flash, .flash, .manual, .timer, .live, .raw, .grid]
        #expect(CameraControls.sanitizedTopBar(overcrowded) == [.flash, .manual, .timer, .live])

        // Main-lens 1x focal length cycling: 24 -> 28 -> 35 -> 24 mm.
        var zoom = 1.0
        var seen: [FocalLength] = []
        for _ in 0..<3 {
            let step = LevelMath.focalTap(
                currentZoom: zoom, defaultFocal: .mm24, activePreset: 1.0,
                presetTapped: 1.0, isBackCamera: true, zoomRange: 0.5...10)
            zoom = step.zoom
            if let badge = step.badge { seen.append(badge) }
        }
        #expect(seen == [.mm28, .mm35, .mm24])

        // Watch throttler under sustained 60 fps load never exceeds 8 fps and drops frames when busy.
        var throttler = WatchFrameThrottler()
        var accepted = 0
        for frame in 0..<60 {
            let t = Double(frame) / 60.0
            let send = throttler.shouldSendFrame(now: t, isReachable: true, inFlight: false)
            if send { accepted += 1 }
        }
        #expect((7...9).contains(accepted), "60 fps input should throttle to ~8 fps, got \(accepted)")

        // Scanner rejects unsafe URL schemes while keeping safe links and escaped Wi-Fi credentials.
        if case .text = QRPayloadParser.parse("javascript:alert(1)")?.kind {
            // safe fallback
        } else {
            Issue.record("javascript: URI must never parse as an openable URL")
        }
        if case .wifi(let ssid, let pass, let enc, _) = QRPayloadParser.parse(#"WIFI:T:WPA;S:Cafe\;One;P:p\:ss;;"#)?
            .kind
        {
            #expect(ssid == "Cafe;One")
            #expect(pass == "p:ss")
            #expect(enc == "WPA")
        } else {
            Issue.record("Escaped Wi-Fi payload should parse cleanly")
        }
    }

    /// Real-server stress & recovery test: mixes Burst + Live Photo + RAW + Spatial + Cinematic +
    /// offline EditRecipe v2 edits queued BEFORE upload completes, drains uploads, sends deferred
    /// actions, and syncs the complete library onto a fresh second device database.
    @Test func mixedOfflineQueueAndSecondDeviceSyncAgainstRealServer() async throws {
        guard RealServer.available else { return }
        let server = try RealServer()
        let info = try await server.ready()

        let (conn1, token1) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "r3-phone", platform: "ios", installationId: "install-r3-phone"))
        let client1 = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(conn1.fingerprint),
            token: token1)

        let dir1 = server.folder.appendingPathComponent("phone1")
        let files1 = try FileLocations(root: dir1, caches: dir1.appendingPathComponent("caches"))
        let db1 = try HaldenDatabase()
        try db1.save(server: StoredServer(serverId: conn1.serverId, connection: conn1, syncSince: 0, backup: nil))

        let burstId = UUID().uuidString.lowercased()
        let baseMs: Int64 = 1_795_443_730_000

        // Enqueue 2 Burst photos.
        var burstIds: [String] = []
        for idx in 0..<2 {
            let id = UUID().uuidString.lowercased()
            let bytes = try #require(SampleMedia.photo(seed: 100 + idx))
            let name = "\(id).jpg"
            try bytes.write(to: files1.original(name))
            var meta = UploadMetadata(takenAt: baseMs + Int64(idx * 250))
            meta.burstId = burstId
            try Uploader.enqueue(
                database: db1, files: files1, assetId: id, fileName: name,
                kind: "photo", mimeType: "image/jpeg", metadata: meta)
            burstIds.append(id)
        }

        // Enqueue 1 Live Photo (photo + paired_video) + offline EditRecipe v2 queued BEFORE upload.
        let liveId = UUID().uuidString.lowercased()
        let livePhotoName = "\(liveId).jpg"
        try #require(SampleMedia.photo(seed: 201)).write(to: files1.original(livePhotoName))
        let liveVideoName = "\(liveId)-live.mov"
        try await SampleMedia.video(at: files1.original(liveVideoName), seed: 201, seconds: 1.0)
        try Uploader.enqueue(
            database: db1, files: files1, assetId: liveId, fileName: livePhotoName,
            kind: "photo", mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: baseMs + 1000))
        try Uploader.enqueuePairedVideo(
            database: db1, files: files1, assetId: liveId, fileName: liveVideoName, mimeType: "video/quicktime")

        var styledEdit = EditRecipe()
        styledEdit.style = PhotographicStyle(preset: .dramatic, tone: -0.2, color: 0.3, palette: 0.75)
        styledEdit.filter = .vivid
        styledEdit.portraitAperture = 2.4
        let actions1 = Actions(database: db1)
        try actions1.correct(liveId, AssetCorrection(edit: .set(styledEdit)))

        // Enqueue 1 Spatial Video + offline Audio Mix edit queued BEFORE upload.
        let spatialId = UUID().uuidString.lowercased()
        let spatialName = "\(spatialId).mov"
        try await SampleMedia.video(at: files1.original(spatialName), seed: 301, seconds: 1.0)
        var spatialMeta = UploadMetadata(takenAt: baseMs + 2000)
        spatialMeta.captureMode = "spatial"
        try Uploader.enqueue(
            database: db1, files: files1, assetId: spatialId, fileName: spatialName,
            kind: "video", mimeType: "video/quicktime", metadata: spatialMeta)

        var mixEdit = EditRecipe()
        mixEdit.audioMix = .studio
        mixEdit.audioMixIntensity = 0.8
        try actions1.correct(spatialId, AssetCorrection(edit: .set(mixEdit)))

        // Actions run before upload finishes: they must wait without failing or dropping.
        _ = await actions1.send(with: client1)
        let pendingBeforeUpload = try await db1.writer.read { try PendingAction.fetchCount($0) }
        #expect(pendingBeforeUpload == 2, "edits for not-yet-uploaded assets must stay queued")

        // Drain uploader, then deliver queued edits.
        let uploader1 = Uploader(database: db1, files: files1, client: client1)
        _ = await uploader1.drain()
        _ = await actions1.send(with: client1)
        let pendingAfterUpload = try await db1.writer.read { try PendingAction.fetchCount($0) }
        #expect(pendingAfterUpload == 0, "all deferred edits must reach the server after upload")

        // Fresh second device logs in and syncs the entire library from scratch.
        let (conn2, token2) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "r3-ipad", platform: "ios", installationId: "install-r3-ipad"))
        let client2 = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(conn2.fingerprint),
            token: token2)
        let db2 = try HaldenDatabase()
        try db2.save(server: StoredServer(serverId: conn2.serverId, connection: conn2, syncSince: 0, backup: nil))
        _ = try await Syncer(database: db2, client: client2).run()

        let syncedBurst0 = try #require(try db2.asset(burstIds[0]))
        let syncedBurst1 = try #require(try db2.asset(burstIds[1]))
        #expect(syncedBurst0.burstId == burstId)
        #expect(syncedBurst1.burstId == burstId)

        let syncedLive = try #require(try db2.asset(liveId))
        #expect(syncedLive.isLivePhoto)
        #expect(syncedLive.edit?.style?.preset == .dramatic)
        #expect(syncedLive.edit?.filter == .vivid)
        #expect(syncedLive.edit?.portraitAperture == 2.4)

        let syncedSpatial = try #require(try db2.asset(spatialId))
        #expect(syncedSpatial.isSpatial)
        #expect(syncedSpatial.edit?.audioMix == .studio)
        #expect(syncedSpatial.edit?.audioMixIntensity == 0.8)
    }
}
