import AVFoundation
import Foundation
import Testing

@testable import HaldenKit

@Suite struct SmallVideosTests {
    @Test func onlyBigVideosGetASmallCopy() {
        let minute: Int64 = 60_000
        #expect(!SmallVideos.smallAlready(width: 3840, height: 2160, bytes: 375_000_000, durationMs: minute))
        #expect(SmallVideos.smallAlready(width: 1280, height: 720, bytes: 15_000_000, durationMs: minute))
        #expect(SmallVideos.smallAlready(width: 720, height: 1280, bytes: 15_000_000, durationMs: minute))
        #expect(!SmallVideos.smallAlready(width: nil, height: nil, bytes: 1, durationMs: minute))
    }

    /// The copy is the size asked for, H.264, as long as the original, turned the same way.
    @Test func theSmallCopyKeepsTheVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("o.mov")
        try await SampleMedia.video(at: original, seed: 6, seconds: 2)
        let small = folder.appendingPathComponent("s.mp4")
        try await SmallVideos.make(from: original, to: small, shorterSide: 180, kbps: 500)
        let made = AVURLAsset(url: small)
        let track = try #require(try await made.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
        let codec = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(codec == kCMVideoCodecType_H264)
        #expect(abs(try await made.load(.duration).seconds - 2) < 0.1)
    }

    /// Made once per video; the round of uploads isn't about them.
    @Test func smallCopiesAreAskedForOnceAndDontCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        try Data(repeating: 1, count: 100).write(to: files.original("v.mov"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "v", fileName: "v.mov", kind: "video",
            mimeType: "video/quicktime", metadata: UploadMetadata(takenAt: 1, durationMs: 1000))
        try database.writer.write { db in
            try db.execute(sql: "UPDATE upload SET state = 'done'")
            try db.execute(sql: "UPDATE asset SET backedUp = 1")
        }
        #expect(try database.videosWithoutSmallCopy(files: files).map(\.id) == ["v"])
        try Data(repeating: 2, count: 10).write(to: files.original("v-small.mp4"))
        try Uploader.enqueueSmallCopy(database: database, files: files, assetId: "v", fileName: "v-small.mp4")
        #expect(try database.videosWithoutSmallCopy(files: files).isEmpty)
        #expect(try database.uploadSummary().total == 1, "the round counts photos and videos only")
        try Data(repeating: 1, count: 100).write(to: files.original("w.mov"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "w", fileName: "w.mov", kind: "video",
            mimeType: "video/quicktime", metadata: UploadMetadata(takenAt: 2))
        try database.writer.write { db in
            try db.execute(sql: "UPDATE upload SET state = 'done'")
            try db.execute(sql: "UPDATE asset SET backedUp = 1")
        }
        try database.noSmallCopy("w")
        #expect(try database.videosWithoutSmallCopy(files: files).isEmpty)
    }
}
