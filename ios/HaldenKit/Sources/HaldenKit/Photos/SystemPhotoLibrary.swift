#if canImport(Photos)
    import CoreLocation
    import Foundation
    import Photos
    import UniformTypeIdentifiers

    /// Apple Photos through PhotoKit. What changed comes from the library's persistent change
    /// history (`fetchPersistentChanges(since:)`): exactly what was added and deleted since the
    /// last time, also while Halden wasn't running.
    public final class SystemPhotoLibrary: PhotoLibrary {
        public init() {}

        /// Asks for access: everything (to import) or only adding (to save Halden's photos).
        public static func ask(everything: Bool) async -> Bool {
            let status = await PHPhotoLibrary.requestAuthorization(for: everything ? .readWrite : .addOnly)
            return status == .authorized || status == .limited
        }

        /// Only some photos chosen by the person: the import sees only those.
        public static var limited: Bool {
            PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        }

        public func mayRead() async -> Bool {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return status == .authorized || status == .limited
        }

        public func mayAdd() async -> Bool {
            let add = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if add == .authorized || add == .limited { return true }
            return await mayRead()
        }

        static func archive(_ token: PHPersistentChangeToken) -> Data? {
            try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        }

        public func changes(since token: Data?) async throws -> PhotoChanges {
            let library = PHPhotoLibrary.shared()
            guard let token,
                let previous = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: PHPersistentChangeToken.self, from: token)
            else {
                return PhotoChanges(added: [], deleted: [], token: Self.archive(library.currentChangeToken))
            }
            var added = Set<String>()
            var deleted = Set<String>()
            var last = previous
            do {
                for change in try library.fetchPersistentChanges(since: previous) {
                    let details = try change.changeDetails(for: .asset)
                    added.formUnion(details.insertedLocalIdentifiers)
                    added.subtract(details.deletedLocalIdentifiers)
                    deleted.formUnion(details.deletedLocalIdentifiers)
                    last = change.changeToken
                }
            } catch let error as PHPhotosError where error.code == .persistentChangeTokenExpired {
                // Too long ago: start again from now.
                return PhotoChanges(added: [], deleted: [], token: Self.archive(library.currentChangeToken))
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(added), options: nil)
            var items: [PhotoItem] = []
            assets.enumerateObjects { asset, _, _ in
                if let item = Self.item(asset) { items.append(item) }
            }
            items.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            return PhotoChanges(added: items, deleted: Array(deleted), token: Self.archive(last))
        }

        public func items(after date: Date?, limit: Int) async throws -> [PhotoItem] {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.fetchLimit = limit
            if let date { options.predicate = NSPredicate(format: "creationDate > %@", date as NSDate) }
            var items: [PhotoItem] = []
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                if let item = Self.item(asset) { items.append(item) }
            }
            return items
        }

        static func item(_ asset: PHAsset) -> PhotoItem? {
            let kind: PhotoItem.Kind
            switch asset.mediaType {
            case .image: kind = .photo
            case .video: kind = .video
            default: return nil
            }
            let location = asset.location.flatMap { place -> ClientLocation? in
                guard place.horizontalAccuracy >= 0 else { return nil }
                return ClientLocation(
                    latitude: place.coordinate.latitude, longitude: place.coordinate.longitude,
                    altitude: place.verticalAccuracy >= 0 ? place.altitude : nil,
                    horizontalAccuracy: place.horizontalAccuracy,
                    verticalAccuracy: place.verticalAccuracy >= 0 ? place.verticalAccuracy : nil,
                    heading: place.course >= 0 ? place.course : nil)
            }
            return PhotoItem(
                localIdentifier: asset.localIdentifier, kind: kind,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive), creationDate: asset.creationDate,
                location: location, width: asset.pixelWidth, height: asset.pixelHeight,
                durationMs: kind == .video ? Int64((asset.duration * 1000).rounded()) : nil)
        }

        public func export(_ item: PhotoItem, into folder: URL) async throws -> [ExportedFile] {
            guard
                let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.localIdentifier], options: nil).firstObject
            else { return [] }
            let resources = PHAssetResource.assetResources(for: asset)
            // The original as taken, not an edited version.
            let main =
                item.kind == .video
                ? resources.first { $0.type == .video } ?? resources.first { $0.type == .fullSizeVideo }
                : resources.first { $0.type == .photo } ?? resources.first { $0.type == .fullSizePhoto }
            guard let main else { return [] }
            var files = [try await write(main, into: folder, name: "main")]
            if item.isLivePhoto, let video = resources.first(where: { $0.type == .pairedVideo }) {
                files.append(try await write(video, into: folder, name: "live"))
            }
            return files
        }

        private func write(_ resource: PHAssetResource, into folder: URL, name: String) async throws -> ExportedFile {
            let type = UTType(resource.uniformTypeIdentifier)
            let url = folder.appendingPathComponent("\(name).\(type?.preferredFilenameExtension ?? "bin")")
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            return ExportedFile(
                url: url, mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                originalFilename: resource.originalFilename)
        }

        public func save(_ file: URL, kind: PhotoItem.Kind) async throws -> String {
            let created = Created()
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: kind == .video ? .video : .photo, fileURL: file, options: nil)
                created.identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
            guard let identifier = created.identifier else { throw CocoaError(.fileWriteUnknown) }
            return identifier
        }

        public func delete(_ identifiers: [String]) async -> Bool {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(
                        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
                }
                return true
            } catch {
                return false
            }
        }
    }

    /// The new item's identifier, out of PhotoKit's change block.
    private final class Created: @unchecked Sendable {
        var identifier: String?
    }
#endif
