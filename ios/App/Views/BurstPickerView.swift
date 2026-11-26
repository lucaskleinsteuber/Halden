import HaldenKit
import SwiftUI

/// Lets the user inspect every shot in a burst, choose which ones to keep, and move the rest to
/// the trash (as in Apple's Photos burst picker).
struct BurstPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let members: [LocalAsset]

    @State private var focusedId: String
    @State private var keeping: Set<String>
    @State private var previewImage: UIImage?
    @State private var thumbnails: [String: UIImage] = [:]

    init(members: [LocalAsset]) {
        self.members = members
        let first = members.first?.id ?? ""
        _focusedId = State(initialValue: first)
        _keeping = State(initialValue: first.isEmpty ? [] : [first])
    }

    private var focused: LocalAsset? {
        members.first { $0.id == focusedId } ?? members.first
    }

    private var isFocusedKept: Bool {
        keeping.contains(focusedId)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                preview
                keepToggle
                filmstrip
            }
            .padding(.vertical, 12)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Select Favorites (\(keeping.count)/\(members.count))")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("burst-picker-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let trash = Bursts.toTrash(members: members, keeping: keeping)
                        if !trash.isEmpty { app.moveToTrash(trash) }
                        dismiss()
                    }
                    .disabled(keeping.isEmpty)
                    .accessibilityIdentifier("burst-picker-done")
                }
            }
            .task(id: focusedId) {
                guard let asset = focused else { return }
                if let rendered = await app.pipeline.image(for: asset, pixels: 1024) {
                    previewImage = UIImage(cgImage: rendered.cgImage)
                }
            }
            .task {
                for asset in members {
                    if let rendered = await app.pipeline.image(for: asset, pixels: 180) {
                        thumbnails[asset.id] = UIImage(cgImage: rendered.cgImage)
                    }
                }
            }
        }
    }

    private var preview: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("burst-picker-preview")
    }

    private var keepToggle: some View {
        Button {
            if isFocusedKept {
                keeping.remove(focusedId)
            } else {
                keeping.insert(focusedId)
            }
        } label: {
            Label(
                isFocusedKept ? "Selected to Keep" : "Keep This Photo",
                systemImage: isFocusedKept ? "checkmark.circle.fill" : "circle"
            )
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(minWidth: 44, minHeight: 44)
            .background(isFocusedKept ? Color.accentColor : Color.secondary.opacity(0.18), in: .capsule)
            .foregroundStyle(isFocusedKept ? .white : .primary)
        }
        .accessibilityIdentifier("burst-toggle-keep")
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, item in
                    let isSelected = keeping.contains(item.id)
                    let isCurrent = item.id == focusedId
                    Button {
                        focusedId = item.id
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let thumb = thumbnails[item.id] {
                                    Image(uiImage: thumb).resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.25)
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2.5)
                            }
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white, Color.accentColor)
                                    .padding(4)
                            }
                        }
                        .frame(minWidth: 64, minHeight: 64)
                    }
                    .accessibilityLabel("Burst photo \(index + 1)\(isSelected ? ", selected" : "")")
                    .accessibilityIdentifier("burst-item-\(index)")
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 72)
    }
}
