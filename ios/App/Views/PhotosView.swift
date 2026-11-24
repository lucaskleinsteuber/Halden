import HaldenKit
import SwiftUI

/// Every photo, newest first, with a check mark once it is safely on the server.
struct PhotosView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryGrid(
                assets: app.library, version: app.libraryVersion, uploads: app.uploads, pipeline: app.pipeline
            ) { id in
                path.append(id)
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if app.library.isEmpty {
                    ContentUnavailableView(
                        "No photos yet", systemImage: "photo",
                        description: Text("Photos you take with Halden show up here.")
                    )
                    .accessibilityIdentifier("empty-library")
                }
            }
            .navigationTitle("Photos")
            .navigationDestination(for: String.self) { id in PhotoDetailView(id: id) }
        }
    }
}

struct Thumbnail: View {
    let url: URL?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
    }
}

struct PhotoDetailView: View {
    @Environment(AppModel.self) private var app
    let id: String

    var body: some View {
        let asset = app.library.first { $0.id == id }
        VStack {
            if let asset, let image = image(of: asset) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ContentUnavailableView("Not on this iPhone", systemImage: "photo")
            }
            if let asset {
                Text(Date(timeIntervalSince1970: Double(asset.takenAt) / 1000).formatted(date: .long, time: .shortened))
                    .font(.footnote)
                Label(
                    asset.backedUp ? "Backed up" : "Not backed up yet",
                    systemImage: asset.backedUp ? "checkmark.circle" : "icloud.slash"
                )
                .font(.footnote)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func image(of asset: LocalAsset) -> UIImage? {
        if let name = asset.localFile, let image = UIImage(contentsOfFile: app.files.original(name).path) {
            return image
        }
        if let sha = asset.previewSha256 ?? asset.thumbnailSha256 {
            return UIImage(contentsOfFile: app.files.thumbnail(sha256: sha).path)
        }
        return nil
    }
}
