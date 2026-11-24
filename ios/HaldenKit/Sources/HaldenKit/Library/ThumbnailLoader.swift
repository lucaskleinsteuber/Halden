import Foundation

/// Gets thumbnails for the grid: from the cache on disk (by SHA-256, so a thumbnail is never
/// fetched twice), made from the local file for photos not backed up yet, and otherwise up to
/// 500 at a time from the server in one request.
public actor ThumbnailLoader {
    let files: FileLocations
    let client: APIClient?

    public init(files: FileLocations, client: APIClient?) {
        self.files = files
        self.client = client
    }

    /// The cached file for an asset, if there is one now.
    public nonisolated func cached(_ asset: LocalAsset) -> URL? {
        guard let sha = asset.thumbnailSha256 else { return nil }
        let url = files.thumbnail(sha256: sha)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Makes sure these assets have a thumbnail on disk. Returns the ones that have one now.
    @discardableResult
    public func load(_ assets: [LocalAsset]) async -> [String: URL] {
        var ready: [String: URL] = [:]
        var fromServer: [LocalAsset] = []
        for asset in assets {
            if let url = cached(asset) {
                ready[asset.id] = url
            } else if asset.thumbnailSha256 != nil, client != nil {
                fromServer.append(asset)
            } else if let name = asset.localFile,
                let made = await Thumbnails.picture(of: files.original(name), edge: Thumbnails.thumbnailEdge)
            {
                let url = files.thumbnail(sha256: asset.thumbnailSha256 ?? made.sha256)
                if (try? made.data.write(to: url, options: .atomic)) != nil {
                    ready[asset.id] = url
                }
            }
        }
        guard let client, !fromServer.isEmpty else { return ready }
        for batch in stride(from: 0, to: fromServer.count, by: 500) {
            let slice = Array(fromServer[batch..<min(batch + 500, fromServer.count)])
            guard let got = try? await client.thumbnails(of: slice.map(\.id)) else { continue }
            for asset in slice {
                guard let data = got[asset.id], let sha = asset.thumbnailSha256 else { continue }
                let url = files.thumbnail(sha256: sha)
                if (try? data.write(to: url, options: .atomic)) != nil {
                    ready[asset.id] = url
                }
            }
        }
        return ready
    }
}
