import Foundation
import GRDB

/// Brings the local library up to date with the server: only what changed since the last time,
/// page by page (`GET /sync`). Photos taken here keep their local file; what the server knows
/// (backed up, thumbnails, trash, corrections) is merged in.
public actor Syncer {
    let database: HaldenDatabase
    let client: APIClient

    public init(database: HaldenDatabase, client: APIClient) {
        self.database = database
        self.client = client
    }

    /// Returns how many assets changed.
    @discardableResult
    public func run() async throws -> Int {
        guard var server = try database.server() else { return 0 }
        var changed = 0
        while true {
            let page = try await client.sync(since: server.syncSince)
            if page.resetRequired == true {
                // Too long away: start from the beginning, keeping photos taken here.
                try await database.writer.write { db in
                    try db.execute(sql: "DELETE FROM asset WHERE localFile IS NULL")
                    try db.execute(sql: "DELETE FROM album")
                }
                server.syncSince = 0
                try database.save(server: server)
                continue
            }
            let next = page.nextSince
            try await database.writer.write { db in
                // A change made here that the server hasn't heard of yet wins until it has: the
                // asset comes again with a new number once the change arrived.
                let waiting = try Actions.waitingAssetIds(db)
                for asset in page.assets where !waiting.contains(asset.id.lowercased()) {
                    try Self.merge(asset, into: db)
                }
                let waitingAlbums = try Actions.waitingAlbumIds(db)
                for album in page.albums ?? [] {
                    try Self.merge(album, into: db, waiting: waitingAlbums)
                }
                try db.execute(sql: "UPDATE server SET syncSince = ?", arguments: [next])
            }
            server.syncSince = next
            changed += page.assets.count
            if !page.hasMore { return changed }
        }
    }

    public static func merge(_ asset: Asset, into db: Database) throws {
        let id = asset.id.lowercased()
        var local =
            try LocalAsset.fetchOne(db, key: id)
            ?? LocalAsset(id: id, kind: asset.kind, takenAt: asset.takenAt)
        local.kind = asset.kind
        local.takenAt = asset.takenAt
        local.timeZoneOffsetMinutes = asset.timeZoneOffsetMinutes
        local.width = asset.width ?? local.width
        local.height = asset.height ?? local.height
        local.title = asset.title
        local.description = asset.description
        local.durationMs = asset.durationMs ?? local.durationMs
        local.latitude = asset.location?.latitude
        local.longitude = asset.location?.longitude
        local.altitude = asset.location?.altitude
        local.locationAccuracy = asset.location?.accuracyMeters
        local.heading = asset.location?.heading
        local.locationSource = asset.location?.source
        local.seq = asset.seq
        local.trashedAt = asset.trashedAt
        local.deletedAt = asset.deletedAt
        if let original = asset.file("original") {
            local.backedUp = true
            local.originalSha256 = original.sha256
            local.mimeType = local.mimeType ?? original.mimeType
        }
        local.thumbnailSha256 = asset.file("thumbnail")?.sha256 ?? local.thumbnailSha256
        local.previewSha256 = asset.file("preview")?.sha256 ?? local.previewSha256
        local.pairedVideoSha256 = asset.file("paired_video")?.sha256 ?? local.pairedVideoSha256
        local.captureMode = asset.captureMode ?? local.captureMode
        local.playback = asset.playback
        local.edit = asset.edit
        local.streamSha256 = asset.file("stream")?.sha256 ?? local.streamSha256
        try local.save(db)
    }
}
