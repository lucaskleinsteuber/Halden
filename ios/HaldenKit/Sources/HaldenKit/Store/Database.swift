import Foundation
import GRDB

/// The app's own database (SQLite via GRDB): the server it belongs to, every photo it knows
/// (taken here or synced from the server), the upload queue and how far sync got. It survives
/// app restarts, so nothing taken is ever forgotten before it is backed up.
public final class HaldenDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (and creates) the database file.
    public init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        writer = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(writer)
    }

    /// An in-memory database, for tests and previews.
    public init() throws {
        writer = try DatabaseQueue()
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("1: server, assets, uploads") { db in
            try db.create(table: "server") { t in
                t.primaryKey("serverId", .text)
                t.column("connection", .jsonText).notNull()
                // Sync position: the last change number seen.
                t.column("syncSince", .integer).notNull().defaults(to: 0)
                t.column("backup", .jsonText)
            }
            try db.create(table: "asset") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("takenAt", .integer).notNull()
                t.column("timeZoneOffsetMinutes", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("title", .text)
                // Taken on this phone: where the file is (inside the app's folder).
                t.column("localFile", .text)
                t.column("mimeType", .text)
                // The server has the original, checked by its hash.
                t.column("backedUp", .boolean).notNull().defaults(to: false)
                t.column("originalSha256", .text)
                t.column("thumbnailSha256", .text)
                t.column("previewSha256", .text)
                t.column("seq", .integer)
                t.column("trashedAt", .integer)
                t.column("deletedAt", .integer)
            }
            try db.create(index: "asset_by_time", on: "asset", columns: ["takenAt"])
            try db.create(table: "upload") { t in
                t.primaryKey("assetId", .text).references("asset", onDelete: .cascade)
                t.column("file", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("sha256", .text)
                t.column("metadata", .jsonText)
                // The server's id for this upload, once announced.
                t.column("uploadId", .text)
                // How many bytes the server has.
                t.column("sent", .integer).notNull().defaults(to: 0)
                // `waiting`, `sending`, `thumbnails`, `done`, `failed`
                t.column("state", .text).notNull().defaults(to: "waiting")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("retryAt", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .integer).notNull()
            }
        }
        migrator.registerMigration("2: details, actions, Apple Photos") { db in
            try db.alter(table: "asset") { t in
                t.add(column: "durationMs", .integer)
                t.add(column: "description", .text)
                // The effective place (a correction if there is one), for the map and the
                // "without location" view without asking the server.
                t.add(column: "latitude", .double)
                t.add(column: "longitude", .double)
                t.add(column: "altitude", .double)
                t.add(column: "locationAccuracy", .double)
                t.add(column: "heading", .double)
                // `client`, `exif`, `manual` or `estimated`.
                t.add(column: "locationSource", .text)
                // Where a photo on this device came from: `camera` (Halden) or `photos` (Apple
                // Photos). Empty for photos that came from the server.
                t.add(column: "origin", .text)
            }
            try db.create(index: "asset_without_location", on: "asset", columns: ["latitude", "takenAt"])
            // Changes made here that the server hasn't heard of yet, oldest first.
            try db.create(table: "action") { t in
                t.autoIncrementedPrimaryKey("id")
                // `trash`, `restore`, `delete`, `correct`, `locate`
                t.column("kind", .text).notNull()
                t.column("assetIds", .jsonText).notNull()
                t.column("payload", .blob)
                t.column("createdAt", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }
            // Which Apple Photos item became which Halden asset, so nothing comes in twice.
            try db.create(table: "photosLink") { t in
                t.primaryKey("localIdentifier", .text)
                t.column("assetId", .text).notNull()
                t.column("linkedAt", .integer).notNull()
            }
            try db.create(index: "photosLink_by_asset", on: "photosLink", columns: ["assetId"])
            // Small pieces of state (e.g. how far the Apple Photos import got).
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob)
            }
        }
        migrator.registerMigration("3: several files per asset") { db in
            // A Live Photo is a photo and a short video: two uploads for one asset.
            try db.create(table: "upload_new") { t in
                t.column("assetId", .text).notNull().references("asset", onDelete: .cascade)
                // `original`, or `paired_video` for a Live Photo's video (after the original).
                t.column("role", .text).notNull().defaults(to: "original")
                t.column("file", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("sha256", .text)
                t.column("metadata", .jsonText)
                t.column("uploadId", .text)
                t.column("sent", .integer).notNull().defaults(to: 0)
                t.column("state", .text).notNull().defaults(to: "waiting")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("retryAt", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .integer).notNull()
                t.primaryKey(["assetId", "role"])
            }
            try db.execute(
                sql: """
                    INSERT INTO upload_new (assetId, role, file, mimeType, size, sha256, metadata, uploadId,
                                            sent, state, attempts, lastError, retryAt, createdAt)
                    SELECT assetId, 'original', file, mimeType, size, sha256, metadata, uploadId,
                           sent, state, attempts, lastError, retryAt, createdAt FROM upload
                    """)
            try db.drop(table: "upload")
            try db.rename(table: "upload_new", to: "upload")
        }
        migrator.registerMigration("4: Live Photos") { db in
            try db.alter(table: "asset") { t in
                // A Live Photo's video: its file on this iPhone, and its hash once on the server.
                t.add(column: "pairedVideoFile", .text)
                t.add(column: "pairedVideoSha256", .text)
            }
            try db.execute(
                sql: """
                    UPDATE asset SET pairedVideoFile = (
                        SELECT file FROM upload WHERE upload.assetId = asset.id AND role = 'paired_video')
                    """)
        }
        migrator.registerMigration("5: slow motion and time-lapse") { db in
            try db.alter(table: "asset") { t in
                // `slowmo` or `timelapse` for videos taken that way.
                t.add(column: "captureMode", .text)
                // The slow part of a slow-motion video (JSON), when it was changed.
                t.add(column: "playback", .jsonText)
            }
        }
        migrator.registerMigration("6: albums") { db in
            try db.create(table: "album") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("coverAssetId", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .integer).notNull()
            }
            try db.create(table: "albumAsset") { t in
                t.column("albumId", .text).notNull().references("album", onDelete: .cascade)
                // Not a reference: the photo may come with a later page of the sync.
                t.column("assetId", .text).notNull()
                t.column("addedAt", .integer).notNull()
                t.primaryKey(["albumId", "assetId"])
            }
            try db.create(index: "albumAsset_by_asset", on: "albumAsset", columns: ["assetId"])
        }
        migrator.registerMigration("7: edits") { db in
            try db.alter(table: "asset") { t in
                // Light, colour, crop and trim as set by hand (JSON); applied when shown.
                t.add(column: "edit", .jsonText)
            }
        }
        migrator.registerMigration("8: small copies of videos") { db in
            try db.alter(table: "asset") { t in
                // The small copy to stream on the go, once the server has it.
                t.add(column: "streamSha256", .text)
            }
        }
        migrator.registerMigration("9: bursts") { db in
            try db.alter(table: "asset") { t in
                // Photos taken together in a burst share this id.
                t.add(column: "burstId", .text)
            }
            try db.create(index: "asset_by_burst", on: "asset", columns: ["burstId"])
        }
        migrator.registerMigration("10: live_effect") { db in
            try db.alter(table: "asset") { t in
                // Rendered Live Photo effect (Loop/Bounce MP4 or Long Exposure still) stored as derived file.
                t.add(column: "liveEffectSha256", .text)
                t.add(column: "liveEffectMime", .text)
            }
        }
        return migrator
    }
}

