import Foundation
import GRDB

/// How far the current round of uploads is: "12 of 40".
public struct UploadSummary: Sendable, Equatable, Codable {
    /// Finished in this round.
    public var done: Int
    /// In this round: everything added since the queue was last empty.
    public var total: Int
    /// Given up (the server won't take them); shown, not counted as waiting.
    public var failed: Int
    public var bytesSent: Int64
    public var bytesTotal: Int64

    public init(done: Int = 0, total: Int = 0, failed: Int = 0, bytesSent: Int64 = 0, bytesTotal: Int64 = 0) {
        self.done = done
        self.total = total
        self.failed = failed
        self.bytesSent = bytesSent
        self.bytesTotal = bytesTotal
    }

    public var waiting: Int { total - done - failed }
}

extension HaldenDatabase {
    public func uploadSummary() throws -> UploadSummary {
        try writer.read { db in
            let round = try String.fetchOne(db, sql: "SELECT CAST(value AS TEXT) FROM meta WHERE key = 'uploadRound'")
            guard
                let start = try round.flatMap({ Int64($0) })
                    ?? Int64.fetchOne(
                        db, sql: "SELECT min(createdAt) FROM upload WHERE state <> 'done' AND state <> 'failed'")
            else { return UploadSummary() }
            // Counted in photos and videos: a Live Photo is one, though it is two files.
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT count(*) AS total, sum(done) AS done, sum(failed) AS failed,
                           sum(sent) AS sent, sum(size) AS size
                    FROM (SELECT min(state = 'done') AS done,
                                 max(state = 'failed') AS failed,
                                 sum(CASE WHEN state = 'done' THEN size ELSE sent END) AS sent,
                                 sum(size) AS size
                          FROM upload WHERE createdAt >= ? AND role <> 'stream' GROUP BY assetId)
                    """, arguments: [start])
            return UploadSummary(
                done: row?["done"] ?? 0, total: row?["total"] ?? 0, failed: row?["failed"] ?? 0,
                bytesSent: row?["sent"] ?? 0, bytesTotal: row?["size"] ?? 0)
        }
    }
}

extension Uploader {
    /// Tries an upload again now, also one that was given up.
    public static func retry(_ assetId: String, database: HaldenDatabase) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE upload SET state = CASE WHEN state = 'failed' THEN 'waiting' ELSE state END,
                                      retryAt = 0, attempts = 0
                    WHERE assetId = ? AND state <> 'done'
                    """, arguments: [assetId.lowercased()])
        }
    }
}

/// The originals on this iPhone. Once one is safely on the server (its hash checked there, the
/// thumbnail and preview here), the phone's copy may go: by the setting "keep copies on this
/// iPhone" turned off, or by "Remove from this iPhone". The original is then fetched from the
/// server when it is needed.
public enum LocalCopies {
    /// Removes the phone's copy of these assets (all, with `nil`) where it is safe. Returns how
    /// many were removed.
    @discardableResult
    public static func remove(_ ids: [String]? = nil, database: HaldenDatabase, files: FileLocations) throws -> Int {
        let candidates = try database.writer.read { db in
            var request = LocalAsset.filter(
                sql: """
                    localFile IS NOT NULL AND backedUp = 1 AND originalSha256 IS NOT NULL
                    AND thumbnailSha256 IS NOT NULL AND previewSha256 IS NOT NULL
                    AND id NOT IN (SELECT assetId FROM upload WHERE state <> 'done')
                    """)
            if let ids { request = request.filter(keys: ids.map { $0.lowercased() }) }
            return try request.fetchAll(db)
        }
        var removed = 0
        for asset in candidates {
            guard let name = asset.localFile, let thumbnail = asset.thumbnailSha256,
                let preview = asset.previewSha256,
                FileManager.default.fileExists(atPath: files.thumbnail(sha256: thumbnail).path),
                FileManager.default.fileExists(atPath: files.thumbnail(sha256: preview).path)
            else { continue }
            // The database first: should the app stop in between, a file nobody points at only
            // wastes space, while a row pointing at a removed file would be wrong.
            let others = try database.writer.write { db in
                try db.execute(
                    sql: "UPDATE asset SET localFile = NULL, pairedVideoFile = NULL WHERE id = ? AND localFile = ?",
                    arguments: [asset.id, name])
                // A Live Photo's video goes with its photo.
                return try String.fetchAll(
                    db, sql: "SELECT file FROM upload WHERE assetId = ? AND role <> 'original'", arguments: [asset.id])
            }
            try? FileManager.default.removeItem(at: files.original(name))
            for other in others { try? FileManager.default.removeItem(at: files.original(other)) }
            removed += 1
        }
        return removed
    }

    /// How many photos and videos have their original on this iPhone, and how much space they take.
    public static func usage(database: HaldenDatabase, files: FileLocations) throws -> (count: Int, bytes: Int64) {
        let names = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT localFile FROM asset WHERE localFile IS NOT NULL")
        }
        var bytes: Int64 = 0
        for name in names {
            let size = try? FileManager.default.attributesOfItem(atPath: files.original(name).path)[.size] as? Int64
            bytes += size ?? 0
        }
        return (names.count, bytes)
    }
}
