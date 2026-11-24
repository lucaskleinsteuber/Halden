import HaldenKit
import SwiftUI

/// Every photo, newest first, with a check mark once it is safely on the server.
struct PhotosView: View {
    enum Route: Hashable {
        case photo(String)
        case withoutPlace
        case uploads
        case trash
    }

    @Environment(AppModel.self) private var app
    @State private var path: [Route] = []
    /// While choosing photos: the chosen ones.
    @State private var selection: Set<String>?
    @State private var confirmDelete = false
    @State private var note: String?

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationTitle("Photos")
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
                        Button("Remove from iPhone") {
                            let removed = app.removeFromPhone(Array(selection))
                            note =
                                removed == selection.count
                                ? "Removed from this iPhone; still on the server."
                                : "\(removed) of \(selection.count) removed. The others aren't safely on the server yet."
                            self.selection = []
                        }
                        .disabled(app.removableFromPhone(Array(selection)) == 0)
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Text("\(selection.count) chosen").font(.footnote)
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                            .disabled(selection.isEmpty)
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
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .photo(let id): PhotoView(start: id, assets: app.library)
                case .withoutPlace: WithoutPlaceView()
                case .uploads: UploadsView()
                case .trash: TrashView()
                }
            }
        }
    }
}
