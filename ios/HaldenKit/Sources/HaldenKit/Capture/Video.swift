import AVFoundation
import Foundation

/// What is known about a video file once it is written.
public struct VideoFacts: Sendable, Equatable {
    public var durationMs: Int64
    /// As shown (turned upright), not as stored.
    public var width: Int
    public var height: Int

    public init(durationMs: Int64, width: Int, height: Int) {
        self.durationMs = durationMs
        self.width = width
        self.height = height
    }

    public static func read(_ url: URL) async throws -> VideoFacts {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        return VideoFacts(
            durationMs: Int64((duration.seconds * 1000).rounded()),
            width: Int(shown.width.rounded()), height: Int(shown.height.rounded()))
    }
}

/// The metadata Halden writes into its videos, the way Apple's camera does, so the file carries
/// time, place and direction wherever it goes.
public enum VideoMetadata {
    static let horizontalAccuracyKey = "com.apple.quicktime.location.accuracy.horizontal"

    public static func items(location: ClientLocation?, takenAt: Date, timeZone: TimeZone) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: String) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        let date = ISO8601DateFormatter()
        date.timeZone = timeZone
        date.formatOptions = [.withInternetDateTime]
        add(.quickTimeMetadataCreationDate, date.string(from: takenAt))
        add(.quickTimeMetadataSoftware, "Halden")
        if let location {
            add(
                .quickTimeMetadataLocationISO6709,
                CapturePlace.iso6709(
                    latitude: location.latitude, longitude: location.longitude, altitude: location.altitude))
            if let accuracy = location.horizontalAccuracy,
                let identifier = AVMetadataItem.identifier(
                    forKey: horizontalAccuracyKey as NSString, keySpace: .quickTimeMetadata)
            {
                add(identifier, String(format: "%.6f", accuracy))
            }
            if let heading = location.heading {
                add(.quickTimeMetadataDirectionFacing, String(format: "%.2f", heading))
            }
        }
        return items
    }
}
