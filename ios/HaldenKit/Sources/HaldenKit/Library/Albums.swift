import Foundation
import GRDB

/// An album as the server sends it.
public struct Album: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var coverAssetId: String?
    public var sortOrder: Int
    /// The photos in it, the most recently added first.
    public var assetIds: [String]
    public var seq: Int64
    public var deletedAt: Int64?
}

/// An album on this device.
public struct LocalAlbum: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "album"
    public var id: String
    public var name: String
    public var coverAssetId: String?
    public var sortOrder: Int
    public var createdAt: Int64
}

/// A photo in an album on this device.
public struct AlbumMember: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "albumAsset"
    public var albumId: String
    public var assetId: String
    public var addedAt: Int64
}

/// A change of an album, made here and waiting for the server (the photos it is about are the
/// action's `assetIds`).
public struct AlbumEdit: Codable, Sendable, Equatable {
    public enum Change: String, Codable, Sendable {
        case create, rename, cover, order, add, remove, delete
    }

    public var change: Change
    public var albumId: String
    public var name: String?
    public var coverAssetId: String?
    public var sortOrder: Int?
}

/// What the album list shows: an album with how many photos it has and its cover.
public struct AlbumSummary: Sendable, Equatable, Identifiable {
    public var album: LocalAlbum
    public var count: Int
    public var cover: LocalAsset?
    public var id: String { album.id }
}

extension HaldenDatabase {
    /// The albums, in their order, with the photos shown in them (not those in the trash).
    public func albums() throws -> [AlbumSummary] {
        try writer.read { db in try Self.albums(db) }
    }

