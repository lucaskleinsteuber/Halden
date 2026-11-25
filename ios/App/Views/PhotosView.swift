import HaldenKit
import SwiftUI

/// Every photo, newest first, with a check mark once it is safely on the server.
struct PhotosView: View {
    enum Route: Hashable {
        case photo(String)
        case withoutPlace
        case uploads
        case trash
        case album(String)
        case photoInAlbum(String, album: String)
        case mapGroup([String])
        case photoInGroup(String, group: [String])
    }

    /// What the Photos tab shows.
    enum Section: String, CaseIterable {
        case library = "Library"
        case albums = "Albums"
        case map = "Map"
    }

    @Environment(AppModel.self) private var app
    @State private var path: [Route] = []
    /// While choosing photos: the chosen ones.
    @State private var selection: Set<String>?
    @State private var confirmDelete = false
    @State private var note: String?
    @State private var section = Section.library
    @State private var addingToAlbum: ChosenPhotos?
    @State private var linking: ChosenPhotos?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch section {
                case .library: library
                case .albums: AlbumsView { id in path.append(.album(id)) }
                case .map:
                    MapLibraryView { ids in
                        path.append(ids.count == 1 ? .photoInGroup(ids[0], group: ids) : .mapGroup(ids))
                    } withoutPlace: {
                        path.append(.withoutPlace)
                    }
                }
            }
            .navigationTitle(section.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .disabled(selection != nil)
                    .accessibilityIdentifier("photos-section")
                }
            }
            .sheet(item: $addingToAlbum, onDismiss: { selection = nil }) { chosen in
                AlbumPicker(assetIds: chosen.ids)
            }
            .sheet(item: $linking, onDismiss: { selection = nil }) { chosen in
                NewLinkView(assetIds: chosen.ids)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .photo(let id): PhotoView(start: id, assets: app.library)
                case .withoutPlace: WithoutPlaceView()
                case .uploads: UploadsView()
                case .trash: TrashView()
                case .album(let id):
                    AlbumView(id: id) { photo, _ in path.append(.photoInAlbum(photo, album: id)) }
                case .photoInAlbum(let photo, let album):
                    PhotoView(start: photo, assets: app.photos(inAlbum: album))
                case .mapGroup(let ids):
                    MapGroupView(ids: ids) { photo in path.append(.photoInGroup(photo, group: ids)) }
                case .photoInGroup(let photo, let ids):
                    let wanted = Set(ids)
                    PhotoView(start: photo, assets: app.library.filter { wanted.contains($0.id) })
                }
            }
        }
    }

    private var library: some View {
        LibraryGrid(
            assets: app.library, version: app.libraryVersion, uploads: app.uploads, pipeline: app.pipeline,
            selection: selection
        ) { id in
            if var chosen = selection {
                if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                selection = chosen
            } else {
                path.append(.photo(id))
            }
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
        .refreshable { app.refresh() }
        .toolbar(selection == nil ? .automatic : .hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selection == nil ? "Select" : "Done") {
                    selection = selection == nil ? [] : nil
                }
                .accessibilityIdentifier("select")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Without place", systemImage: "mappin.slash") { path.append(.withoutPlace) }
                        .accessibilityIdentifier("without-place")
                    Button("Trash", systemImage: "trash") { path.append(.trash) }
                        .accessibilityIdentifier("trash")
                    Button("Uploads", systemImage: "arrow.up.circle") { path.append(.uploads) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("photos-menu")
            }
            if let selection {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        let removed = app.removeFromPhone(Array(selection))
                        note =
                            removed == selection.count
                            ? "Removed from this iPhone; still on the server."
                            : "\(removed) of \(selection.count) removed. The others aren't safely on the server yet."
                        self.selection = []
                    } label: {
                        Image(systemName: "iphone.slash")
                    }
                    .disabled(app.removableFromPhone(Array(selection)) == 0)
                    .accessibilityLabel("Remove from this iPhone")
                    .accessibilityIdentifier("remove-chosen")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        addingToAlbum = ChosenPhotos(ids: Array(selection))
                    } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel("Add \(selection.count) to album")
                    .accessibilityIdentifier("add-to-album")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        linking = ChosenPhotos(ids: Array(selection))
                    } label: {
                        Image(systemName: "link")
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel("Share a link to \(selection.count)")
                    .accessibilityIdentifier("link-chosen")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel("Delete \(selection.count) everywhere")
                    .accessibilityIdentifier("delete-chosen")
                }
            }
        }
        .confirmationDialog(
            "Delete \(selection?.count ?? 0) everywhere?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete everywhere", role: .destructive) {
                app.moveToTrash(Array(selection ?? []))
                selection = nil
            }
            .accessibilityIdentifier("confirm-delete")
        } message: {
            Text(
                "They go to the trash on the server and on all devices, and can be restored for \(app.trashDays) days."
            )
        }
        .alert("Done", isPresented: .constant(note != nil)) {
            Button("OK") { note = nil }
        } message: {
            Text(note ?? "")
        }
    }
}

/// Photos chosen for something that opens a sheet.
struct ChosenPhotos: Identifiable {
    let ids: [String]
    var id: String { ids.joined(separator: ",") }
}
