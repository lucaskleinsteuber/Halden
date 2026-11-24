import Photos

/// Tells when something changed in Apple Photos while Halden is open.
@MainActor
final class PhotosWatcher: NSObject, PHPhotoLibraryChangeObserver {
    var changed: (() -> Void)?
    private var registered = false
    private var waiting: Task<Void, Never>?

    func start() {
        guard !registered else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        registered = true
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            // Many changes at once (an import in Apple Photos): once, a moment later.
            self.waiting?.cancel()
            self.waiting = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { self.changed?() }
            }
        }
    }
}
