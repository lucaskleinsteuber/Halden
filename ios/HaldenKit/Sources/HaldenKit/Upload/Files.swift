import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the app keeps its files: originals taken here (until the person removes them) and the
/// thumbnail cache.
public struct FileLocations: Sendable {
    /// Originals taken with Halden, kept as they were taken.
    public let originals: URL
    /// Thumbnails and previews by their SHA-256; the system may clear this folder.
    public let thumbnails: URL

    public init(root: URL, caches: URL) throws {
        originals = root.appendingPathComponent("Originals", isDirectory: true)
        thumbnails = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        for folder in [originals, thumbnails] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Originals are not in iCloud backups: they go to the Halden server instead.
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    /// The app's standard places.
    public static func standard() throws -> FileLocations {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try FileLocations(
            root: support.appendingPathComponent("Halden", isDirectory: true),
            caches: caches.appendingPathComponent("Halden", isDirectory: true))
    }

    /// A file of an original, by its name in the database.
    public func original(_ name: String) -> URL {
        originals.appendingPathComponent(name)
    }

    public func thumbnail(sha256: String) -> URL {
        thumbnails.appendingPathComponent("\(sha256).jpg")
    }
}

public enum Hashing {
    /// SHA-256 of a file, read in pieces of 1 MiB (a 2 GB video never sits in memory).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A small JPEG made from a photo on this device.
public struct MadeImage: Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var sha256: String
}

public enum Thumbnails {
    /// The long edge of thumbnails (grid) and previews (full screen), as the server makes them.
    public static let thumbnailEdge = 512
    public static let previewEdge = 2048

    /// A picture of a photo or a video (a frame from half a second in), long edge at most `edge`.
    public static func picture(of url: URL, edge: Int, quality: Double = 0.82) async -> MadeImage? {
        if isVideo(url) {
            return await make(fromVideo: url, edge: edge, quality: quality)
        }
        return make(from: url, edge: edge, quality: quality)
    }

    /// Width and height of a photo as it is shown (turned upright by its orientation).
    public static func shownSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Orientations 5 to 8 turn the picture by a quarter.
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    public static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    /// Scales a photo (HEIC, JPEG, PNG, …) so its long edge is at most `edge`, upright, as JPEG.
    public static func make(from url: URL, edge: Int, quality: Double = 0.82) -> MadeImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return jpeg(image, quality: quality)
    }

    /// A frame of a video, upright, not the often black very first one.
    public static func make(fromVideo url: URL, edge: Int, quality: Double = 0.82) async -> MadeImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: edge, height: edge)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        let moment = CMTime(seconds: seconds.isFinite ? min(0.5, seconds / 2) : 0, preferredTimescale: 600)
        guard let (image, _) = try? await generator.image(at: moment) else { return nil }
        return jpeg(image, quality: quality)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> MadeImage? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = output as Data
        return MadeImage(data: data, width: image.width, height: image.height, sha256: Hashing.sha256(of: data))
    }
}
