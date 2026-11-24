import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// The bigger files behind a photo for the full-screen view, sharing and export: the preview
/// (about 2048 px) and the original. What is on this iPhone is used as it is; what isn't is
/// fetched from the server once and kept in the cache by its hash.
public actor MediaFiles {
    let files: FileLocations
    private var client: APIClient?
    private var loading: [String: Task<URL, Error>] = [:]

    public init(files: FileLocations, client: APIClient?) {
        self.files = files
        self.client = client
    }

    public func use(_ client: APIClient?) {
        self.client = client
    }

    nonisolated var originalsCache: URL {
        files.thumbnails.deletingLastPathComponent().appendingPathComponent("Originals", isDirectory: true)
    }

    /// The preview: from the cache, else from the server (asked for by asset), else made from
    /// the original on this iPhone. `nil` when there is none yet.
    public func preview(of asset: LocalAsset) async -> URL? {
        if let sha = asset.previewSha256 {
            let url = files.thumbnail(sha256: sha)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            if let client, let data = try? await client.thumbnails(of: [asset.id], role: "preview")[asset.id] {
                if (try? data.write(to: url, options: .atomic)) != nil { return url }
            }
        }
        if let name = asset.localFile,
            let made = await Thumbnails.picture(of: files.original(name), edge: Thumbnails.previewEdge)
        {
            let url = files.thumbnail(sha256: made.sha256)
            if (try? made.data.write(to: url, options: .atomic)) != nil { return url }
        }
        return nil
    }

    /// Where the original is on this iPhone right now, without fetching it.
    public nonisolated func localOriginal(of asset: LocalAsset) -> URL? {
        if let name = asset.localFile {
            let url = files.original(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let cached = cachedOriginal(of: asset)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    nonisolated func cachedOriginal(of asset: LocalAsset) -> URL {
        let type = asset.mimeType.flatMap { UTType(mimeType: $0) }
        let name = (asset.originalSha256 ?? asset.id) + "." + (type?.preferredFilenameExtension ?? "bin")
        return originalsCache.appendingPathComponent(name)
    }

    /// The original: on this iPhone, or fetched from the server once (several asking at once
    /// share one download).
    public func original(of asset: LocalAsset) async throws -> URL {
        if let url = localOriginal(of: asset) { return url }
        guard let client else { throw APIError.unreachable("not connected") }
        if let running = loading[asset.id] { return try await running.value }
        let destination = cachedOriginal(of: asset)
        let folder = originalsCache
        let task = Task {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await client.download(asset: asset.id, role: "original", to: destination)
            return destination
        }
        loading[asset.id] = task
        defer { loading[asset.id] = nil }
        return try await task.value
    }
}

/// Feeds `AVPlayer` with a video from the server in ranges, over the API client with the pinned
/// certificate. The player asks for `halden-stream://<asset>/<role>`; this answers with the
/// bytes it asked for.
public final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "halden-stream"
    let client: APIClient
    let id: String
    let role: String
    private let lock = NSLock()
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static let queue = DispatchQueue(label: "halden.stream")
    /// AVURLAsset keeps its resource loader delegate weakly.
    nonisolated(unsafe) private static let alive = NSMapTable<AVURLAsset, StreamLoader>.weakToStrongObjects()
    private static let aliveLock = NSLock()

    init(client: APIClient, id: String, role: String) {
        self.client = client
        self.id = id
        self.role = role
    }

    /// An asset the player can play, its bytes coming from the server through `client`.
    public static func asset(id: String, role: String = "original", client: APIClient?) -> AVURLAsset? {
        guard let client, let url = URL(string: "\(scheme)://\(id)/\(role)") else { return nil }
        let asset = AVURLAsset(url: url)
        let loader = StreamLoader(client: client, id: id, role: role)
        asset.resourceLoader.setDelegate(loader, queue: queue)
        aliveLock.withLock { alive.setObject(loader, forKey: asset) }
        return asset
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(request)
        let carried = UncheckedRequest(request: request)
        let task = Task { [client, id, role] in
            await Self.answer(carried.request, client: client, id: id, role: role)
            _ = self.lock.withLock { self.requests.removeValue(forKey: key) }
        }
        lock.withLock { requests[key] = task }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest
    ) {
        lock.withLock { requests.removeValue(forKey: ObjectIdentifier(request)) }?.cancel()
    }

    /// Pieces of at most this size, so playing starts before a big range has arrived.
    static let piece: Int64 = 2 << 20

    static func answer(_ request: AVAssetResourceLoadingRequest, client: APIClient, id: String, role: String) async {
        do {
            if let info = request.contentInformationRequest {
                let first = try await client.range(asset: id, role: role, offset: 0, length: 2)
                info.contentType = UTType(mimeType: first.mimeType)?.identifier ?? UTType.quickTimeMovie.identifier
                info.contentLength = first.total
                info.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                var offset = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
                let end: Int64? =
                    data.requestsAllDataToEndOfResource ? nil : data.requestedOffset + Int64(data.requestedLength)
                while end.map({ offset < $0 }) ?? true {
                    try Task.checkCancellation()
                    let length = min(piece, (end ?? Int64.max) - offset)
                    let got = try await client.range(asset: id, role: role, offset: offset, length: length)
                    if got.data.isEmpty { break }
                    data.respond(with: got.data)
                    offset += Int64(got.data.count)
                    if offset >= got.total { break }
                }
            }
            request.finishLoading()
        } catch is CancellationError {
            return
        } catch {
            request.finishLoading(with: error)
        }
    }
}

/// `AVAssetResourceLoadingRequest` isn't marked `Sendable`; each one is answered by exactly one task.
struct UncheckedRequest: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
}
