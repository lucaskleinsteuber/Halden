import HaldenKit
import MapKit
import SwiftUI

/// Photos and videos without a place: choose some, then give them the place of the photo taken
/// nearest in time (marked as estimated) or one tapped on the map.
struct WithoutPlaceView: View {
    @Environment(AppModel.self) private var app
    @State private var assets: [LocalAsset] = []
    @State private var selected: Set<String> = []
    @State private var suggestions: [String: PlaceSuggestion] = [:]
    @State private var choosing = false
    @State private var chosen: CLLocationCoordinate2D?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets, id: \.id) { asset in
                    PlaceCell(
                        asset: asset, selected: selected.contains(asset.id), suggested: suggestions[asset.id] != nil
                    )
                    .onTapGesture {
                        if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
                    }
                }
            }
        }
        .overlay {
            if assets.isEmpty {
                ContentUnavailableView(
                    "Every photo has a place", systemImage: "mappin.and.ellipse",
                    description: Text("Photos without a place show up here."))
            }
        }
        .navigationTitle("Without place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selected.count == assets.count && !assets.isEmpty ? "Select none" : "Select all") {
                    selected = selected.count == assets.count ? [] : Set(assets.map(\.id))
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Use suggestions (\(suggestedCount))") { useSuggestions() }
                    .disabled(suggestedCount == 0)
                    .accessibilityIdentifier("use-suggestions")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Choose place…") { choosing = true }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("choose-place")
            }
        }
        .task(id: app.libraryVersion) {
            assets = app.library.filter { !$0.hasLocation }
            selected.formIntersection(assets.map(\.id))
        }
        .task { suggestions = await app.placeSuggestions() }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                PlacePicker(place: $chosen)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Where were they taken?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Set") {
                                if let chosen {
                                    app.setPlace(
                                        Array(selected),
                                        CorrectedLocation(latitude: chosen.latitude, longitude: chosen.longitude))
                                    selected = []
                                }
                                choosing = false
                            }
                            .disabled(chosen == nil)
                        }
                    }
            }
        }
    }

    /// Selected photos that have a suggestion (all with a suggestion when none is selected).
    private var suggestedIds: [String] {
        let pool = selected.isEmpty ? assets.map(\.id) : Array(selected)
        return pool.filter { suggestions[$0] != nil }
    }

    private var suggestedCount: Int { suggestedIds.count }

    /// Photos with the same suggestion go to the server together.
    private func useSuggestions() {
        var groups: [String: (CorrectedLocation, [String])] = [:]
        for id in suggestedIds {
            guard let suggestion = suggestions[id] else { continue }
            let key = "\(suggestion.latitude),\(suggestion.longitude)"
            let place = CorrectedLocation(
                latitude: suggestion.latitude, longitude: suggestion.longitude, estimated: true)
            groups[key, default: (place, [])].1.append(id)
        }
        for (place, ids) in groups.values { app.setPlace(ids, place) }
        selected = []
    }
}

private struct PlaceCell: View {
    @Environment(AppModel.self) private var app
    let asset: LocalAsset
    let selected: Bool
    let suggested: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.white, selected ? .blue : .black.opacity(0.3))
                    .padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                if suggested {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.white, .orange).padding(4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(suggested ? "Photo, a place is suggested" : "Photo")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task {
                if let decoded = await app.pipeline.image(for: asset, pixels: 300) {
                    image = UIImage(cgImage: decoded.cgImage)
                }
            }
    }
}
