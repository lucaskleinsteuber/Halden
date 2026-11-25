import Foundation
import Testing

@testable import HaldenKit

struct GesturesAndBurstsTests {
    @Test func shutterDragRecognizesBurstLockAndQuickTakeZoom() {
        let range = 0.5...10.0

        // Dragging left in photo mode starts burst; small drags stay idle.
        #expect(
            ShutterGestures.evaluateDrag(
                dx: -20, dy: 0, quickTaking: false, locked: false, startZoom: 1, zoomRange: range) == .none)
        #expect(
            ShutterGestures.evaluateDrag(
                dx: -60, dy: 5, quickTaking: false, locked: false, startZoom: 1, zoomRange: range) == .burst)

        // During QuickTake, dragging right locks; dragging up zooms smoothly.
        #expect(
            ShutterGestures.evaluateDrag(
                dx: 60, dy: -4, quickTaking: true, locked: false, startZoom: 1, zoomRange: range) == .lockQuickTake)
        let zoomAction = ShutterGestures.evaluateDrag(
            dx: 0, dy: -(ShutterGestures.zoomDeadzone + ShutterGestures.zoomPointsPerDoubling),
            quickTaking: true, locked: false, startZoom: 1, zoomRange: range)
        if case .quickTakeZoom(let z) = zoomAction {
            #expect(abs(z - 2.0) < 0.01)
        } else {
            Issue.record("Expected quickTakeZoom, got \(zoomAction)")
        }

        // Clamped to upper bound; once locked, drag returns .none.
        let maxZoom = ShutterGestures.evaluateDrag(
            dx: 0, dy: -2000, quickTaking: true, locked: false, startZoom: 2, zoomRange: range)
        #expect(maxZoom == .quickTakeZoom(10.0))
        #expect(
            ShutterGestures.evaluateDrag(
                dx: 80, dy: -200, quickTaking: true, locked: true, startZoom: 1, zoomRange: range) == .none)
    }

    @Test func focusSunExposureAndRecordingElapsedTime() {
        // Dragging up brightens (+1 EV at -40 pt); dragging down darkens; clamped to -2...+2.
        #expect(ShutterGestures.sunExposureBias(from: 0, dy: -40) == 1.0)
        #expect(ShutterGestures.sunExposureBias(from: 0, dy: 40) == -1.0)
        #expect(ShutterGestures.sunExposureBias(from: 1.5, dy: -200) == 2.0)
        #expect(ShutterGestures.sunExposureBias(from: -1.5, dy: 200) == -2.0)

        // Recording timer excludes paused intervals and freezes while paused.
        let start = Date(timeIntervalSince1970: 1000)
        let pausedAt = start.addingTimeInterval(10)
        let later = start.addingTimeInterval(25)
        #expect(ShutterGestures.recordingElapsed(started: start, pausedAt: pausedAt, totalPaused: 0, now: later) == 10)
        #expect(ShutterGestures.recordingElapsed(started: start, pausedAt: nil, totalPaused: 15, now: later) == 10)
    }

    @Test func burstsCollapsePreserveOrderAndSelectKeepers() {
        func photo(_ id: String, at: Int64, burst: String? = nil) -> LocalAsset {
            var asset = LocalAsset(id: id, kind: "photo", takenAt: at)
            asset.burstId = burst
            return asset
        }
        let solo = photo("solo", at: 500)
        let b3 = photo("b3", at: 400, burst: "burst-1")
        let b2 = photo("b2", at: 399, burst: "burst-1")
        let b1 = photo("b1", at: 398, burst: "burst-1")
        let singleBurst = photo("lone", at: 300, burst: "burst-2")
        let list = [solo, b3, b2, b1, singleBurst]

        let stacks = Bursts.collapse(list)
        #expect(stacks.count == 3)
        #expect(stacks[0].cover.id == "solo")
        #expect(stacks[0].count == 1)
        #expect(stacks[1].cover.id == "b3")
        #expect(stacks[1].count == 3)
        #expect(stacks[1].burstId == "burst-1")
        #expect(stacks[1].memberIds == ["b3", "b2", "b1"])
        // A burst with only 1 surviving photo displays as a normal tile.
        #expect(stacks[2].cover.id == "lone")
        #expect(stacks[2].count == 1)

        // Members ordered chronologically (oldest first) for the burst picker.
        let members = Bursts.members(of: b3, in: list, chronological: true)
        #expect(members.map(\.id) == ["b1", "b2", "b3"])

        // Keeping b2 trashes b1 and b3; empty keeping set refuses to trash everything.
        #expect(Set(Bursts.toTrash(members: members, keeping: ["b2"])) == Set(["b1", "b3"]))
        #expect(Bursts.toTrash(members: members, keeping: []).isEmpty)
    }

    @Test func burstIdSyncsThroughRealServer() async throws {
        guard RealServer.available else { return }
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "burst", platform: "ios", installationId: "install-e2e-burst"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        let stored = StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil)
        try database.save(server: stored)

        let burstId = UUID().uuidString.lowercased()
        let a1 = UUID().uuidString.lowercased()
        let a2 = UUID().uuidString.lowercased()
        for (id, seed, ms) in [(a1, 10, Int64(1_795_443_730_000)), (a2, 11, Int64(1_795_443_730_200))] {
            let jpeg = try #require(SampleMedia.photo(seed: seed))
            let name = "\(id).jpg"
            try jpeg.write(to: files.original(name))
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: name, kind: "photo",
                mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: ms, burstId: burstId))
        }
        let uploader = Uploader(database: database, files: files, client: client)
        await uploader.drain()

        // A second device syncing from scratch sees both photos with the same burstId.
        let other = try HaldenDatabase()
        try other.save(server: stored)
        let syncer = Syncer(database: other, client: client)
        _ = try await syncer.run()
        let synced = try other.library()
        let stacks = Bursts.collapse(synced)
        let burstStack = try #require(stacks.first { $0.burstId == burstId })
        #expect(burstStack.count == 2)
        #expect(Set(burstStack.memberIds) == Set([a1, a2]))
    }
}
