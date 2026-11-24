import CoreGraphics
import Foundation
import ImageIO

/// A decoded picture, ready to show without more work on the main thread.
public final class DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

/// Pictures for the grid, fast enough for tens of thousands of photos: decoded pictures stay in
/// memory, the small JPEGs on disk by their SHA-256, and what is missing is fetched from the server
/// in bulk (many cells asking at once become one request). Decoding happens off the main thread and
/// scales to the size the cell shows, so scrolling never waits for it.
public actor ImagePipeline {
    /// Decoded pictures by SHA-256 (or asset id) and size. Thread-safe on its own, so a cell can
    /// look into it synchronously and show a picture in the same frame.
    private nonisolated(unsafe) let memory = NSCache<NSString, DecodedImage>()
    private var loader: ThumbnailLoader
    private var waiting: [String: (asset: LocalAsset, callers: [CheckedContinuation<URL?, Never>])] = [:]
    private var flushing = false

    /// How long requests are collected before they go out together.
    static let batchDelay = Duration.milliseconds(15)

    public init(loader: ThumbnailLoader, memoryLimitBytes: Int = 96 << 20) {
        self.loader = loader
        memory.totalCostLimit = memoryLimitBytes
    }

    /// Another server connection (after signing in, or a different address).
    public func use(_ loader: ThumbnailLoader) {
        self.loader = loader
    }

    nonisolated static func key(_ asset: LocalAsset, pixels: Int) -> NSString {
        "\(asset.thumbnailSha256 ?? asset.id)-\(pixels)" as NSString
    }

    /// The picture if it is decoded already; never waits.
    public nonisolated func cached(_ asset: LocalAsset, pixels: Int) -> DecodedImage? {
        memory.object(forKey: Self.key(asset, pixels: pixels))
    }

    /// The asset's thumbnail scaled so its longer side is at most `pixels`.
    public func image(for asset: LocalAsset, pixels: Int) async -> DecodedImage? {
        let key = Self.key(asset, pixels: pixels)
        if let found = memory.object(forKey: key) { return found }
        var url = loader.cached(asset)
        if url == nil {
            url = await fetch(asset)
        }
        guard let url, !Task.isCancelled else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decode(url, pixels: pixels)
        }.value
        if let decoded {
            memory.setObject(decoded, forKey: key, cost: decoded.cgImage.bytesPerRow * decoded.cgImage.height)
        }
        return decoded
    }

    /// Gets pictures ready that will be needed soon (cells about to scroll in).
    public nonisolated func prefetch(_ assets: [LocalAsset], pixels: Int) {
        for asset in assets where cached(asset, pixels: pixels) == nil {
            Task(priority: .utility) { _ = await image(for: asset, pixels: pixels) }
        }
    }

    public nonisolated func forgetDecoded() {
        memory.removeAllObjects()
    }

    private func fetch(_ asset: LocalAsset) async -> URL? {
        await withCheckedContinuation { continuation in
            waiting[asset.id, default: (asset, [])].callers.append(continuation)
            if !flushing {
                flushing = true
                Task {
                    try? await Task.sleep(for: Self.batchDelay)
                    await flush()
                }
            }
        }
    }

    private func flush() async {
        let batch = waiting
        waiting = [:]
        flushing = false
        let found = await loader.load(batch.values.map(\.asset))
        for (id, entry) in batch {
            for caller in entry.callers {
                caller.resume(returning: found[id])
            }
        }
    }

    /// Decodes a JPEG (or any picture ImageIO reads) at no more than `pixels` on its longer side.
    public nonisolated static func decode(_ url: URL, pixels: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            // Decoded now, here, instead of later on the main thread while drawing.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedImage(image)
    }
}
