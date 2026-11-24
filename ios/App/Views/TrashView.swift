import GRDB
import HaldenKit
import SwiftUI

/// What was deleted: the same on every device, restorable until it is deleted for good, by hand
/// or after the days the owner set.
struct TrashView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [LocalAsset] = []
    @State private var selected: Set<String> = []
    @State private var observation: AnyDatabaseCancellable?
    @State private var confirm: [String]?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        ScrollView {
            Text("Photos here are deleted for good after \(app.trashDays) days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items, id: \.id) { asset in
                    TrashCell(asset: asset, selected: selected.contains(asset.id), daysLeft: daysLeft(asset))
                        .onTapGesture {
                            if selected.contains(asset.id) {
                                selected.remove(asset.id)
                            } else {
                                selected.insert(asset.id)
                            }
                        }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("The trash is empty", systemImage: "trash")
                    .accessibilityIdentifier("trash-empty")
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Restore") {
                    app.restore(chosen)
                    selected = []
                }
                .disabled(items.isEmpty)
                .accessibilityIdentifier("restore")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(selected.isEmpty ? "Delete all" : "Delete", role: .destructive) { confirm = chosen }
                    .disabled(items.isEmpty)
                    .accessibilityIdentifier("delete-for-good")
            }
        }
        .confirmationDialog(
            "Delete \(confirm?.count ?? 0) for good?",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible
        ) {
            Button("Delete for good", role: .destructive) {
                app.deleteForGood(confirm ?? [])
                selected = []
                confirm = nil
            }
            .accessibilityIdentifier("confirm-delete-for-good")
        } message: {
            Text("They are removed from the server and every device. This can't be undone.")
        }
        .onAppear(perform: watch)
        .onDisappear { observation = nil }
    }

    /// The chosen ones, or all when none is chosen.
    private var chosen: [String] {
        selected.isEmpty ? items.map(\.id) : Array(selected)
    }

    private func daysLeft(_ asset: LocalAsset) -> Int {
        guard let trashedAt = asset.trashedAt else { return app.trashDays }
        let gone = Double(trashedAt) / 1000 + Double(app.trashDays) * 86_400
        return max(0, Int((gone - Date().timeIntervalSince1970) / 86_400) + 1)
    }

    private func watch() {
        observation =
            ValueObservation
            .tracking { db in
                try LocalAsset.filter(sql: "trashedAt IS NOT NULL AND deletedAt IS NULL")
                    .order(sql: "trashedAt DESC").fetchAll(db)
            }
            .start(in: app.database.writer, scheduling: .async(onQueue: .main)) { _ in
            } onChange: { found in
                MainActor.assumeIsolated {
                    items = found
                    selected.formIntersection(found.map(\.id))
                }
            }
    }
}

private struct TrashCell: View {
    @Environment(AppModel.self) private var app
    let asset: LocalAsset
    let selected: Bool
    let daysLeft: Int
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(daysLeft == 1 ? "1 day" : "\(daysLeft) days")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.white, selected ? .blue : .black.opacity(0.3))
                    .padding(4)
            }
            .accessibilityElement()
            .accessibilityLabel("\(asset.isVideo ? "Video" : "Photo"), \(daysLeft) days left")
            .accessibilityIdentifier("trashed-\(asset.id)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .task {
                if let decoded = await app.pipeline.image(for: asset, pixels: 300) {
                    image = UIImage(cgImage: decoded.cgImage)
                }
            }
    }
}
