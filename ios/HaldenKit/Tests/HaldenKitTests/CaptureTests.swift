import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HaldenKit

@Suite struct CapturePlaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(accuracy: Double, age: TimeInterval = 2, verticalAccuracy: Double? = 4) -> PlaceReading {
        PlaceReading(
            latitude: 48.1372, longitude: 11.5755, altitude: 519, horizontalAccuracy: accuracy,
            verticalAccuracy: verticalAccuracy, measuredAt: now.addingTimeInterval(-age))
    }

    @Test func aPreciseFreshPlaceGoesWithItsAccuracyAndDirection() throws {
        let place = try #require(
            CapturePlace.location(
                reading(accuracy: 5), heading: CompassReading(degrees: 271.5, accuracy: 10, trueNorth: true), at: now,
                settings: AppSettings()))
        #expect(place.latitude == 48.1372 && place.altitude == 519)
        #expect(place.horizontalAccuracy == 5 && place.verticalAccuracy == 4)
        #expect(place.heading == 271.5 && place.headingAccuracy == 10)
    }

    /// Better no place than one from somewhere else.
    @Test func anOldReadingIsLeftOut() {
        #expect(
            CapturePlace.location(reading(accuracy: 5, age: 61), heading: nil, at: now, settings: AppSettings()) == nil)
        #expect(CapturePlace.location(nil, heading: nil, at: now, settings: AppSettings()) == nil)
        #expect(CapturePlace.location(reading(accuracy: -1), heading: nil, at: now, settings: AppSettings()) == nil)
    }

    /// Less precise than the limit: kept and marked, or left out, as set.
    @Test func anImprecisePlaceFollowsTheSetting() {
        var settings = AppSettings()
        let rough = reading(accuracy: 120)
        let kept = CapturePlace.location(rough, heading: nil, at: now, settings: settings)
        #expect(kept?.horizontalAccuracy == 120)
        #expect(CapturePlace.imprecise(accuracy: 120, settings: settings))
        #expect(!CapturePlace.imprecise(accuracy: 50, settings: settings))
        settings.inaccurateLocation = .omit
        #expect(CapturePlace.location(rough, heading: nil, at: now, settings: settings) == nil)
        #expect(CapturePlace.location(reading(accuracy: 50), heading: nil, at: now, settings: settings) != nil)
    }

    /// An altitude without a valid vertical accuracy is a guess: not kept.
    @Test func anAltitudeWithoutAccuracyIsLeftOut() {
        let place = CapturePlace.location(
            reading(accuracy: 5, verticalAccuracy: -1), heading: nil, at: now, settings: AppSettings())
        #expect(place != nil && place?.altitude == nil && place?.verticalAccuracy == nil)
    }

    @Test func iso6709IsWrittenLikeApplesCamera() {
        #expect(
            CapturePlace.iso6709(latitude: 48.1372, longitude: 11.5755, altitude: 519) == "+48.1372+011.5755+519.000/")
        #expect(CapturePlace.iso6709(latitude: -33.8688, longitude: -151.2093, altitude: nil) == "-33.8688-151.2093/")
        #expect(CapturePlace.iso6709(latitude: 5.5, longitude: 0, altitude: -12.5) == "+05.5000+000.0000-12.500/")
    }
}

