import HaldenKit
import SwiftUI

/// Every photo, newest first, with a check mark once it is safely on the server.
struct PhotosView: View {
    enum Route: Hashable {
        case photo(String)
        case withoutPlace
        case uploads
    }

    @Environment(AppModel.self) private var app
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            LibraryGrid(
                assets: app.library, version: app.libraryVersion, uploads: app.uploads, pipeline: app.pipeline
            ) { id in
                path.append(.photo(id))
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Without place", systemImage: "mappin.slash") { path.append(.withoutPlace) }
                            .accessibilityIdentifier("without-place")
                        Button("Uploads", systemImage: "arrow.up.circle") { path.append(.uploads) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("photos-menu")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .photo(let id): PhotoView(start: id, assets: app.library)
                case .withoutPlace: WithoutPlaceView()
                case .uploads: UploadsView()
                }
            }
        }
    }
}
