import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HaldenKit

@Suite struct MigrationTests {
    /// A database from the first version keeps everything when it is brought up to date.
    @Test func versionOneDataSurvivesTheUpgrade() throws {
        let queue = try DatabaseQueue()
        try HaldenDatabase.migrator.migrate(queue, upTo: "1: server, assets, uploads")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO asset (id, kind, takenAt, localFile, backedUp) VALUES ('a', 'photo', 5, 'a.heic', 1)")
            try db.execute(
                sql: """
                    INSERT INTO upload (assetId, file, mimeType, size, state, createdAt)
                    VALUES ('a', 'a.heic', 'image/heic', 10, 'done', 1)
                    """)
        }
        try HaldenDatabase.migrator.migrate(queue)
        let asset = try queue.read { db in try LocalAsset.fetchOne(db, key: "a") }
        #expect(asset?.localFile == "a.heic")
        #expect(asset?.backedUp == true)
        #expect(asset?.latitude == nil && asset?.origin == nil)
        let tables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(Set(tables).isSuperset(of: ["action", "photosLink", "meta"]))
    }
}

@Suite struct CorrectionTests {
    /// The server tells "leave it" (missing) from "remove it" (`null`).
    @Test func keptFieldsAreLeftOutAndClearedOnesAreNull() throws {
        let correction = AssetCorrection(
            location: .clear, title: .set("Munich"), restore: ["takenAt"])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(correction)) as? [String: Any]
        #expect(json?["title"] as? String == "Munich")
        #expect(json?["location"] is NSNull)
        #expect(json?.keys.contains("takenAt") == false)
        #expect(json?["restore"] as? [String] == ["takenAt"])
        let back = try JSONDecoder().decode(AssetCorrection.self, from: JSONEncoder().encode(correction))
        #expect(back == correction)
    }
}

@Suite struct SettingsTests {
    @Test func defaultsAreTheAgreedOnes() {
        let settings = AppSettings()
        #expect(settings.uploadOverCellular && settings.videosOnlyOnWiFi && !settings.onlyOnHomeNetwork)
        #expect(settings.keepLocalCopies)
        #expect(settings.videoResolution == .uhd4K && settings.videoFrameRate == 60 && !settings.videoHDR)
        #expect(settings.importFromPhotos && settings.saveToPhotos && settings.syncDeletionsWithPhotos)
    }

    /// Settings saved by an older version (missing keys) or with an option that went away keep the
    /// rest and take defaults for what they don't know.
    @Test func missingOrUnknownValuesTakeTheDefault() throws {
        let saved = Data(#"{"keepLocalCopies": false, "videoResolution": "8k", "videoFrameRate": 30}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        #expect(settings.keepLocalCopies == false)
        #expect(settings.videoFrameRate == 30)
        #expect(settings.videoResolution == .uhd4K, "8k doesn't exist: the default")
        #expect(settings.saveToPhotos)
    }

    @Test func savedSettingsComeBack() {
        let suite = "halden-tests-\(UUID().uuidString)"
        let store = DefaultsSettingsStore(suite: suite)
        var settings = AppSettings()
        settings.videosOnlyOnWiFi = false
        settings.flash = .off
        store.save(settings)
        #expect(DefaultsSettingsStore(suite: suite).load() == settings)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

@Suite struct ActionTests {
    func library(_ ids: [String], backedUp: Bool = true) throws -> HaldenDatabase {
        let database = try HaldenDatabase()
        try database.writer.write { db in
            for (n, id) in ids.enumerated() {
                var asset = LocalAsset(id: id, kind: "photo", takenAt: Int64(n))
                asset.backedUp = backedUp
                try asset.insert(db)
            }
        }
        return database
    }

    /// Changes show at once, in this order, and wait for the server.
    @Test func changesShowAtOnceAndWaitInOrder() throws {
        let database = try library(["a", "b", "c"])
        let actions = Actions(database: database)
        try actions.trash(["a", "B"])
        #expect(try database.library().map(\.id) == ["c"])
        #expect(try database.trash().count == 2)
        try actions.restore(["b"])
        try actions.deleteForGood(["a", "c"])
        #expect(try database.asset("a")?.deletedAt != nil)
        #expect(try database.asset("c")?.deletedAt == nil, "not in the trash: not deleted")
        try actions.correct(
            "c", AssetCorrection(location: .set(CorrectedLocation(latitude: 1, longitude: 2)), title: .set("Hi")))
        try actions.setLocation(["b"], CorrectedLocation(latitude: 3, longitude: 4, estimated: true))
        let c = try #require(try database.asset("c"))
        #expect(c.title == "Hi" && c.latitude == 1 && c.locationSource == "manual")
        #expect(try database.asset("b")?.locationSource == "estimated")
        #expect(try actions.pending().map(\.kind) == ["trash", "restore", "delete", "correct", "locate"])
        #expect(try actions.pending()[0].assetIds == ["a", "b"], "ids are kept in lower case")
    }

    /// While a change waits, the sync doesn't undo it here.
    @Test func theSyncLeavesWaitingChangesAlone() throws {
        let database = try library(["a"])
        try database.save(
            server: StoredServer(
                serverId: "s",
                connection: ServerConnection(
                    serverId: "s", name: "x", addresses: [], port: 1, fingerprint: "", userId: "u", username: "u",
                    deviceId: "d")))
        try Actions(database: database).trash(["a"])
        try database.writer.write { db in
            let waiting = try Actions.waitingAssetIds(db)
            #expect(waiting == ["a"])
        }
    }

    /// Nothing reachable: everything waits, nothing is lost.
    @Test func withoutTheServerEverythingWaits() async throws {
        let database = try library(["a"])
        let actions = Actions(database: database)
        try actions.trash(["a"])
        let nowhere = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: 1)!, trust: .pinned(String(repeating: "0", count: 64)),
            token: "t", timeout: 2)
        #expect(await actions.send(with: nowhere) == .later)
        #expect(try actions.pending().count == 1)
        #expect(try database.asset("a")?.trashedAt != nil)
    }
}

@Suite struct ImagePipelineTests {
    func jpeg(at url: URL, width: Int, height: Int) throws {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Photos taken here get their thumbnail made from the file, scaled to the cell, and the second
    /// time it comes straight from memory.
    @Test func picturesAreScaledToTheCellAndRemembered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        defer { try? FileManager.default.removeItem(at: root) }
        var assets: [LocalAsset] = []
        for n in 0..<20 {
            try jpeg(at: files.original("\(n).jpg"), width: 1200, height: 800)
            assets.append(LocalAsset(id: "\(n)", kind: "photo", takenAt: Int64(n), localFile: "\(n).jpg"))
        }
        let pipeline = ImagePipeline(loader: ThumbnailLoader(files: files, client: nil))
        // Many cells asking at once.
        let images = await withTaskGroup(of: DecodedImage?.self) { group in
            for asset in assets { group.addTask { await pipeline.image(for: asset, pixels: 300) } }
            var found: [DecodedImage?] = []
            for await image in group { found.append(image) }
            return found
        }
        #expect(images.compactMap { $0 }.count == 20)
        let first = try #require(images.first ?? nil)
        #expect(max(first.cgImage.width, first.cgImage.height) == 300)
        #expect(pipeline.cached(assets[3], pixels: 300) != nil)
        #expect(pipeline.cached(assets[3], pixels: 600) == nil, "another size is another picture")
    }
}
