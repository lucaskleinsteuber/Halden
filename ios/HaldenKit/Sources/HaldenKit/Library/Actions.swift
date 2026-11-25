import Foundation
import GRDB

/// Changes made on this device: moving to the trash, restoring, deleting for good, corrections and
/// places. Each one shows here at once and goes to the server in the order it was made, as soon as
/// the server can be reached. The server takes every one of them twice without harm, so a change
/// sent again after a broken connection does nothing wrong.
public struct Actions: Sendable {
    public enum Kind: String, Sendable {
        case trash, restore, delete, correct, locate, album
    }

    /// How sending went.
    public enum Outcome: Sendable, Equatable {
        /// Everything that could go, went (some may wait for their photo's upload).
        case done
        /// The server can't take more right now; the rest waits for the next try.
        case later
        /// The device was signed out.
        case signedOut
    }

    /// After this many tries that failed for unclear reasons, a change is given up.
    static let maxAttempts = 10

    let database: HaldenDatabase

    public init(database: HaldenDatabase) {
        self.database = database
    }

    // MARK: Making changes

    /// Moves to the trash.
    public func trash(_ ids: [String]) throws {
        try record(.trash, ids) { db, ids, now in
            try LocalAsset.filter(keys: ids).filter(sql: "trashedAt IS NULL AND deletedAt IS NULL")
                .updateAll(db, Column("trashedAt").set(to: now))
        }
    }

    /// Takes out of the trash.
    public func restore(_ ids: [String]) throws {
        try record(.restore, ids) { db, ids, _ in
            try LocalAsset.filter(keys: ids).filter(sql: "trashedAt IS NOT NULL AND deletedAt IS NULL")
                .updateAll(db, Column("trashedAt").set(to: nil))
        }
    }

    /// Deletes for good; only what is in the trash.
    public func deleteForGood(_ ids: [String]) throws {
        try record(.delete, ids) { db, ids, now in
            try LocalAsset.filter(keys: ids).filter(sql: "trashedAt IS NOT NULL AND deletedAt IS NULL")
                .updateAll(db, Column("deletedAt").set(to: now))
        }
    }

    /// Corrects time, place, title or description of one asset.
    public func correct(_ id: String, _ correction: AssetCorrection) throws {
        let payload = try JSONEncoder().encode(correction)
        try record(.correct, [id], payload: payload) { db, ids, _ in
            guard let id = ids.first, var asset = try LocalAsset.fetchOne(db, key: id) else { return }
            if case .set(let takenAt) = correction.takenAt { asset.takenAt = takenAt }
            switch correction.timeZoneOffsetMinutes {
            case .set(let offset): asset.timeZoneOffsetMinutes = offset
            case .clear: asset.timeZoneOffsetMinutes = nil
            case .keep: break
            }
            switch correction.location {
            case .set(let location): Self.place(location, on: &asset)
            case .clear: Self.place(nil, on: &asset)
            case .keep: break
            }
            switch correction.title {
            case .set(let title): asset.title = title
            case .clear: asset.title = nil
            case .keep: break
            }
            switch correction.description {
            case .set(let description): asset.description = description
            case .clear: asset.description = nil
            case .keep: break
            }
            switch correction.playback {
            case .set(let playback): asset.playback = playback
            case .clear: asset.playback = nil
            case .keep: break
            }
            switch correction.edit {
            case .set(let edit): asset.edit = edit
            case .clear: asset.edit = nil
            case .keep: break
            }
            try asset.update(db)
        }
    }

    /// One place for many photos (the "without location" view).
    public func setLocation(_ ids: [String], _ location: CorrectedLocation) throws {
        let payload = try JSONEncoder().encode(location)
        try record(.locate, ids, payload: payload) { db, ids, _ in
            for var asset in try LocalAsset.fetchAll(db, keys: ids) {
                Self.place(location, on: &asset)
                try asset.update(db)
            }
        }
    }

    static func place(_ location: CorrectedLocation?, on asset: inout LocalAsset) {
        asset.latitude = location?.latitude
        asset.longitude = location?.longitude
        asset.altitude = location?.altitude
        asset.locationAccuracy = nil
        asset.heading = nil
        asset.locationSource = location?.resolvedSource
    }

    func record(
        _ kind: Kind, _ ids: [String], payload: Data? = nil, allowEmpty: Bool = false,
        apply: @Sendable (Database, [String], Int64) throws -> Void
    ) throws {
        let ids = ids.map { $0.lowercased() }
        guard !ids.isEmpty || allowEmpty else { return }
        let now = Self.now()
        try database.writer.write { db in
            try apply(db, ids, now)
            var action = PendingAction(
                id: nil, kind: kind.rawValue, assetIds: ids, payload: payload, createdAt: now, attempts: 0,
                lastError: nil)
            try action.insert(db)
        }
    }

    static func now() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: Sending

    /// Changes not sent yet, oldest first.
    public func pending() throws -> [PendingAction] {
        try database.writer.read { db in try PendingAction.order(Column("id")).fetchAll(db) }
    }

    /// Ids of assets with changes not sent yet: the sync leaves them as they are here.
    static func waitingAssetIds(_ db: Database) throws -> Set<String> {
        Set(try PendingAction.fetchAll(db).flatMap(\.assetIds))
    }

