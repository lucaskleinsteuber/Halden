import HaldenKit
import SwiftUI

/// The albums: the own ones with their cover and how many photos are in them, and below the
/// trips Halden found, to keep as albums.
struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    let open: (String) -> Void
    @State private var naming = false
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(app.albums) { summary in
                    Button {
                        open(summary.id)
                    } label: {
                        AlbumCard(title: summary.album.name, count: summary.count, cover: summary.cover)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("album-\(summary.album.name)")
                }
            }
            .padding(.horizontal)
            if app.albums.isEmpty {
                Text("No albums yet. Make one with +, or choose photos and add them to one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .accessibilityIdentifier("no-albums")
            }
            if !app.trips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Trips").font(.title3.bold())
                    Text("Found in your photos: days far from home. Keep one to make it an album.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(app.trips) { trip in
                        TripRow(trip: trip)
                    }
                }
                .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New album")
                .accessibilityIdentifier("new-album")
            }
        }
        .task(id: app.libraryVersion) { app.findTrips() }
        .alert("New album", isPresented: $naming) {
            TextField("Name", text: $newName).accessibilityIdentifier("album-name")
            Button("Make") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { app.createAlbum(named: name) }
            }
            .accessibilityIdentifier("make-album")
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// An album's cover, name and size.
struct AlbumCard: View {
    @Environment(AppModel.self) private var app
    let title: String
    let count: Int
    let cover: LocalAsset?
    @State private var picture: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.secondary.opacity(0.15)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let picture {
                        Image(decorative: picture, scale: 1).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: cover.map { "\($0.id) \($0.thumbnailSha256 ?? "")" }) {
            guard let cover else {
                picture = nil
                return
            }
            picture = await app.pipeline.image(for: cover, pixels: 400)?.cgImage
        }
        .accessibilityElement(children: .combine)
    }
}

/// A trip found in the photos, to keep as an album.
struct TripRow: View {
    @Environment(AppModel.self) private var app
    let trip: TripSuggestion

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title).font(.subheadline.weight(.medium))
                Text("\(trip.trip.assetIds.count) photos · \(trip.trip.days) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Keep") { app.keep(trip) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("keep-trip")
        }
        .accessibilityElement(children: .contain)
    }
}

/// One album: its photos like the library, renaming, deleting, and choosing photos to take out
/// or to put on the cover.
struct AlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    let openPhoto: (String, [LocalAsset]) -> Void
    @State private var photos: [LocalAsset] = []
    /// Goes up whenever `photos` is loaded: the grid redraws only then.
    @State private var loaded = 0
    @State private var selection: Set<String>?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var linking = false

    private var album: LocalAlbum? { app.albums.first { $0.id == id }?.album }

    var body: some View {
        LibraryGrid(
            assets: photos, version: loaded, uploads: app.uploads, pipeline: app.pipeline,
            selection: selection
        ) { asset in
            if var chosen = selection {
                if chosen.contains(asset) { chosen.remove(asset) } else { chosen.insert(asset) }
                selection = chosen
            } else {
                openPhoto(asset, photos)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            if photos.isEmpty {
                ContentUnavailableView(
                    "No photos in it", systemImage: "photo",
                    description: Text("Choose photos in the library and add them to this album."))
            }
        }
        .navigationTitle(album?.name ?? "Album")
        .toolbar(selection == nil ? .automatic : .hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selection == nil ? "Select" : "Done") { selection = selection == nil ? [] : nil }
                    .accessibilityIdentifier("select-in-album")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = album?.name ?? ""
                        renaming = true
                    }
                    .accessibilityIdentifier("rename-album")
                    Button("Share a link…", systemImage: "link") { linking = true }
                        .accessibilityIdentifier("share-album")
                    Button("Delete album", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("delete-album")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Album")
                .accessibilityIdentifier("album-menu")
            }
            if let selection {
                ToolbarItem(placement: .bottomBar) {
                    Button("Make cover") {
                        if let first = selection.first { app.setCover(of: id, to: first) }
                        self.selection = nil
                    }
                    .disabled(selection.count != 1)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Take out", role: .destructive) {
                        app.removeFromAlbum(id, Array(selection))
                        self.selection = nil
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("take-out")
                }
            }
        }
        .alert("Rename album", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { app.renameAlbum(id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this album?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete album", role: .destructive) {
                app.deleteAlbum(id)
                dismiss()
            }
            .accessibilityIdentifier("confirm-delete-album")
        } message: {
            Text("The photos stay in your library.")
        }
        .sheet(isPresented: $linking) { NewLinkView(assetIds: [], albumId: id, title: album?.name) }
        .task(id: "\(app.libraryVersion) \(app.albums.first { $0.id == id }.map { "\($0.count)" } ?? "")") {
            photos = app.photos(inAlbum: id)
            loaded += 1
        }
    }
}

/// Chooses the album chosen photos go into, or makes a new one for them.
struct AlbumPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let assetIds: [String]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                // A new album right here (no extra question on top of this sheet).
                Section {
                    HStack {
                        TextField("New album", text: $newName)
                            .submitLabel(.done)
                            .onSubmit(makeAlbum)
                            .accessibilityIdentifier("new-album-name")
                        Button("Make", action: makeAlbum)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("make-album")
                    }
                }
                ForEach(app.albums) { summary in
                    Button {
                        app.addToAlbum(summary.id, assetIds)
                        dismiss()
                    } label: {
                        LabeledContent(summary.album.name, value: "\(summary.count)")
                    }
                    .accessibilityIdentifier("pick-\(summary.album.name)")
                }
            }
            .navigationTitle("Add \(assetIds.count) to album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func makeAlbum() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        app.createAlbum(named: name, with: assetIds)
        dismiss()
    }
}