@Suite struct VideoTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A video keeps its length, size, time, place and direction, and gives a thumbnail.
    @Test func aVideoCarriesItsMetadataAndGivesAThumbnail() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("v.mov")
        let place = ClientLocation(
            latitude: 48.1372, longitude: 11.5755, altitude: 519, horizontalAccuracy: 8, heading: 90)
        let items = VideoMetadata.items(
            location: place, takenAt: Date(timeIntervalSince1970: 1_800_000_000),
            timeZone: TimeZone(identifier: "Europe/Berlin")!)
        try await SampleMedia.video(at: url, seed: 1, seconds: 1, metadata: items)

        let facts = try await VideoFacts.read(url)
        #expect(abs(facts.durationMs - 1000) <= 40)
        #expect(facts.width == 640 && facts.height == 360)

        let written = try await AVURLAsset(url: url).load(.metadata)
        func value(_ identifier: AVMetadataIdentifier) async throws -> String? {
            guard let item = AVMetadataItem.metadataItems(from: written, filteredByIdentifier: identifier).first
            else { return nil }
            return try await item.load(.stringValue)
        }
        #expect(try await value(.quickTimeMetadataLocationISO6709) == "+48.1372+011.5755+519.000/")
        #expect(try await value(.quickTimeMetadataDirectionFacing) == "90.00")
        #expect(try await value(.quickTimeMetadataCreationDate) == "2027-01-15T09:00:00+01:00")

        let thumbnail = try #require(await Thumbnails.picture(of: url, edge: 512))
        #expect(max(thumbnail.width, thumbnail.height) == 512)
        #expect(Thumbnails.isVideo(url) && !Thumbnails.isVideo(root.appendingPathComponent("p.heic")))
    }

    /// A video taken here goes into the library with its length and place before it is uploaded.
    @Test func aQueuedVideoShowsItsLengthAndPlace() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        try await SampleMedia.video(at: files.original("a.mov"), seed: 2, seconds: 0.5)
        let facts = try await VideoFacts.read(files.original("a.mov"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "A", fileName: "a.mov", kind: "video",
            mimeType: "video/quicktime",
            metadata: UploadMetadata(
                takenAt: 5, location: ClientLocation(latitude: 1, longitude: 2, horizontalAccuracy: 30, heading: 45),
                width: facts.width, height: facts.height, durationMs: facts.durationMs))
        let asset = try #require(try database.asset("a"))
        #expect(asset.isVideo && asset.durationMs == facts.durationMs && !asset.backedUp)
        #expect(asset.latitude == 1 && asset.locationAccuracy == 30 && asset.heading == 45)
        #expect(asset.origin == "camera" && asset.locationSource == "client")
        let shown = await ThumbnailLoader(files: files, client: nil).load([asset])
        #expect(shown["a"] != nil, "the grid gets a picture of the video at once")
    }

    /// A photo taken with the phone upright is stored on its side with orientation 6.
    @Test func theShownSizeFollowsTheOrientation() throws {
        let photo = try #require(SampleMedia.photo(seed: 3, width: 64, height: 48))
        #expect(Thumbnails.shownSize(of: photo)! == (64, 48))
        let source = try #require(CGImageSourceCreateWithData(photo as CFData, nil))
        let turned = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(turned, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(Thumbnails.shownSize(of: turned as Data)! == (48, 64))
        #expect(Thumbnails.shownSize(of: Data("no photo".utf8)) == nil)
    }

    @Test func samplePhotosDiffer() throws {
        let one = try #require(SampleMedia.photo(seed: 1, width: 64, height: 48))
        let two = try #require(SampleMedia.photo(seed: 2, width: 64, height: 48))
        #expect(one != two)
        #expect(SampleMedia.photo(seed: 1, width: 64, height: 48) == one)
    }
}

@Suite struct LockedCaptureTests {
    /// What the lock-screen camera took comes into the library once, with what it knew.
    @Test func capturesFromTheLockScreenAreTakenOverOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let files = try FileLocations(
            root: root.appendingPathComponent("app"), caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()

        let photo = try #require(SampleMedia.photo(seed: 9, width: 64, height: 48))
        try LockedCaptures.save(
            photo: photo, heic: false,
            metadata: UploadMetadata(
                takenAt: 7, location: ClientLocation(latitude: 1, longitude: 2), width: 64, height: 48),
            into: session)
        let video = root.appendingPathComponent("v.mov")
        try await SampleMedia.video(at: video, seed: 9, seconds: 0.5)
        try LockedCaptures.save(video: video, metadata: UploadMetadata(takenAt: 8, durationMs: 500), into: session)
        // Not finished when the extension was stopped: no description.
        try Data("half".utf8).write(to: session.appendingPathComponent("half.heic"))

        #expect(try LockedCaptures.takeOver(from: session, database: database, files: files) == 2)
        let library = try database.library()
        #expect(library.map(\.kind) == ["video", "photo"])
        #expect(library.last?.latitude == 1 && library.last?.width == 64)
        #expect(library.first?.durationMs == 500)
        #expect(try database.pendingUploads().count == 2)
        #expect(library.allSatisfy { FileManager.default.fileExists(atPath: files.original($0.localFile ?? "-").path) })
        #expect(try LockedCaptures.takeOver(from: session, database: database, files: files) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path) == ["half.heic"])
    }
}
