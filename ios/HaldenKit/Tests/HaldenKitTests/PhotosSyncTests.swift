import Foundation
import GRDB
import Testing

@testable import HaldenKit

/// Apple Photos for the tests: items with made-up files and a history of changes.
final class StandInPhotoLibrary: PhotoLibrary, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: PhotoItem] = [:]
    private var history: [(added: [String], deleted: [String])] = []
    var deletedOnRequest: [String] = []
    var allowDelete = true

    func add(_ item: PhotoItem) {
        lock.withLock {
            items[item.localIdentifier] = item
            history.append(([item.localIdentifier], []))
        }
    }

    func remove(_ identifier: String) {
        lock.withLock {
            items[identifier] = nil
            history.append(([], [identifier]))
        }
    }

    func mayRead() async -> Bool { true }
    func mayAdd() async -> Bool { true }

    func changes(since token: Data?) async throws -> PhotoChanges {
        lock.withLock {
            let end = history.count
            guard let token, let start = Int(String(decoding: token, as: UTF8.self)) else {
                return PhotoChanges(added: [], deleted: [], token: Data(String(end).utf8))
            }
            var added: [String] = []
            var deleted: [String] = []
            for change in history[start..<end] {
                added += change.added
                added.removeAll { change.deleted.contains($0) }
                deleted += change.deleted
            }
            return PhotoChanges(
                added: added.compactMap { items[$0] }, deleted: deleted, token: Data(String(end).utf8))
        }
    }

    func items(after date: Date?, limit: Int) async throws -> [PhotoItem] {
        lock.withLock {
            Array(
                items.values.filter { item in date.map { (item.creationDate ?? .distantPast) > $0 } ?? true }
                    .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                    .prefix(limit))
        }
    }

    func items(withIdentifiers identifiers: [String]) async -> [PhotoItem] {
        lock.withLock { identifiers.compactMap { items[$0] } }
    }

    func export(_ item: PhotoItem, into folder: URL) async throws -> [ExportedFile] {
        let seed = abs(item.localIdentifier.hashValue % 100_000)
        if item.kind == .video {
            let url = folder.appendingPathComponent("main.mov")
            try await SampleMedia.video(at: url, seed: seed, seconds: 0.5)
            return [ExportedFile(url: url, mimeType: "video/quicktime", originalFilename: "IMG_\(seed).MOV")]
        }
        let photo = folder.appendingPathComponent("main.jpg")
        try SampleMedia.photo(seed: seed, width: 64, height: 48)!.write(to: photo)
        var files = [ExportedFile(url: photo, mimeType: "image/jpeg", originalFilename: "IMG_\(seed).JPG")]
        if item.isLivePhoto {
            let video = folder.appendingPathComponent("live.mov")
            try await SampleMedia.video(at: video, seed: seed + 1, seconds: 0.5)
            files.append(ExportedFile(url: video, mimeType: "video/quicktime", originalFilename: "IMG_\(seed).MOV"))
        }
        return files
    }

    func save(_ file: URL, kind: PhotoItem.Kind, pairedVideo: URL?) async throws -> String {
        let identifier = "saved-\(UUID().uuidString)"
        add(
            PhotoItem(
                localIdentifier: identifier, kind: kind, isLivePhoto: pairedVideo != nil, creationDate: Date(),
                width: 64, height: 48))
        return identifier
    }

    func delete(_ identifiers: [String]) async -> Bool {
        guard allowDelete else { return false }
        lock.withLock { deletedOnRequest += identifiers }
        for identifier in identifiers { remove(identifier) }
        return true
    }
}

@Suite struct PhotosSyncTests {
    func world() throws -> (HaldenDatabase, FileLocations, StandInPhotoLibrary, PhotosSync, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        let library = StandInPhotoLibrary()
        return (database, files, library, PhotosSync(library: library, database: database, files: files), root)
    }

    func item(_ id: String, live: Bool = false, video: Bool = false, at seconds: Double = 1_800_000_000) -> PhotoItem {
        PhotoItem(
            localIdentifier: id, kind: video ? .video : .photo, isLivePhoto: live,
            creationDate: Date(timeIntervalSince1970: seconds),
            location: ClientLocation(latitude: 47.5, longitude: 8.5, horizontalAccuracy: 12), width: 64, height: 48,
            durationMs: video ? 500 : nil)
    }

