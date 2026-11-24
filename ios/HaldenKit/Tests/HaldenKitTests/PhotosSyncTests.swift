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
        let (database, files, library, sync, root) = try world()
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
}