    /// The albums, for observing them.
    public static func albums(_ db: Database) throws -> [AlbumSummary] {
        do {
            let albums = try LocalAlbum.order(sql: "sortOrder, name COLLATE NOCASE, id").fetchAll(db)
            return try albums.map { album in
                let count =
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT count(*) FROM albumAsset JOIN asset ON asset.id = albumAsset.assetId
                            WHERE albumAsset.albumId = ? AND asset.trashedAt IS NULL AND asset.deletedAt IS NULL
                            """, arguments: [album.id]) ?? 0
                var cover: LocalAsset?
                if let chosen = album.coverAssetId {
                    cover = try LocalAsset.filter(
                        sql: "id = ? AND trashedAt IS NULL AND deletedAt IS NULL", arguments: [chosen]
                    )
                    .fetchOne(db)
                }
                if cover == nil {
                    cover = try LocalAsset.fetchOne(
                        db,
                        sql: """
                            SELECT asset.* FROM asset JOIN albumAsset ON albumAsset.assetId = asset.id
                            WHERE albumAsset.albumId = ? AND asset.trashedAt IS NULL AND asset.deletedAt IS NULL
                            ORDER BY asset.takenAt DESC LIMIT 1
                            """, arguments: [album.id])
                }
                return AlbumSummary(album: album, count: count, cover: cover)
            }
        }
    }

    /// The photos of one album, newest first, like the library.
    public func photos(inAlbum id: String) throws -> [LocalAsset] {
        try writer.read { db in
            try LocalAsset.fetchAll(
                db,
                sql: """
                    SELECT asset.* FROM asset JOIN albumAsset ON albumAsset.assetId = asset.id
                    WHERE albumAsset.albumId = ? AND asset.trashedAt IS NULL AND asset.deletedAt IS NULL
                    ORDER BY asset.takenAt DESC, asset.id
                    """, arguments: [id.lowercased()])
        }
    }

    public func album(_ id: String) throws -> LocalAlbum? {
        try writer.read { db in try LocalAlbum.fetchOne(db, key: id.lowercased()) }
    }
}

extension Syncer {
    /// The server's state of an album, unless a change of it made here still waits.
    static func merge(_ album: Album, into db: Database, waiting: Set<String>) throws {
        let id = album.id.lowercased()
        guard !waiting.contains(id) else { return }
        if album.deletedAt != nil {
            _ = try LocalAlbum.deleteOne(db, key: id)
            return
        }
        let existing = try LocalAlbum.fetchOne(db, key: id)
        try LocalAlbum(
            id: id, name: album.name, coverAssetId: album.coverAssetId?.lowercased(), sortOrder: album.sortOrder,
            createdAt: existing?.createdAt ?? Actions.now()
        ).save(db)
        try db.execute(sql: "DELETE FROM albumAsset WHERE albumId = ?", arguments: [id])
        // Newest added first on the server: kept in that order.
        let now = Actions.now()
        for (index, assetId) in album.assetIds.enumerated() {
            try db.execute(
                sql: "INSERT OR IGNORE INTO albumAsset (albumId, assetId, addedAt) VALUES (?, ?, ?)",
                arguments: [id, assetId.lowercased(), now - Int64(index)])
        }
    }
}

extension Actions {
    /// Albums with changes made here that the server hasn't heard of yet.
    static func waitingAlbumIds(_ db: Database) throws -> Set<String> {
        let edits = try PendingAction.filter(Column("kind") == Kind.album.rawValue).fetchAll(db)
        return Set(
            edits.compactMap { action in
                action.payload.flatMap { try? JSONDecoder().decode(AlbumEdit.self, from: $0) }?.albumId
            })
    }

    /// A new album, with photos in it from the start. Returns its id.
    @discardableResult
    public func createAlbum(named name: String, with assetIds: [String] = []) throws -> String {
        let id = UUID().uuidString.lowercased()
        try edit(AlbumEdit(change: .create, albumId: id, name: name), assetIds) { db, ids, now in
            try LocalAlbum(id: id, name: name, coverAssetId: nil, sortOrder: 0, createdAt: now).insert(db)
            try Self.add(ids, to: id, db: db, now: now)
        }
        return id
    }

    public func renameAlbum(_ id: String, to name: String) throws {
        try edit(AlbumEdit(change: .rename, albumId: id, name: name), []) { db, _, _ in
            try db.execute(sql: "UPDATE album SET name = ? WHERE id = ?", arguments: [name, id.lowercased()])
        }
    }

    /// The photo on the cover; `nil` for the newest one.
    public func setCover(of id: String, to assetId: String?) throws {
        try edit(AlbumEdit(change: .cover, albumId: id, coverAssetId: assetId?.lowercased()), []) { db, _, _ in
            try db.execute(
                sql: "UPDATE album SET coverAssetId = ? WHERE id = ?",
                arguments: [assetId?.lowercased(), id.lowercased()])
        }
    }

    /// The albums in this order.
    public func orderAlbums(_ ids: [String]) throws {
        for (position, id) in ids.enumerated() {
            try edit(AlbumEdit(change: .order, albumId: id, sortOrder: position), []) { db, _, _ in
                try db.execute(
                    sql: "UPDATE album SET sortOrder = ? WHERE id = ?", arguments: [position, id.lowercased()])
            }
        }
    }

    public func addToAlbum(_ id: String, _ assetIds: [String]) throws {
        try edit(AlbumEdit(change: .add, albumId: id), assetIds) { db, ids, now in
            try Self.add(ids, to: id.lowercased(), db: db, now: now)
        }
    }

    public func removeFromAlbum(_ id: String, _ assetIds: [String]) throws {
        try edit(AlbumEdit(change: .remove, albumId: id), assetIds) { db, ids, _ in
            for assetId in ids {
                try db.execute(
                    sql: "DELETE FROM albumAsset WHERE albumId = ? AND assetId = ?",
                    arguments: [id.lowercased(), assetId])
            }
        }
    }

    /// The album goes; its photos stay.
    public func deleteAlbum(_ id: String) throws {
        try edit(AlbumEdit(change: .delete, albumId: id), []) { db, _, _ in
            _ = try LocalAlbum.deleteOne(db, key: id.lowercased())
        }
    }

    private static func add(_ assetIds: [String], to albumId: String, db: Database, now: Int64) throws {
        for assetId in assetIds {
            try db.execute(
                sql: "INSERT OR IGNORE INTO albumAsset (albumId, assetId, addedAt) VALUES (?, ?, ?)",
                arguments: [albumId, assetId, now])
        }
    }

    private func edit(
        _ edit: AlbumEdit, _ assetIds: [String], apply: @Sendable (Database, [String], Int64) throws -> Void
    ) throws {
        var edit = edit
        edit.albumId = edit.albumId.lowercased()
        try record(.album, assetIds, payload: try JSONEncoder().encode(edit), allowEmpty: true, apply: apply)
    }

    /// Sends one album change; photos still uploading wait for a later one.
    func performAlbum(_ action: PendingAction, client: APIClient) async throws {
        guard let payload = action.payload else { return }
        let edit = try JSONDecoder().decode(AlbumEdit.self, from: payload)
        let id = edit.albumId
        switch edit.change {
        case .create:
            _ = try await client.createAlbum(id: id, name: edit.name ?? "Album")
            if !action.assetIds.isEmpty { _ = try await client.addToAlbum(id, action.assetIds) }
        case .rename: _ = try await client.changeAlbum(id, name: edit.name)
        case .cover: _ = try await client.changeAlbum(id, cover: .some(edit.coverAssetId))
        case .order: _ = try await client.changeAlbum(id, sortOrder: edit.sortOrder)
        case .add: if !action.assetIds.isEmpty { _ = try await client.addToAlbum(id, action.assetIds) }
        case .remove: if !action.assetIds.isEmpty { _ = try await client.removeFromAlbum(id, action.assetIds) }
        case .delete: try await client.deleteAlbum(id)
        }
    }
}

extension APIClient {
    public func albums() async throws -> [Album] {
        struct List: Decodable { var albums: [Album] }
        let list: List = try await get("albums")
        return list.albums
    }

    public func createAlbum(id: String, name: String, assetIds: [String] = []) async throws -> Album {
        struct Body: Encodable {
            var id: String
            var name: String
            var assetIds: [String]
        }
        return try await call("POST", "albums", json: Body(id: id, name: name, assetIds: assetIds))
    }

    /// Name, cover (`.some(nil)`: the newest photo) or place in the list; what is `nil` stays.
    public func changeAlbum(
        _ id: String, name: String? = nil, cover: String?? = nil, sortOrder: Int? = nil
    ) async throws -> Album {
        struct Body: Encodable {
            var name: String?
            var cover: String??
            var sortOrder: Int?

            enum CodingKeys: String, CodingKey {
                case name, coverAssetId, sortOrder
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(name, forKey: .name)
                try container.encodeIfPresent(sortOrder, forKey: .sortOrder)
                if let cover {
                    if let cover {
                        try container.encode(cover, forKey: .coverAssetId)
                    } else {
                        try container.encodeNil(forKey: .coverAssetId)
                    }
                }
            }
        }
        return try await call("PATCH", "albums/\(id)", json: Body(name: name, cover: cover, sortOrder: sortOrder))
    }

    public func addToAlbum(_ id: String, _ assetIds: [String]) async throws -> Album {
        struct Body: Encodable { var assetIds: [String] }
        return try await call("POST", "albums/\(id)/assets", json: Body(assetIds: assetIds))
    }

    public func removeFromAlbum(_ id: String, _ assetIds: [String]) async throws -> Album {
        struct Body: Encodable { var assetIds: [String] }
        return try await call("DELETE", "albums/\(id)/assets", json: Body(assetIds: assetIds))
    }

    public func deleteAlbum(_ id: String) async throws {
        try await perform("DELETE", "albums/\(id)")
    }
}