/// The server this device belongs to.
public struct StoredServer: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "server"
    public var serverId: String
    public var connection: ServerConnection
    public var syncSince: Int64
    public var backup: BackupState?

    public init(serverId: String, connection: ServerConnection, syncSince: Int64 = 0, backup: BackupState? = nil) {
        self.serverId = serverId
        self.connection = connection
        self.syncSince = syncSince
        self.backup = backup
    }
}

/// A photo or video, as this device knows it.
public struct LocalAsset: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "asset"
    public var id: String
    public var kind: String
    public var takenAt: Int64
    public var timeZoneOffsetMinutes: Int?
    public var width: Int?
    public var height: Int?
    public var title: String?
    public var localFile: String?
    public var mimeType: String?
    public var backedUp: Bool
    public var originalSha256: String?
    public var thumbnailSha256: String?
    public var previewSha256: String?
    public var seq: Int64?
    public var trashedAt: Int64?
    public var deletedAt: Int64?
    public var durationMs: Int64?
    public var description: String?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var locationAccuracy: Double?
    public var heading: Double?
    public var locationSource: String?
    public var origin: String?
    public var pairedVideoFile: String?
    public var pairedVideoSha256: String?
    /// `slowmo` or `timelapse` for videos taken that way.
    public var captureMode: String?
    /// The slow part of a slow-motion video, when it was changed; else the standard one.
    public var playback: SlowMotion?
    /// Light, colour, crop and trim as set by hand; the original stays as it is.
    public var edit: EditRecipe?
    /// A video's small copy, to stream on the go.
    public var streamSha256: String?
    /// Shared identifier for photos taken together in a burst.
    public var burstId: String?
    /// Rendered Live Photo effect (Loop/Bounce video or Long Exposure still) cached on the server.
    public var liveEffectSha256: String?
    public var liveEffectMime: String?

    public var isVideo: Bool { kind == "video" }
    public var isSlowMotion: Bool { isVideo && captureMode == "slowmo" }
    public var isTimeLapse: Bool { isVideo && captureMode == "timelapse" }
    public var isCinematic: Bool { isVideo && captureMode == "cinematic" }
    /// A photo with a short video, taken as one.
    public var isLivePhoto: Bool { !isVideo && (pairedVideoFile != nil || pairedVideoSha256 != nil) }
    public var activeLiveEffect: LivePhotoEffect { edit?.liveEffect ?? .live }
    public var hasLocation: Bool { latitude != nil && longitude != nil }
    /// The place was estimated (from a photo nearby in time or where the iPhone was), not measured
    /// for this file.
    public var hasEstimatedLocation: Bool { locationSource == "estimated" || locationSource == "device" }

    public init(
        id: String, kind: String, takenAt: Int64, timeZoneOffsetMinutes: Int? = nil,
        width: Int? = nil, height: Int? = nil, localFile: String? = nil, mimeType: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.takenAt = takenAt
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.width = width
        self.height = height
        self.localFile = localFile
        self.mimeType = mimeType
        self.backedUp = false
    }
}

