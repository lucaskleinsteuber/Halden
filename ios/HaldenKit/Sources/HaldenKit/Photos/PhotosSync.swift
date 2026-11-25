import Foundation
import GRDB
import UniformTypeIdentifiers

/// Keeps Halden and Apple Photos together:
/// - photos and videos added there (by Apple's camera, screenshots, other apps) come into Halden
///   and are uploaded, Live Photos with their video;
/// - deleted there, they go into Halden's trash, where they can be restored;
/// - photos taken with Halden are saved there too, linked so they never come back as new;
/// - deleting everywhere in Halden can delete them there too (the system asks);
/// - what was there before Halden can be imported, in pieces, going on where it stopped.
public actor PhotosSync {
    let library: any PhotoLibrary
    let database: HaldenDatabase
    let files: FileLocations
    /// While a photo is being saved there, the changes wait: the new item must be linked first.
    private var saving = 0

    static let tokenKey = "photosChangeToken"
    static let importKey = "photosImportedUpTo"
    static let existingScreenshotsKey = "screenshotsLocatedOnce"

    public init(library: any PhotoLibrary, database: HaldenDatabase, files: FileLocations) {
        self.library = library
        self.database = database
        self.files = files
    }

    /// Takes over what changed in Apple Photos since the last time. The first time it only notes
    /// where Apple Photos stands.
    @discardableResult
    public func takeOverChanges(
        settings: AppSettings, now: Date = Date(), currentPlace: (@Sendable () async -> PlaceReading?)? = nil
    ) async throws -> (added: Int, trashed: Int) {
        guard settings.importFromPhotos || settings.syncDeletionsWithPhotos, saving == 0, await library.mayRead()
        else { return (0, 0) }
        let changes = try await library.changes(since: try database.meta(Self.tokenKey))
        var added = 0
        if settings.importFromPhotos {
            let needsPlace = changes.added.contains {
                ScreenshotPlace.eligible($0, settings: settings)
                    && ScreenshotPlace.withinDeviceWindow($0, now: now, settings: settings)
            }
            let reading = needsPlace ? await currentPlace?() : nil
            for item in changes.added {
                if try await take(item, settings: settings, now: now, deviceReading: reading) { added += 1 }
            }
        }
        var trashed = 0
        if !changes.deleted.isEmpty {
            let ids = try links(for: changes.deleted)
            if settings.syncDeletionsWithPhotos, !ids.isEmpty {
                let showing = try notTrashed(ids)
                if !showing.isEmpty {
                    try Actions(database: database).trash(showing)
                    trashed = showing.count
                }
            }
            try unlink(identifiers: changes.deleted)
        }
        // Only now: should the app stop before, the same changes come again (and are skipped).
        try database.setMeta(Self.tokenKey, changes.token)
        return (added, trashed)
    }

    /// Imports what was in Apple Photos before, oldest first, `limit` at a time. Returns how many
    /// came in and whether everything is done.
    public func importExisting(
        limit: Int = 50, settings: AppSettings = AppSettings(), now: Date = Date(),
        currentPlace: (@Sendable () async -> PlaceReading?)? = nil
    ) async throws -> (imported: Int, done: Bool) {
        guard await library.mayRead() else { return (0, true) }
        let after = try database.meta(Self.importKey).flatMap { Double(String(decoding: $0, as: UTF8.self)) }
            .map { Date(timeIntervalSince1970: $0) }
        let items = try await library.items(after: after, limit: limit)
        let needsPlace = items.contains {
            ScreenshotPlace.eligible($0, settings: settings)
                && ScreenshotPlace.withinDeviceWindow($0, now: now, settings: settings)
        }
        let reading = needsPlace ? await currentPlace?() : nil
        var imported = 0
        for item in items {
            if try await take(item, settings: settings, now: now, deviceReading: reading) { imported += 1 }
            if let date = item.creationDate {
                try database.setMeta(Self.importKey, Data(String(date.timeIntervalSince1970).utf8))
            }
        }
        return (imported, items.count < limit)
    }

    /// Gives previously imported screenshots (and screen recordings, when enabled) without a place
    /// an estimated place from the nearest photo within two hours. Runs once; Apple Photos stays
    /// unchanged.
    @discardableResult
    public func locateExistingScreenshots(
        settings: AppSettings, client: APIClient? = nil, force: Bool = false
    ) async throws -> Int {
        guard settings.locateScreenshots, await library.mayRead() else { return 0 }
        if !force, try database.meta(Self.existingScreenshotsKey) != nil { return 0 }
        struct LinkedMissing: FetchableRecord, Decodable {
            var assetId: String
            var localIdentifier: String
            var takenAt: Int64
            var backedUp: Bool
        }
        let missing = try await database.writer.read { db in
            try LinkedMissing.fetchAll(
                db,
                sql: """
                    SELECT a.id AS assetId, l.localIdentifier, a.takenAt, a.backedUp
                    FROM asset a JOIN photosLink l ON l.assetId = a.id
                    WHERE a.latitude IS NULL AND a.trashedAt IS NULL AND a.deletedAt IS NULL
                    """)
        }
        let items = await library.items(withIdentifiers: missing.map(\.localIdentifier))
        let byIdentifier = Dictionary(uniqueKeysWithValues: items.map { ($0.localIdentifier, $0) })
        let actions = Actions(database: database)
        var located = 0
        for candidate in missing {
            guard let item = byIdentifier[candidate.localIdentifier],
                ScreenshotPlace.eligible(item, settings: settings)
            else { continue }
            var place: CorrectedLocation?
            if let client, candidate.backedUp,
                let suggestion = try? await client.locationSuggestion(for: candidate.assetId)
            {
                place = CorrectedLocation(
                    latitude: suggestion.latitude, longitude: suggestion.longitude, estimated: true)
            } else if let nearby = try ScreenshotPlace.nearestLocation(
                in: database, near: candidate.takenAt, excluding: candidate.assetId)
            {
                place = CorrectedLocation(
                    latitude: nearby.latitude, longitude: nearby.longitude, altitude: nearby.altitude, estimated: true)
            }
            if let place {
                try actions.correct(candidate.assetId, AssetCorrection(location: .set(place)))
                located += 1
            }
        }
        try database.setMeta(Self.existingScreenshotsKey, Data("1".utf8))
        return located
    }

    /// How far the import of the library from before got (`nil`: not started).
    public func importedUpTo() throws -> Date? {
        try database.meta(Self.importKey).flatMap { Double(String(decoding: $0, as: UTF8.self)) }
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// One item into Halden, unless it came in before: its files next to Halden's own, into the
    /// library and the upload queue, linked.
    func take(
        _ item: PhotoItem, settings: AppSettings = AppSettings(), now: Date = Date(),
        deviceReading: PlaceReading? = nil
    ) async throws -> Bool {
        if try isLinked(item.localIdentifier) { return false }
        let id = UUID().uuidString.lowercased()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exported = try await library.export(item, into: folder)
        guard let main = exported.first else { return false }
        let name = "\(id).\(Self.fileExtension(main))"
        try FileManager.default.moveItem(at: main.url, to: files.original(name))
        let estimated = try ScreenshotPlace.resolve(
            for: item, now: now, deviceReading: deviceReading, database: database, settings: settings)
        var metadata = UploadMetadata(
            takenAt: item.creationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
            timeZoneOffsetMinutes: nil, timeZone: nil, location: item.location ?? estimated, width: item.width,
            height: item.height, durationMs: item.durationMs, originalFilename: main.originalFilename)
        if let date = item.creationDate {
            // Apple Photos keeps the moment, not the zone: the zone of this iPhone then.
            metadata.timeZoneOffsetMinutes = TimeZone.current.secondsFromGMT(for: date) / 60
        }
        try Uploader.enqueue(
            database: database, files: files, assetId: id, fileName: name, kind: item.kind.rawValue,
            mimeType: main.mimeType, metadata: metadata, origin: "photos")
        if exported.count > 1 {
            let video = exported[1]
            let videoName = "\(id)-live.\(Self.fileExtension(video))"
            try FileManager.default.moveItem(at: video.url, to: files.original(videoName))
            try Uploader.enqueuePairedVideo(
                database: database, files: files, assetId: id, fileName: videoName, mimeType: video.mimeType)
        }
        try link(item.localIdentifier, to: id)
        return true
    }

    /// A photo or video taken with Halden goes into Apple Photos too.
    public func save(assetId: String, settings: AppSettings) async {
        guard settings.saveToPhotos, await library.mayAdd(),
            let asset = try? database.asset(assetId), let name = asset.localFile
        else { return }
        saving += 1
        defer { saving -= 1 }
        let paired = asset.pairedVideoFile.map { files.original($0) }
        guard
            let identifier = try? await library.save(
                files.original(name), kind: asset.isVideo ? .video : .photo, pairedVideo: paired)
        else { return }
        try? link(identifier, to: asset.id)
    }

    /// Deleted everywhere in Halden: from Apple Photos too, if they are there (the system asks
    /// the person). Returns whether something was deleted there.
    public func deleteInPhotos(assetIds: [String], settings: AppSettings) async -> Bool {
        guard settings.syncDeletionsWithPhotos, let identifiers = try? identifiers(of: assetIds), !identifiers.isEmpty
        else { return false }
        guard await library.delete(identifiers) else { return false }
        try? unlink(identifiers: identifiers)
        return true
    }

    /// Whether any of these assets are in Apple Photos too.
    public func inPhotos(_ assetIds: [String]) -> Bool {
        let count = try? database.writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT count(*) FROM photosLink WHERE assetId IN (SELECT value FROM json_each(?))",
                arguments: [Self.json(assetIds.map { $0.lowercased() })])
        }
        return (count ?? 0) > 0
    }

    // MARK: Links

    private func notTrashed(_ ids: [String]) throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM asset WHERE trashedAt IS NULL AND deletedAt IS NULL
                    AND id IN (SELECT value FROM json_each(?))
                    """, arguments: [Self.json(ids)])
        }
    }

    private func identifiers(of assetIds: [String]) throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT localIdentifier FROM photosLink WHERE assetId IN (SELECT value FROM json_each(?))",
                arguments: [Self.json(assetIds.map { $0.lowercased() })])
        }
    }

    private func isLinked(_ identifier: String) throws -> Bool {
        try database.writer.read { db in try PhotosLink.fetchOne(db, key: identifier) != nil }
    }

    private func link(_ identifier: String, to assetId: String) throws {
        let link = PhotosLink(
            localIdentifier: identifier, assetId: assetId, linkedAt: Int64(Date().timeIntervalSince1970 * 1000))
        try database.writer.write { db in try link.save(db) }
    }

    private func links(for identifiers: [String]) throws -> [String] {
        try database.writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT assetId FROM photosLink WHERE localIdentifier IN (SELECT value FROM json_each(?))",
                arguments: [Self.json(identifiers)])
        }
    }

    private func unlink(identifiers: [String]) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM photosLink WHERE localIdentifier IN (SELECT value FROM json_each(?))",
                arguments: [Self.json(identifiers)])
        }
    }

    static func json(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func fileExtension(_ file: ExportedFile) -> String {
        let fromName = (file.originalFilename as NSString?)?.pathExtension.lowercased() ?? ""
        if !fromName.isEmpty { return fromName }
        return UTType(mimeType: file.mimeType)?.preferredFilenameExtension ?? "bin"
    }
}
