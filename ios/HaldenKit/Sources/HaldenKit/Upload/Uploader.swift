import Foundation
import GRDB

/// Sends what was taken on this phone to the server, one file at a time, oldest first. The queue
/// is in the database, so it survives the app being closed or the phone restarting. A file goes
/// in pieces (8 MiB); after a break it continues where the server stands, never from the start.
/// When the original is safely on the server (its SHA-256 checked there), the phone sends the
/// thumbnail and preview it made itself.
public actor Uploader {
    let database: HaldenDatabase
    let files: FileLocations
    let client: APIClient
    let pieceSize: Int

    public init(database: HaldenDatabase, files: FileLocations, client: APIClient, pieceSize: Int = 8 << 20) {
        self.database = database
        self.files = files
        self.client = client
        self.pieceSize = pieceSize
    }

    /// Takes a photo or video (already written to `files.originals`) into the library and the
    /// queue. `origin` says where it came from (`camera` for Halden's own).
    public static func enqueue(
        database: HaldenDatabase, files: FileLocations, assetId: String, fileName: String,
        kind: String, mimeType: String, metadata: UploadMetadata, origin: String? = "camera"
    ) throws {
        let size = try FileManager.default.attributesOfItem(atPath: files.original(fileName).path)[.size] as? Int64 ?? 0
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var asset = LocalAsset(
            id: assetId.lowercased(), kind: kind, takenAt: metadata.takenAt ?? now,
            timeZoneOffsetMinutes: metadata.timeZoneOffsetMinutes, width: metadata.width,
            height: metadata.height, localFile: fileName, mimeType: mimeType)
        asset.backedUp = false
        asset.durationMs = metadata.durationMs
        asset.origin = origin
        asset.captureMode = kind == "video" ? metadata.captureMode : nil
        asset.burstId = kind == "photo" ? metadata.burstId : nil
        if let place = metadata.location {
            asset.latitude = place.latitude
            asset.longitude = place.longitude
            asset.altitude = place.altitude
            asset.locationAccuracy = place.horizontalAccuracy
            asset.heading = place.heading
            asset.locationSource = place.source ?? "client"
        }
        let item = UploadItem(
            assetId: asset.id, file: fileName, mimeType: mimeType, size: size, sha256: nil,
            metadata: metadata, uploadId: nil, sent: 0, state: "waiting", attempts: 0,
            lastError: nil, retryAt: 0, createdAt: now)
        try database.writer.write { db in
            // A new round of uploads starts when nothing was waiting: "1 of 1", not "41 of 41".
            if try UploadItem.filter(sql: "state <> 'done' AND state <> 'failed'").fetchCount(db) == 0 {
                try db.execute(
                    sql: """
                        INSERT INTO meta (key, value) VALUES ('uploadRound', ?)
                        ON CONFLICT (key) DO UPDATE SET value = excluded.value
                        """, arguments: [Data(String(now).utf8)])
            }
            try asset.insert(db)
            try item.insert(db)
        }
    }

    /// The video of a Live Photo (already written to `files.originals`), sent after its photo.
    public static func enqueuePairedVideo(
        database: HaldenDatabase, files: FileLocations, assetId: String, fileName: String, mimeType: String
    ) throws {
        let size = try FileManager.default.attributesOfItem(atPath: files.original(fileName).path)[.size] as? Int64 ?? 0
        let item = UploadItem(
            assetId: assetId.lowercased(), role: "paired_video", file: fileName, mimeType: mimeType, size: size,
            sha256: nil, metadata: nil, uploadId: nil, sent: 0, state: "waiting", attempts: 0, lastError: nil,
            retryAt: 0, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        try database.writer.write { db in
            try item.insert(db)
            try db.execute(
                sql: "UPDATE asset SET pairedVideoFile = ? WHERE id = ?", arguments: [fileName, assetId.lowercased()])
        }
    }

    /// The Bayer DNG companion of a RAW+HEIC/JPEG capture, sent after its processed original.
    public static func enqueueRaw(
        database: HaldenDatabase, files: FileLocations, assetId: String, fileName: String,
        mimeType: String = "image/x-adobe-dng"
    ) throws {
        let size = try FileManager.default.attributesOfItem(atPath: files.original(fileName).path)[.size] as? Int64 ?? 0
        let item = UploadItem(
            assetId: assetId.lowercased(), role: "raw", file: fileName, mimeType: mimeType, size: size,
            sha256: nil, metadata: nil, uploadId: nil, sent: 0, state: "waiting", attempts: 0, lastError: nil,
            retryAt: 0, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        try database.writer.write { db in try item.insert(db) }
    }

    /// Works through every due upload. Returns how many finished; stops early when the server
    /// can't be reached (the next call continues). `skipping`: uploads the system is sending in
    /// the background right now (by `UploadItem.key`).
    @discardableResult
    public func drain(permit: UploadPermit = .all, skipping: Set<String> = []) async -> Int {
        var finished = 0
        while let item = nextDue(permit: permit, skipping: skipping) {
            do {
                try await process(item)
                finished += 1
            } catch {
                // Stopped on purpose (the app went to the background): not a failed try.
                if Task.isCancelled { break }
                failed(item, error)
                if case APIError.unreachable = error { break }
                if (error as? APIError)?.signedOut == true { break }
            }
            if Task.isCancelled { break }
        }
        return finished
    }

    /// The oldest upload that is due and may go now (videos may have to wait for Wi-Fi).
    func nextDue(permit: UploadPermit, skipping: Set<String> = []) -> UploadItem? {
        guard permit.any else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let skipped = String(decoding: (try? JSONEncoder().encode(Array(skipping))) ?? Data("[]".utf8), as: UTF8.self)
        return try? database.writer.read { db in
            try UploadItem
                .filter(sql: "state <> 'done' AND state <> 'failed' AND retryAt <= ?", arguments: [now])
                .filter(sql: "(assetId || '|' || role) NOT IN (SELECT value FROM json_each(?))", arguments: [skipped])
                // A Live Photo's video goes once its photo is on the server.
                .filter(
                    sql: """
                        role = 'original' OR NOT EXISTS (
                            SELECT 1 FROM upload AS photo WHERE photo.assetId = upload.assetId
                            AND photo.role = 'original' AND photo.state NOT IN ('thumbnails', 'done'))
                        """
                )
                .filter(
                    sql: "(mimeType LIKE 'video/%' AND ?) OR (mimeType NOT LIKE 'video/%' AND ?)",
                    arguments: [permit.videos, permit.photos]
                )
                .order(sql: "createdAt")
                .fetchOne(db)
        }
    }

    private func save(_ item: UploadItem) throws {
        try database.writer.write { db in try item.update(db) }
    }

    private func failed(_ item: UploadItem, _ error: Error) {
        var item = (try? database.upload(item.assetId, role: item.role)) ?? item
        item.attempts += 1
        item.lastError = error.localizedDescription
        let waits: [Int64] = [5, 30, 120, 600, 3600]
        let wait = waits[min(item.attempts - 1, waits.count - 1)]
        item.retryAt = Int64(Date().timeIntervalSince1970 * 1000) + wait * 1000
        // A file the server will never take (wrong type, too big for it) stops trying.
        if let api = error as? APIError, let status = api.status, [413, 415].contains(status) {
            item.state = "failed"
        } else if item.state == "sending" {
            item.state = "waiting"
        }
        try? save(item)
    }

    func process(_ start: UploadItem) async throws {
        var item = start
        let url = files.original(item.file)
        if item.state == "thumbnails" {
            try await sendThumbnails(item, url: url, asset: nil)
            return
        }
        guard let ready = try await ready(item) else { return }
        item = ready
        guard let id = item.uploadId else { throw APIError.unexpected("no upload id") }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while item.sent < item.size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(item.sent))
            let piece = try handle.read(upToCount: pieceSize) ?? Data()
            if piece.isEmpty { throw APIError.unexpected("the file is shorter than announced") }
            do {
                let state = try await client.send(upload: id, offset: item.sent, piece: piece)
                if state.state == "completed" {
                    try await finished(item, url: url, asset: state.asset)
                    return
                }
                // Another device sent the same photo while this one was on its way.
                if state.state == "duplicate" {
                    try duplicate(item, existing: state.existingAssetId)
                    return
                }
                item.sent = state.offset ?? (item.sent + Int64(piece.count))
                try save(item)
            } catch APIError.server(409, "offset_mismatch", _, let offset?) {
                item.sent = offset
                try save(item)
            }
        }
        // Everything arrived, but the answer to the last piece was lost: ask to finish.
        let state = try await client.complete(upload: id)
        if state.state == "duplicate" {
            try duplicate(item, existing: state.existingAssetId)
            return
        }
        try await finished(item, url: url, asset: state.asset)
    }

    /// Gets an upload ready for its bytes: hashed, announced, and where the server stands. `nil`
    /// when nothing is left to send (the server has it already, or it is a duplicate; both are
    /// dealt with here).
    func ready(_ start: UploadItem) async throws -> UploadItem? {
        var item = start
        let url = files.original(item.file)
        if item.sha256 == nil {
            item.sha256 = try Hashing.sha256(of: url)
            try save(item)
        }
        if item.state == "thumbnails" { return nil }
        item.state = "sending"
        try save(item)

        if let id = item.uploadId {
            do {
                let state = try await client.uploadState(id)
                if state.state == "completed" {
                    try await finished(item, url: url, asset: state.asset)
                    return nil
                }
                if state.state == "duplicate" {
                    try duplicate(item, existing: state.existingAssetId)
                    return nil
                }
                item.sent = state.offset ?? 0
            } catch let error as APIError where [404, 410].contains(error.status ?? 0) {
                // The server forgot the upload (expired, or it failed): announce it again.
                item.uploadId = nil
                item.sent = 0
            }
            try save(item)
        }
        if item.uploadId == nil {
            let state = try await client.announce(
                UploadRequest(
                    assetId: item.assetId, role: item.role, size: item.size,
                    sha256: item.sha256 ?? "", mimeType: item.mimeType, metadata: item.metadata))
            switch state.state {
            case "completed":
                try await finished(item, url: url, asset: state.asset)
                return nil
            case "duplicate":
                try duplicate(item, existing: state.existingAssetId)
                return nil
            default:
                item.uploadId = state.uploadId
                item.sent = state.offset ?? 0
                try save(item)
            }
        }
        return item
    }

    /// The original is on the server, checked by its hash.
    private func finished(_ start: UploadItem, url: URL, asset: Asset?) async throws {
        let item = try Self.onServer(start, seq: asset?.seq, database: database)
        try await sendThumbnails(item, url: url, asset: asset)
    }

    /// Notes that the server has the original (checked by its hash); the thumbnails come next.
    @discardableResult
    static func onServer(_ start: UploadItem, seq: Int64?, database: HaldenDatabase) throws -> UploadItem {
        var item = start
        // A Live Photo's video needs no thumbnails; the photo is what shows.
        item.state = item.role == "original" ? "thumbnails" : "done"
        item.lastError = nil
        let done = item
        try database.writer.write { db in
            try done.update(db)
            if done.role == "original" {
                try db.execute(
                    sql: "UPDATE asset SET backedUp = 1, originalSha256 = ?, seq = coalesce(?, seq) WHERE id = ?",
                    arguments: [done.sha256, seq, done.assetId])
            }
        }
        return item
    }

    /// Makes and sends the thumbnail and preview, unless the server has them already.
    private func sendThumbnails(_ start: UploadItem, url: URL, asset: Asset?) async throws {
        guard start.role == "original" else { return }
        var item = start
        var thumbnailSha = asset?.file("thumbnail")?.sha256
        var previewSha = asset?.file("preview")?.sha256
        if item.mimeType.hasPrefix("image/") || item.mimeType.hasPrefix("video/") {
            for (role, edge) in [("thumbnail", Thumbnails.thumbnailEdge), ("preview", Thumbnails.previewEdge)] {
                if (role == "thumbnail" ? thumbnailSha : previewSha) != nil { continue }
                guard let made = await Thumbnails.picture(of: url, edge: edge) else { continue }
                _ = try await client.put(
                    file: made.data, role: role, asset: item.assetId, mimeType: "image/jpeg",
                    sha256: made.sha256, width: made.width, height: made.height)
                // Shown in the grid right away, without asking the server.
                try? made.data.write(to: files.thumbnail(sha256: made.sha256), options: .atomic)
                if role == "thumbnail" { thumbnailSha = made.sha256 } else { previewSha = made.sha256 }
            }
        }
        item.state = "done"
        let done = item
        let (thumbnail, preview) = (thumbnailSha, previewSha)
        try await database.writer.write { db in
            try done.update(db)
            try db.execute(
                sql:
                    "UPDATE asset SET thumbnailSha256 = coalesce(?, thumbnailSha256), previewSha256 = coalesce(?, previewSha256) WHERE id = ?",
                arguments: [thumbnail, preview, done.assetId])
        }
    }

    private func duplicate(_ item: UploadItem, existing: String?) throws {
        try Self.duplicate(item, existing: existing, database: database)
    }

    /// The same photo is on the server already under another id: this one is that one.
    static func duplicate(_ item: UploadItem, existing: String?, database: HaldenDatabase) throws {
        if item.role != "original" {
            // The same video is stored already: nothing more to send.
            var done = item
            done.state = "done"
            try database.writer.write { db in try done.update(db) }
            return
        }
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM upload WHERE assetId = ?", arguments: [item.assetId])
            guard let existing = existing?.lowercased(), existing != item.assetId else {
                try db.execute(sql: "UPDATE asset SET backedUp = 1 WHERE id = ?", arguments: [item.assetId])
                return
            }
            if try LocalAsset.fetchOne(db, key: existing) != nil {
                try db.execute(
                    sql: "UPDATE asset SET localFile = coalesce(localFile, ?), backedUp = 1 WHERE id = ?",
                    arguments: [item.file, existing])
                try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [item.assetId])
            } else {
                try db.execute(
                    sql: "UPDATE asset SET id = ?, backedUp = 1, originalSha256 = ? WHERE id = ?",
                    arguments: [existing, item.sha256, item.assetId])
            }
        }
    }
}