    /// Sends what is waiting, oldest first. The server doesn't know a photo whose upload hasn't
    /// finished, so a change for it waits, and so does every later change of that photo; the
    /// other photos of the same change go now. A change the server refuses for good is dropped, and
    /// its assets are fetched again so this device shows what the server has.
    @discardableResult
    public func send(with client: APIClient) async -> Outcome {
        guard let actions = try? pending() else { return .later }
        // Photos whose earlier changes are still waiting: their later changes wait too.
        var held = Set<String>()
        for original in actions {
            guard let id = original.id else { continue }
            var action = original
            let uploading = (try? stillUploading(action.assetIds)) ?? Set(action.assetIds)
            let waiting = action.assetIds.filter { held.contains($0) || uploading.contains($0) }
            if !waiting.isEmpty {
                held.formUnion(waiting)
                let ready = action.assetIds.filter { !waiting.contains($0) }
                // One asset's correction can't be split; several photos' changes can. An album
                // change goes with the photos that are there (even none: the album is made).
                let album = Kind(rawValue: action.kind) == .album
                guard album || (!ready.isEmpty && Kind(rawValue: action.kind) != .correct) else { continue }
                action.assetIds = ready
            }
            do {
                try await perform(action, client: client)
                _ = try? await database.writer.write { db in
                    if waiting.isEmpty {
                        _ = try PendingAction.deleteOne(db, key: id)
                    } else {
                        try db.execute(
                            sql: "UPDATE action SET assetIds = ? WHERE id = ?",
                            arguments: [String(decoding: try JSONEncoder().encode(waiting), as: UTF8.self), id])
                    }
                }
            } catch let error as APIError {
                if case .unreachable = error { return .later }
                if error.signedOut { return .signedOut }
                let status = error.status ?? 0
                let transient = status >= 500 || status == 408 || status == 429 || status == 0
                if transient && action.attempts + 1 < Self.maxAttempts {
                    try? note(action, error: error)
                    return .later
                }
                await giveUp(original, error: error, client: client)
            } catch {
                try? note(action, error: error)
                return .later
            }
        }
        return .done
    }

    private func perform(_ action: PendingAction, client: APIClient) async throws {
        switch Kind(rawValue: action.kind) {
        case .trash: _ = try await client.trash(action.assetIds)
        case .restore: _ = try await client.restore(action.assetIds)
        case .delete: _ = try await client.deleteForGood(action.assetIds)
        case .correct:
            guard let id = action.assetIds.first, let payload = action.payload else { return }
            let correction = try JSONDecoder().decode(AssetCorrection.self, from: payload)
            let asset = try await client.correct(id, correction)
            try await merge([asset], except: action.id)
        case .locate:
            guard let payload = action.payload else { return }
            let location = try JSONDecoder().decode(CorrectedLocation.self, from: payload)
            _ = try await client.setLocation(action.assetIds, location)
        case .album:
            try await performAlbum(action, client: client)
        case nil:
            break
        }
    }

    /// Which of these photos are still on their way to the server.
    private func stillUploading(_ ids: [String]) throws -> Set<String> {
        try database.writer.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT asset.id FROM asset JOIN upload ON upload.assetId = asset.id
                        WHERE asset.backedUp = 0 AND asset.id IN (SELECT value FROM json_each(?))
                        """,
                    arguments: [String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)]))
        }
    }

    private func note(_ action: PendingAction, error: Error) throws {
        guard let id = action.id else { return }
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE action SET attempts = attempts + 1, lastError = ? WHERE id = ?",
                arguments: [error.localizedDescription, id])
        }
    }

    /// The server refused the change for good: drop it and show what the server has.
    private func giveUp(_ action: PendingAction, error: Error, client: APIClient) async {
        guard let id = action.id else { return }
        _ = try? await database.writer.write { db in try PendingAction.deleteOne(db, key: id) }
        // An album change: the album as the server has it (or none).
        if Kind(rawValue: action.kind) == .album, let payload = action.payload,
            let edit = try? JSONDecoder().decode(AlbumEdit.self, from: payload)
        {
            let album: Album? = try? await client.get("albums/\(edit.albumId)")
            _ = try? await database.writer.write { db in
                if let album {
                    try Syncer.merge(album, into: db, waiting: try Self.waitingAlbumIds(db))
                } else {
                    _ = try LocalAlbum.deleteOne(db, key: edit.albumId)
                }
            }
            return
        }
        var fresh: [Asset] = []
        for assetId in action.assetIds {
            if let asset = try? await client.asset(assetId) { fresh.append(asset) }
        }
        try? await merge(fresh, except: nil)
    }

    /// Takes the server's state of these assets, unless another change of them still waits.
    private func merge(_ assets: [Asset], except actionId: Int64?) async throws {
        try await database.writer.write { db in
            var waiting = Set<String>()
            for action in try PendingAction.fetchAll(db) where action.id != actionId {
                waiting.formUnion(action.assetIds)
            }
            for asset in assets where !waiting.contains(asset.id.lowercased()) {
                try Syncer.merge(asset, into: db)
            }
        }
    }
}
