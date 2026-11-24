import Foundation
import GRDB
import Testing

@testable import HaldenKit

@Suite struct UploadRuleTests {
    let wifi = NetworkSituation(kind: .wifi)
    let cellular = NetworkSituation(kind: .cellular, expensive: true)
    let hotspot = NetworkSituation(kind: .wifi, expensive: true)
    let lowData = NetworkSituation(kind: .wifi, constrained: true)

    @Test func theDefaultsSendPhotosEverywhereAndVideosOnWiFi() {
        let settings = AppSettings()
        #expect(UploadRules.permit(on: wifi, atHome: false, settings: settings) == .all)
        #expect(
            UploadRules.permit(on: cellular, atHome: false, settings: settings)
                == UploadPermit(photos: true, videos: false))
        #expect(
            UploadRules.permit(on: hotspot, atHome: true, settings: settings).videos == false, "a hotspot is cellular")
        #expect(UploadRules.permit(on: lowData, atHome: true, settings: settings).videos == false)
        #expect(UploadRules.permit(on: .offline, atHome: true, settings: settings) == .nothing)
        #expect(UploadRules.reason(for: .all, on: wifi, atHome: true, settings: settings) == nil)
        #expect(
            UploadRules.reason(
                for: UploadPermit(photos: true, videos: false), on: cellular, atHome: false, settings: settings)
                == "Videos wait for Wi-Fi.")
    }

    @Test func withoutCellularNothingGoesOverIt() {
        var settings = AppSettings()
        settings.uploadOverCellular = false
        #expect(UploadRules.permit(on: cellular, atHome: false, settings: settings) == .nothing)
        #expect(UploadRules.permit(on: hotspot, atHome: true, settings: settings) == .nothing)
        #expect(UploadRules.permit(on: wifi, atHome: false, settings: settings) == .all)
        settings.videosOnlyOnWiFi = false
        settings.uploadOverCellular = true
        #expect(UploadRules.permit(on: cellular, atHome: false, settings: settings) == .all)
    }

    /// Only at home: on Wi-Fi, and the server answers at its home address, not over Tailscale.
    @Test func onlyAtHomeNeedsTheHomeWiFi() {
        var settings = AppSettings()
        settings.onlyOnHomeNetwork = true
        #expect(UploadRules.permit(on: wifi, atHome: true, settings: settings) == .all)
        #expect(UploadRules.permit(on: wifi, atHome: false, settings: settings) == .nothing)
        #expect(UploadRules.permit(on: cellular, atHome: true, settings: settings) == .nothing)
        #expect(UploadRules.permit(on: NetworkSituation(kind: .wired), atHome: true, settings: settings) == .all)
    }

    @Test func tailscaleAddressesAreRecognized() {
        #expect(Addresses.isTailscale("100.105.174.83"))
        #expect(Addresses.isTailscale("100.64.0.1") && Addresses.isTailscale("100.127.255.255"))
        #expect(!Addresses.isTailscale("100.128.0.1") && !Addresses.isTailscale("100.63.0.1"))
        #expect(Addresses.isTailscale("[fd7a:115c:a1e0::e54a:ae54]"))
        #expect(!Addresses.isTailscale("192.168.178.87") && !Addresses.isTailscale("fd5c:84d4:aa63::1"))
    }
}

@Suite struct UploadQueueTests {
    func world() throws -> (HaldenDatabase, FileLocations, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        return (try HaldenDatabase(), files, root)
    }

    func add(_ id: String, kind: String, at: Int64, _ database: HaldenDatabase, _ files: FileLocations) throws {
        let name = "\(id).\(kind == "video" ? "mov" : "jpg")"
        try Data(repeating: 1, count: 100).write(to: files.original(name))
        try Uploader.enqueue(
            database: database, files: files, assetId: id, fileName: name, kind: kind,
            mimeType: kind == "video" ? "video/quicktime" : "image/jpeg", metadata: UploadMetadata(takenAt: at))
        try database.writer.write { db in
            try db.execute(sql: "UPDATE upload SET createdAt = ? WHERE assetId = ?", arguments: [at, id])
        }
    }

