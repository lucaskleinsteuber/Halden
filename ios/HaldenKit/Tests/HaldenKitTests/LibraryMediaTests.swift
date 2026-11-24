import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HaldenKit

@Suite struct ExportTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A JPEG with a place in it, like a photo from a phone.
    func photoWithPlace(at url: URL) throws {
        let data = try #require(SampleMedia.photo(seed: 21, width: 120, height: 90))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 10.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 20.0, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func aPhotoCarriesItsCorrections() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("p.jpg")
        try photoWithPlace(at: original)
        let out = root.appendingPathComponent("out.jpg")
        let facts = Export.Facts(
            takenAt: Date(timeIntervalSince1970: 1_800_000_000), timeZoneOffsetMinutes: 120,
            location: ClientLocation(latitude: -33.5, longitude: 151.25, altitude: 12),
            title: "Harbour", description: "Evening walk")
        try Export.photo(original, to: out, facts: facts)
        let written = try properties(out)
        let gps = try #require(written[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(gps[kCGImagePropertyGPSLatitude] as? Double == 33.5)
        #expect(gps[kCGImagePropertyGPSLatitudeRef] as? String == "S")
        #expect(gps[kCGImagePropertyGPSLongitude] as? Double == 151.25)
        let exif = try #require(written[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2027:01:15 10:00:00")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+02:00")
        let iptc = try #require(written[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        #expect(iptc[kCGImagePropertyIPTCObjectName] as? String == "Harbour")
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String == "Evening walk")
        #expect(written[kCGImagePropertyPixelWidth] as? Int == 120)
    }

    /// A place that was removed is not in the copy either.
    @Test func aRemovedPlaceLeavesTheCopy() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("p.jpg")
        try photoWithPlace(at: original)
        #expect(try properties(original)[kCGImagePropertyGPSDictionary] != nil)
        let out = root.appendingPathComponent("out.jpg")
        try Export.photo(
            original, to: out,
            facts: Export.Facts(takenAt: Date(), timeZoneOffsetMinutes: 0, location: nil, title: nil, description: nil))
        let gps = try properties(out)[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        #expect(gps?[kCGImagePropertyGPSLatitude] == nil)
    }

    @Test func aVideoCarriesItsCorrections() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("v.mov")
        try await SampleMedia.video(
            at: original, seed: 22, seconds: 0.5,
            metadata: VideoMetadata.items(
                location: ClientLocation(latitude: 1, longitude: 2), takenAt: Date(), timeZone: .current))
        let out = root.appendingPathComponent("out.mov")
        try await Export.video(
            original, to: out,
            facts: Export.Facts(
                takenAt: Date(timeIntervalSince1970: 1_800_000_000), timeZoneOffsetMinutes: 60,
                location: ClientLocation(latitude: 48.1372, longitude: 11.5755), title: "Snow", description: nil))
        let metadata = try await AVURLAsset(url: out).load(.metadata)
        func value(_ identifier: AVMetadataIdentifier) async throws -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
            else { return nil }
            return try await item.load(.stringValue)
        }
        #expect(try await value(.quickTimeMetadataLocationISO6709) == "+48.1372+011.5755/")
        #expect(try await value(.quickTimeMetadataTitle) == "Snow")
        #expect(try await value(.quickTimeMetadataCreationDate) == "2027-01-15T09:00:00+01:00")
        #expect(abs(try await VideoFacts.read(out).durationMs - 500) <= 40)
    }
}

@Suite(.enabled(if: RealServer.available, "build the server first: cd server && cargo build"))
struct LibraryServerTests {
    /// A video only on the server plays through the pinned connection, its original comes down
    /// once and is the same file, and the server's details and places without a place arrive.
    @Test func filesDetailsAndPlacesFromTheServer() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "library", platform: "ios", installationId: "install-e2e-library"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let video = UUID().uuidString.lowercased()
        let placed = UUID().uuidString.lowercased()
        let unplaced = UUID().uuidString.lowercased()
        try await SampleMedia.video(at: files.original("v.mov"), seed: 31, seconds: 2)
        let facts = try await VideoFacts.read(files.original("v.mov"))
        try Uploader.enqueue(
            database: database, files: files, assetId: video, fileName: "v.mov", kind: "video",
            mimeType: "video/quicktime",
            metadata: UploadMetadata(
                takenAt: 1_800_000_000_000, width: facts.width, height: facts.height, durationMs: facts.durationMs))
        try noiseJPEG(at: files.original("a.jpg"), seed: 32)
        try noiseJPEG(at: files.original("b.jpg"), seed: 33)
        try Uploader.enqueue(
            database: database, files: files, assetId: placed, fileName: "a.jpg", kind: "photo",
            mimeType: "image/jpeg",
            metadata: UploadMetadata(
                takenAt: 1_800_000_000_000, location: ClientLocation(latitude: 48.1, longitude: 11.5)))
        try Uploader.enqueue(
            database: database, files: files, assetId: unplaced, fileName: "b.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1_800_000_600_000))
        #expect(await Uploader(database: database, files: files, client: client).drain() == 3)

        // The video, as if only on the server: streamed, then downloaded.
        let stream = try #require(StreamLoader.asset(id: video, client: client))
        let duration = try await stream.load(.duration)
        #expect(abs(duration.seconds - 2) < 0.1)
        #expect(try await stream.loadTracks(withMediaType: .video).count == 1)
        var asset = try #require(try database.asset(video))
        try FileManager.default.moveItem(at: files.original("v.mov"), to: root.appendingPathComponent("away.mov"))
        asset.localFile = nil
        let media = MediaFiles(files: files, client: client)
        let downloaded = try await media.original(of: asset)
        #expect(try Hashing.sha256(of: downloaded) == asset.originalSha256)
        #expect(media.localOriginal(of: asset) == downloaded, "kept for next time")
        let placedAsset = try #require(try database.asset(placed))
        let preview = try #require(await media.preview(of: placedAsset))
        #expect(FileManager.default.fileExists(atPath: preview.path))

        let detail = try await client.detail(placed)
        #expect(detail.asset.location?.latitude == 48.1)
        #expect(detail.original?.takenAt == 1_800_000_000_000)
        let without = try await client.withoutPlace()
        let entry = try #require(without.first { $0.asset.id.lowercased() == unplaced })
        #expect(entry.suggestion?.latitude == 48.1 && entry.suggestion?.minutesApart == 10)
    }
}