    /// New in Apple Photos: into Halden once, a Live Photo with its video after the photo.
    @Test func newPhotosComeInOnce() async throws {
        let (database, _, library, sync, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        library.add(item("before"))
        #expect(
            try await sync.takeOverChanges(settings: AppSettings()) == (0, 0),
            "the first look only notes where it stands")
        library.add(item("live", live: true))
        library.add(item("clip", video: true, at: 1_800_000_100))
        #expect(try await sync.takeOverChanges(settings: AppSettings()) == (2, 0))
        let assets = try database.library()
        #expect(assets.map(\.kind) == ["video", "photo"])
        #expect(assets.allSatisfy { $0.origin == "photos" && $0.latitude == 47.5 && !$0.backedUp })
        let uploads = try database.pendingUploads()
        #expect(uploads.map(\.role).sorted() == ["original", "original", "paired_video"])
        #expect(
            uploads.first { $0.role == "original" && $0.mimeType == "image/jpeg" }?.metadata?.originalFilename != nil)
        #expect(try await sync.takeOverChanges(settings: AppSettings()) == (0, 0), "nothing twice")
    }

    /// Deleted in Apple Photos: into Halden's trash, restorable; not when that is turned off.
    @Test func deletedThereGoesToTheTrashHere() async throws {
        let (database, _, library, sync, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await sync.takeOverChanges(settings: AppSettings())
        library.add(item("a"))
        library.add(item("b", at: 1_800_000_050))
        try await sync.takeOverChanges(settings: AppSettings())
        let ids = try database.library().map(\.id)
        library.remove("a")
        #expect(try await sync.takeOverChanges(settings: AppSettings()) == (0, 1))
        #expect(try database.trash().count == 1)
        #expect(try Actions(database: database).pending().map(\.kind) == ["trash"])
        var keep = AppSettings()
        keep.syncDeletionsWithPhotos = false
        library.remove("b")
        #expect(try await sync.takeOverChanges(settings: keep) == (0, 0))
        #expect(try database.library().count == 1, "kept in Halden")
        #expect(ids.count == 2)
    }

    /// A photo taken with Halden goes into Apple Photos and never comes back as new; deleted
    /// everywhere in Halden, it is deleted there too, if the person agrees.
    @Test func haldensOwnPhotosGoThereAndNotBack() async throws {
        let (database, files, library, sync, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await sync.takeOverChanges(settings: AppSettings())
        try SampleMedia.photo(seed: 3, width: 64, height: 48)!.write(to: files.original("own.jpg"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "own", fileName: "own.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1))
        await sync.save(assetId: "own", settings: AppSettings())
        #expect(await sync.inPhotos(["own"]))
        #expect(try await sync.takeOverChanges(settings: AppSettings()) == (0, 0), "linked: not imported")
        library.allowDelete = false
        #expect(await sync.deleteInPhotos(assetIds: ["own"], settings: AppSettings()) == false, "the person said no")
        library.allowDelete = true
        #expect(await sync.deleteInPhotos(assetIds: ["own"], settings: AppSettings()))
        #expect(library.deletedOnRequest.count == 1)
        #expect(!(await sync.inPhotos(["own"])))
        var off = AppSettings()
        off.saveToPhotos = false
        try SampleMedia.photo(seed: 4, width: 64, height: 48)!.write(to: files.original("two.jpg"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "two", fileName: "two.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 2))
        await sync.save(assetId: "two", settings: off)
        #expect(!(await sync.inPhotos(["two"])))
    }

    /// A Live Photo taken with Halden goes there as a Live Photo.
    @Test func haldensLivePhotosGoThereAsLivePhotos() async throws {
        let (database, files, library, sync, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        try SampleMedia.photo(seed: 5, width: 64, height: 48)!.write(to: files.original("live.jpg"))
        try Data(repeating: 1, count: 10).write(to: files.original("live-live.mov"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "live", fileName: "live.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1))
        try Uploader.enqueuePairedVideo(
            database: database, files: files, assetId: "live", fileName: "live-live.mov", mimeType: "video/quicktime")
        await sync.save(assetId: "live", settings: AppSettings())
        #expect(try await library.items(after: nil, limit: 10).contains { $0.isLivePhoto })
    }

    /// The library from before comes in pieces and goes on where it stopped.
    @Test func theLibraryFromBeforeComesInPieces() async throws {
        let (database, _, library, sync, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<5 { library.add(item("old-\(n)", at: 1_700_000_000 + Double(n))) }
        #expect(try await sync.importedUpTo() == nil)
        #expect(try await sync.importExisting(limit: 2) == (2, false))
        #expect(try await sync.importExisting(limit: 2) == (2, false))
        #expect(try await sync.importExisting(limit: 2) == (1, true))
        #expect(try await sync.importExisting(limit: 2) == (0, true))
        #expect(try database.library().count == 5)
        #expect(try await sync.importedUpTo() == Date(timeIntervalSince1970: 1_700_000_004))
    }

    /// Screenshots without GPS get the device's current place when recent, the nearest photo's
    /// place within two hours when older, or stay without a place otherwise; Apple Photos is never
    /// modified.
    @Test func screenshotsGetEstimatedPlacesByAgeAndNearbyPhotos() async throws {
        let (database, _, library, sync, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await sync.takeOverChanges(settings: AppSettings())

        // Seed a located photo 90 minutes before `now`.
        let nearbyTime = now.addingTimeInterval(-90 * 60)
        var nearby = LocalAsset(
            id: "nearby-photo", kind: "photo", takenAt: Int64((nearbyTime.timeIntervalSince1970 * 1000).rounded()))
        nearby.latitude = 48.137
        nearby.longitude = 11.575
        nearby.locationSource = "client"
        let nearbyCopy = nearby
        try await database.writer.write { db in try nearbyCopy.insert(db) }

        // 1. Recent screenshot (10 min old) → gets the device's current place (`device`).
        library.add(
            PhotoItem(
                localIdentifier: "shot-recent", kind: .photo, isScreenshot: true,
                creationDate: now.addingTimeInterval(-10 * 60), width: 1179, height: 2556))
        // 2. Older screenshot (60 min old, 30 min after nearby photo) → gets nearby photo (`estimated`).
        library.add(
            PhotoItem(
                localIdentifier: "shot-older", kind: .photo, isScreenshot: true,
                creationDate: now.addingTimeInterval(-60 * 60), width: 1179, height: 2556))
        // 3. Very old screenshot (6 h old, > 2 h from any photo) → stays without a place.
        library.add(
            PhotoItem(
                localIdentifier: "shot-ancient", kind: .photo, isScreenshot: true,
                creationDate: now.addingTimeInterval(-6 * 3600), width: 1179, height: 2556))
        // 4. Recent screen recording (5 min old) → gets `device` when enabled.
        library.add(
            PhotoItem(
                localIdentifier: "rec-recent", kind: .video, isScreenRecording: true,
                creationDate: now.addingTimeInterval(-5 * 60), width: 1179, height: 2556, durationMs: 2000))

        let deviceReading = PlaceReading(
            latitude: 50.5558, longitude: 9.6808, altitude: 261, horizontalAccuracy: 8, verticalAccuracy: 5,
            measuredAt: now)
        #expect(
            try await sync.takeOverChanges(settings: AppSettings(), now: now, currentPlace: { deviceReading }) == (4, 0)
        )

        let byId = try await database.writer.read { db -> [String: LocalAsset] in
            let links = try PhotosLink.fetchAll(db)
            var out: [String: LocalAsset] = [:]
            for link in links {
                if let asset = try LocalAsset.fetchOne(db, key: link.assetId) { out[link.localIdentifier] = asset }
            }
            return out
        }
        #expect(byId["shot-recent"]?.locationSource == "device")
        #expect(byId["shot-recent"]?.latitude == 50.5558)
        #expect(byId["shot-recent"]?.hasEstimatedLocation == true)
        #expect(byId["shot-recent"]?.mapPoint?.estimated == true)

        #expect(byId["shot-older"]?.locationSource == "estimated")
        #expect(byId["shot-older"]?.latitude == 48.137)
        #expect(byId["shot-older"]?.hasEstimatedLocation == true)

        #expect(byId["shot-ancient"]?.hasLocation == false)

        #expect(byId["rec-recent"]?.locationSource == "device")
        #expect(byId["rec-recent"]?.latitude == 50.5558)

        // Screen recordings off, and locateScreenshots off, are respected.
        var noRecordings = AppSettings()
        noRecordings.locateScreenRecordings = false
        library.add(
            PhotoItem(
                localIdentifier: "rec-ignored", kind: .video, isScreenRecording: true,
                creationDate: now.addingTimeInterval(-2 * 60), width: 1179, height: 2556, durationMs: 1000))
        #expect(
            try await sync.takeOverChanges(settings: noRecordings, now: now, currentPlace: { deviceReading }) == (1, 0))
        let recIgnoredLink = try await database.writer.read { db in try PhotosLink.fetchOne(db, key: "rec-ignored") }
        let recIgnored = try #require(recIgnoredLink.flatMap { try database.asset($0.assetId) })
        #expect(!recIgnored.hasLocation)

        var off = AppSettings()
        off.locateScreenshots = false
        library.add(
            PhotoItem(
                localIdentifier: "shot-off", kind: .photo, isScreenshot: true,
                creationDate: now.addingTimeInterval(-1 * 60), width: 1179, height: 2556))
        #expect(try await sync.takeOverChanges(settings: off, now: now, currentPlace: { deviceReading }) == (1, 0))
        let shotOffLink = try await database.writer.read { db in try PhotosLink.fetchOne(db, key: "shot-off") }
        let shotOff = try #require(shotOffLink.flatMap { try database.asset($0.assetId) })
        #expect(!shotOff.hasLocation)
    }

    /// Recent screenshots fall back to a nearby photo when the iPhone has no live reading (e.g.
    /// background sync), and existing screenshots without a place get one once from nearby photos.
    @Test func existingScreenshotsAndFallbackUseNearbyPhotos() async throws {
        let (database, _, library, sync, root) = try world()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await sync.takeOverChanges(settings: AppSettings())

        // Import two screenshots and a regular unlocated photo while locateScreenshots is off
        // (simulating screenshots already in Halden from before C2).
        var disabled = AppSettings()
        disabled.locateScreenshots = false
        library.add(
            PhotoItem(
                localIdentifier: "old-shot", kind: .photo, isScreenshot: true,
                creationDate: now.addingTimeInterval(-45 * 60), width: 1179, height: 2556))
        library.add(
            PhotoItem(
                localIdentifier: "plain-photo", kind: .photo, isScreenshot: false,
                creationDate: now.addingTimeInterval(-40 * 60), width: 4032, height: 3024))
        _ = try await sync.takeOverChanges(settings: disabled, now: now)

        // Add a located photo 15 minutes from old-shot.
        var anchored = LocalAsset(
            id: "anchored", kind: "photo",
            takenAt: Int64((now.addingTimeInterval(-30 * 60).timeIntervalSince1970 * 1000).rounded()))
        anchored.latitude = 52.52
        anchored.longitude = 13.405
        anchored.locationSource = "client"
        let anchoredCopy = anchored
        try await database.writer.write { db in try anchoredCopy.insert(db) }

        // One-time pass locates only the existing screenshot, not the regular photo; second call is a no-op.
        #expect(try await sync.locateExistingScreenshots(settings: AppSettings()) == 1)
        #expect(try await sync.locateExistingScreenshots(settings: AppSettings()) == 0)

        let shotLink = try #require(
            try await database.writer.read { db in try PhotosLink.fetchOne(db, key: "old-shot") })
        let shot = try #require(try database.asset(shotLink.assetId))
        #expect(shot.latitude == 52.52 && shot.locationSource == "estimated")
        let plainLink = try #require(
            try await database.writer.read { db in try PhotosLink.fetchOne(db, key: "plain-photo") })
        let plain = try #require(try database.asset(plainLink.assetId))
        #expect(!plain.hasLocation, "regular photos are not touched")

        // Recent screenshot with no live device reading falls back to the nearby photo.
        library.add(
            PhotoItem(
                localIdentifier: "bg-shot", kind: .photo, isScreenshot: true,
                creationDate: now.addingTimeInterval(-20 * 60), width: 1179, height: 2556))
        #expect(try await sync.takeOverChanges(settings: AppSettings(), now: now, currentPlace: { nil }) == (1, 0))
        let bgLink = try #require(try await database.writer.read { db in try PhotosLink.fetchOne(db, key: "bg-shot") })
        let bgShot = try #require(try database.asset(bgLink.assetId))
        #expect(bgShot.latitude == 52.52 && bgShot.locationSource == "estimated")
    }
}

@Suite struct UploadRoleMigrationTests {
    /// Uploads waiting from before become the originals' uploads.
    @Test func waitingUploadsSurviveTheChange() throws {
        let queue = try DatabaseQueue()
        try HaldenDatabase.migrator.migrate(queue, upTo: "2: details, actions, Apple Photos")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO asset (id, kind, takenAt, localFile, backedUp) VALUES ('a', 'photo', 5, 'a.heic', 0)")
            try db.execute(
                sql: """
                    INSERT INTO upload (assetId, file, mimeType, size, sent, state, uploadId, createdAt)
                    VALUES ('a', 'a.heic', 'image/heic', 10, 4, 'sending', 'u1', 1)
                    """)
        }
        try HaldenDatabase.migrator.migrate(queue)
        let item = try queue.read { db in
            try UploadItem.fetchOne(db, key: ["assetId": "a", "role": "original"])
        }
        #expect(item?.sent == 4 && item?.uploadId == "u1" && item?.state == "sending")
    }

    /// A Live Photo from Apple Photos waiting from before knows its video afterwards.
    @Test func aWaitingLivePhotoKnowsItsVideo() throws {
        let queue = try DatabaseQueue()
        try HaldenDatabase.migrator.migrate(queue, upTo: "3: several files per asset")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO asset (id, kind, takenAt, localFile, backedUp) VALUES ('a', 'photo', 5, 'a.heic', 0)")
            try db.execute(
                sql: """
                    INSERT INTO upload (assetId, role, file, mimeType, size, createdAt)
                    VALUES ('a', 'original', 'a.heic', 'image/heic', 10, 1),
                           ('a', 'paired_video', 'a-live.mov', 'video/quicktime', 10, 1)
                    """)
        }
        try HaldenDatabase.migrator.migrate(queue)
        let asset = try queue.read { db in try LocalAsset.fetchOne(db, key: "a") }
        #expect(asset?.pairedVideoFile == "a-live.mov" && asset?.isLivePhoto == true)
    }
}

@Suite(.enabled(if: RealServer.available, "build the server first: cd server && cargo build"))
struct LivePhotoServerTests {
    /// A Live Photo's video reaches the server after its photo, as the asset's `paired_video`.
    @Test func aLivePhotoArrivesWithItsVideo() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "live", platform: "ios", installationId: "install-e2e-live"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let library = StandInPhotoLibrary()
        let sync = PhotosSync(library: library, database: database, files: files)
        _ = try await sync.takeOverChanges(settings: AppSettings())
        library.add(
            PhotoItem(
                localIdentifier: "live-1", kind: .photo, isLivePhoto: true, creationDate: Date(), width: 64, height: 48
            ))
        #expect(try await sync.takeOverChanges(settings: AppSettings()) == (1, 0))
        #expect(await Uploader(database: database, files: files, client: client).drain() == 2)
        #expect(try database.pendingUploads().isEmpty)
        let id = try #require(try database.library().first?.id)
        let asset = try await client.asset(id)
        #expect(asset.file("paired_video")?.mimeType == "video/quicktime")
        #expect(asset.file("original")?.mimeType == "image/jpeg")
    }

    /// A recent screenshot uploaded with source `device` arrives on the server marked as `device`,
    /// and an older unlocated screenshot receives its place via `/location-suggestion`.
    @Test func screenshotLocationReachesServerAsDevice() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "shots", platform: "ios", installationId: "install-e2e-shots"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let library = StandInPhotoLibrary()
        let sync = PhotosSync(library: library, database: database, files: files)
        let now = Date()
        _ = try await sync.takeOverChanges(settings: AppSettings())
        library.add(
            PhotoItem(
                localIdentifier: "shot-e2e", kind: .photo, isScreenshot: true,
                creationDate: now.addingTimeInterval(-120), width: 64, height: 48))
        let reading = PlaceReading(
            latitude: 50.5558, longitude: 9.6808, altitude: 260, horizontalAccuracy: 6, verticalAccuracy: 4,
            measuredAt: now)
        #expect(
            try await sync.takeOverChanges(settings: AppSettings(), now: now, currentPlace: { reading }) == (1, 0))
        #expect(await Uploader(database: database, files: files, client: client).drain() == 1)
        let id = try #require(try database.library().first?.id)
        let detail = try await client.detail(id)
        #expect(detail.asset.location?.source == "device")
        #expect(detail.original?.location == nil)
    }
}
