import AVFoundation
import Foundation
import GRDB

/// Smaller copies of big videos, to play on the go: made on the iPhone with its video encoder
/// (H.264 in MP4, the shorter side 720, about 3 Mbit/s, the sound as it was) and sent as the
/// asset's `stream`, so the server needn't make them. Turned the same way as the original
/// (the turn is kept as metadata, the pictures aren't turned).
public enum SmallVideos {
    public static let shorterSide = 720
    public static let kbps = 3000

    /// Whether a video is no bigger than its small copy would be.
    public static func smallAlready(width: Int?, height: Int?, bytes: Int64, durationMs: Int64?) -> Bool {
        guard let width, let height, let durationMs, durationMs > 0 else { return false }
        let kbps = Double(bytes) * 8 / Double(durationMs)
        return min(width, height) <= shorterSide && kbps <= Double(Self.kbps) * 1.5
    }

    /// Writes the small copy of `source` to `destination`.
    public static func make(
        from source: URL, to destination: URL, shorterSide: Int = shorterSide, kbps: Int = kbps
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let scale = min(1, Double(shorterSide) / Double(min(natural.width, natural.height)))
        // Even sizes, as the encoder wants them.
        let width = Int((natural.width * scale / 2).rounded()) * 2
        let height = Int((natural.height * scale / 2).rounded()) * 2

        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(
            track: video,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
        frames.alwaysCopiesSampleData = false
        reader.add(frames)
        var sound: AVAssetReaderTrackOutput?
        if let audio {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                sound = output
            }
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = try await asset.load(.metadata)
        let pictures = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: kbps * 1000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        pictures.transform = transform
        pictures.expectsMediaDataInRealTime = false
        writer.add(pictures)
        var soundInput: AVAssetWriterInput?
        if let audio, sound != nil {
            let hint = try await audio.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                soundInput = input
            } else {
                sound = nil
            }
        }
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        try await copy(frames, into: pictures, reader: reader, writer: writer)
        if let sound, let soundInput { try await copy(sound, into: soundInput, reader: reader, writer: writer) }
        await writer.finishWriting()
        if writer.status != .completed || reader.status == .failed {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private static func copy(
        _ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws {
        while let sample = output.copyNextSampleBuffer() {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing || reader.status == .failed {
                    input.markAsFinished()
                    throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
                }
                waited += 1
                if waited > 6_000 {
                    input.markAsFinished()
                    writer.cancelWriting()
                    reader.cancelReading()
                    throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            if !input.append(sample) { break }
            try Task.checkCancellation()
        }
        input.markAsFinished()
    }
}

extension HaldenDatabase {
    /// Videos on this iPhone that are on the server and need a small copy still.
    public func videosWithoutSmallCopy(files: FileLocations, limit: Int = 5) throws -> [LocalAsset] {
        try writer.read { db in
            try LocalAsset.fetchAll(
                db,
                sql: """
                    SELECT * FROM asset
                    WHERE kind = 'video' AND backedUp = 1 AND localFile IS NOT NULL AND streamSha256 IS NULL
                      AND trashedAt IS NULL AND deletedAt IS NULL
                      AND id NOT IN (SELECT assetId FROM upload WHERE role = 'stream')
                      AND id NOT IN (SELECT value FROM json_each(coalesce(
                          (SELECT CAST(value AS TEXT) FROM meta WHERE key = 'noSmallCopy'), '[]')))
                    ORDER BY takenAt DESC LIMIT ?
                    """, arguments: [limit])
        }
    }

    /// A video that needs no small copy (small already, or it can't be made): not asked again.
    public func noSmallCopy(_ id: String) throws {
        var ids = (try meta("noSmallCopy")).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        ids.append(id)
        try setMeta("noSmallCopy", try JSONEncoder().encode(ids))
    }
}

extension Uploader {
    /// A video's small copy (already written to `files.originals`), sent after its original.
    public static func enqueueSmallCopy(
        database: HaldenDatabase, files: FileLocations, assetId: String, fileName: String
    ) throws {
        let size = try FileManager.default.attributesOfItem(atPath: files.original(fileName).path)[.size] as? Int64 ?? 0
        let item = UploadItem(
            assetId: assetId.lowercased(), role: "stream", file: fileName, mimeType: "video/mp4", size: size,
            sha256: nil, metadata: nil, uploadId: nil, sent: 0, state: "waiting", attempts: 0, lastError: nil,
            retryAt: 0, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        try database.writer.write { db in try item.insert(db) }
    }
}