/// One file waiting to go to the server (or on its way).
public struct UploadItem: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "upload"
    public var assetId: String
    /// `original`, or `paired_video` for a Live Photo's video.
    public var role = "original"
    public var file: String
    public var mimeType: String
    public var size: Int64
    public var sha256: String?
    public var metadata: UploadMetadata?
    public var uploadId: String?
    public var sent: Int64
    public var state: String
    public var attempts: Int
    public var lastError: String?
    public var retryAt: Int64
    public var createdAt: Int64

    /// One upload: an asset's file in one role.
    public var key: String { "\(assetId)|\(role)" }
}

/// A change made on this device, waiting for the server.
public struct PendingAction: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "action"
    public var id: Int64?
    public var kind: String
    public var assetIds: [String]
    /// The JSON body for `correct` and `locate`.
    public var payload: Data?
    public var createdAt: Int64
    public var attempts: Int
    public var lastError: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// An Apple Photos item that became a Halden asset (imported, or saved there from the camera).
public struct PhotosLink: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "photosLink"
    public var localIdentifier: String
    public var assetId: String
    public var linkedAt: Int64

    public init(localIdentifier: String, assetId: String, linkedAt: Int64) {
        self.localIdentifier = localIdentifier
        self.assetId = assetId
        self.linkedAt = linkedAt
    }
}

extension HaldenDatabase {
    /// A small value kept across launches.
    public func meta(_ key: String) throws -> Data? {
        try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public func setMeta(_ key: String, _ value: Data?) throws {
        try writer.write { db in
            try db.execute(
                sql:
                    "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                arguments: [key, value])
        }
    }

    public func server() throws -> StoredServer? {
        try writer.read { db in try StoredServer.fetchOne(db) }
    }

    public func save(server: StoredServer) throws {
        try writer.write { db in
            try StoredServer.deleteAll(db)
            try server.insert(db)
        }
    }

    /// Forgets the server (signing out): everything synced from it goes; photos taken here and
    /// not yet backed up stay, and their uploads wait for the next server.
    public func forgetServer() throws {
        try writer.write { db in
            try StoredServer.deleteAll(db)
            try db.execute(sql: "DELETE FROM asset WHERE localFile IS NULL")
            try db.execute(sql: "UPDATE asset SET backedUp = 0, seq = NULL")
            try db.execute(sql: "UPDATE upload SET uploadId = NULL, sent = 0, state = 'waiting'")
            // Changes meant for the old server don't apply to the next one.
            try db.execute(sql: "DELETE FROM action")
            try db.execute(sql: "DELETE FROM photosLink WHERE assetId NOT IN (SELECT id FROM asset)")
            try db.execute(sql: "DELETE FROM album")
        }
    }

    /// Photos and videos in the trash, most recently trashed first.
    public func trash() throws -> [LocalAsset] {
        try writer.read { db in
            try LocalAsset
                .filter(sql: "trashedAt IS NOT NULL AND deletedAt IS NULL")
                .order(sql: "trashedAt DESC, id")
                .fetchAll(db)
        }
    }

    /// What the grid shows: every photo that is neither in the trash nor deleted, newest first.
    public func library() throws -> [LocalAsset] {
        try writer.read { db in
            try LocalAsset
                .filter(sql: "trashedAt IS NULL AND deletedAt IS NULL")
                .order(sql: "takenAt DESC, id")
                .fetchAll(db)
        }
    }

    public func asset(_ id: String) throws -> LocalAsset? {
        try writer.read { db in try LocalAsset.fetchOne(db, key: id) }
    }

    /// Uploads not done yet.
    public func pendingUploads() throws -> [UploadItem] {
        try writer.read { db in
            try UploadItem.filter(sql: "state <> 'done'").order(sql: "createdAt").fetchAll(db)
        }
    }

    public func upload(_ assetId: String, role: String = "original") throws -> UploadItem? {
        try writer.read { db in try UploadItem.fetchOne(db, key: ["assetId": assetId, "role": role]) }
    }
}
