import HaldenKit
import SwiftUI

/// Every photo, newest first, with a check mark once it is safely on the server.
struct PhotosView: View {
    @Environment(AppModel.self) private var app
    @State private var thumbnails: [String: URL] = [:]
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if app.library.isEmpty {
                    ContentUnavailableView(
                        "No photos yet", systemImage: "photo",
                        description: Text("Photos you take with Halden show up here.")
                    )
                    .accessibilityIdentifier("empty-library")
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(app.library) { asset in
                        NavigationLink(value: asset.id) {
                            Thumbnail(url: thumbnails[asset.id])
                                .overlay(alignment: .bottomTrailing) { badge(for: asset) }
                        }
                        .accessibilityIdentifier("photo-\(asset.id)")
                    }
                }
            }
            .navigationTitle("Photos")
            .navigationDestination(for: String.self) { id in PhotoDetailView(id: id) }
            .refreshable { app.refresh() }
            .task(id: app.library.map { "\($0.id)\($0.thumbnailSha256 ?? "")" }) {
                let found = await app.thumbnails(for: app.library)
                thumbnails.merge(found) { _, new in new }
            }
        }
    }

    @ViewBuilder private func badge(for asset: LocalAsset) -> some View {
        if asset.backedUp {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
                .padding(4)
                .accessibilityLabel("Backed up")
        } else if let progress = app.uploads[asset.id] {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .padding(4)
                .accessibilityLabel("Uploading")
        } else {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.white)
                .padding(4)
                .accessibilityLabel("Not backed up yet")
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