    /// Videos wait for Wi-Fi; the photos behind them go first.
    @Test func videosWaitWhileOnlyPhotosMayGo() async throws {
        let (database, files, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        try add("v", kind: "video", at: 1, database, files)
        try add("p", kind: "photo", at: 2, database, files)
        let uploader = Uploader(
            database: database, files: files,
            client: APIClient(base: URL(string: "https://127.0.0.1:1/api/v1")!, trust: .pinned("")))
        #expect(await uploader.nextDue(permit: .all)?.assetId == "v")
        #expect(await uploader.nextDue(permit: UploadPermit(photos: true, videos: false))?.assetId == "p")
        #expect(await uploader.nextDue(permit: UploadPermit(photos: false, videos: true))?.assetId == "v")
        #expect(await uploader.nextDue(permit: .nothing) == nil)
    }

    @Test func theSummaryCountsThisRound() throws {
        let (database, files, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try database.uploadSummary() == UploadSummary())
        try add("old", kind: "photo", at: 1, database, files)
        try add("a", kind: "photo", at: 10, database, files)
        try add("b", kind: "video", at: 11, database, files)
        try add("c", kind: "photo", at: 12, database, files)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE upload SET state = 'done' WHERE assetId IN ('old', 'a')")
            try db.execute(sql: "UPDATE upload SET sent = 40 WHERE assetId = 'b'")
            try db.execute(sql: "UPDATE upload SET state = 'failed', attempts = 3 WHERE assetId = 'c'")
        }
        try database.setMeta("uploadRound", Data("10".utf8))
        let summary = try database.uploadSummary()
        #expect(summary.total == 3 && summary.done == 1 && summary.failed == 1 && summary.waiting == 1)
        #expect(summary.bytesSent == 140 && summary.bytesTotal == 300)
        #expect(try database.pendingUploads().map(\.assetId) == ["b", "c"])
        try Uploader.retry("C", database: database)
        let retried = try #require(try database.upload("c"))
        #expect(retried.state == "waiting" && retried.attempts == 0 && retried.retryAt == 0)
    }

    /// A round starts when something is added to an empty queue.
    @Test func aNewRoundStartsAfterTheQueueRanEmpty() throws {
        let (database, files, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        func enqueue(_ id: String) throws {
            try Data(repeating: 2, count: 10).write(to: files.original("\(id).jpg"))
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: "\(id).jpg", kind: "photo",
                mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1))
        }
        try enqueue("x")
        try enqueue("y")
        #expect(try database.uploadSummary().total == 2)
        try database.writer.write { db in try db.execute(sql: "UPDATE upload SET state = 'done'") }
        #expect(try database.uploadSummary().done == 2, "the finished round still shows")
        Thread.sleep(forTimeInterval: 0.01)
        try enqueue("z")
        let summary = try database.uploadSummary()
        #expect(summary.total == 1 && summary.waiting == 1)
    }

    /// A phone's copy goes only when the server has the original (checked by its hash) and the
    /// thumbnail and preview are here.
    @Test func onlySafeCopiesAreRemoved() throws {
        let (database, files, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["safe", "uploading", "nopreview", "notchecked"] {
            try add(id, kind: "photo", at: 1, database, files)
        }
        try Data("t".utf8).write(to: files.thumbnail(sha256: "t"))
        try Data("p".utf8).write(to: files.thumbnail(sha256: "p"))
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE asset SET backedUp = 1, originalSha256 = 'o', thumbnailSha256 = 't', previewSha256 = 'p'
                    """)
            try db.execute(sql: "UPDATE upload SET state = 'done' WHERE assetId <> 'uploading'")
            try db.execute(sql: "UPDATE asset SET previewSha256 = 'missing' WHERE id = 'nopreview'")
            try db.execute(sql: "UPDATE asset SET originalSha256 = NULL WHERE id = 'notchecked'")
        }
        #expect(try LocalCopies.usage(database: database, files: files) == (4, 400))
        #expect(try LocalCopies.remove(database: database, files: files) == 1)
        #expect(try database.asset("safe")?.localFile == nil)
        #expect(!FileManager.default.fileExists(atPath: files.original("safe.jpg").path))
        for kept in ["uploading", "nopreview", "notchecked"] {
            #expect(try database.asset(kept)?.localFile != nil, "\(kept)")
        }
        #expect(try LocalCopies.remove(["uploading"], database: database, files: files) == 0)
    }
}
