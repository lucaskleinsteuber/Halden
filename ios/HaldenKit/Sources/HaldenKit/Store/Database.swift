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
}

extension HaldenDatabase {
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

    public func upload(_ assetId: String) throws -> UploadItem? {
        try writer.read { db in try UploadItem.fetchOne(db, key: assetId) }
    }
}
