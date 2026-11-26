import HaldenKit
import SwiftUI
import UIKit

/// Apple-style picker for non-destructive Live Photo effects (Live, Loop, Bounce, Long Exposure)
/// and choosing a Key Photo frame from the paired video.
struct LivePhotoEffectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let asset: LocalAsset

    @State private var selectedEffect: LivePhotoEffect
    @State private var durationMs: Int64 = 1500
    @State private var keyFrameMs: Double
    @State private var keyFrameEdited = false
    @State private var scrubberImages: [UIImage] = []
    @State private var previewImage: UIImage?
    @State private var busy = false
    @State private var problem: String?

    init(asset: LocalAsset) {
        self.asset = asset
        _selectedEffect = State(initialValue: asset.activeLiveEffect)
        _keyFrameMs = State(initialValue: Double(asset.edit?.liveKeyFrameMs ?? 0))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    previewCard
                    effectSelector
                    keyPhotoSection
                    if let problem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Live Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(busy)
                        .accessibilityIdentifier("live-effect-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        apply()
                    } label: {
                        if busy {
                            ProgressView()
                        } else {
                            Text("Apply").bold()
                        }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("live-effect-apply")
                }
            }
            .task { await loadMedia() }
        }
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
                .frame(height: 220)
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(.rect(cornerRadius: 14))
            } else {
                Image(systemName: selectedEffect.symbol)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            VStack {
                HStack {
                    Label(selectedEffect.title.uppercased(), systemImage: selectedEffect.symbol)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: .capsule)
                    Spacer()
                }
                Spacer()
            }
            .padding(10)
        }
    }

    private var effectSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effect")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(LivePhotoEffect.allCases) { effect in
                    let active = selectedEffect == effect
                    Button {
                        selectedEffect = effect
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: effect.symbol)
                                .font(.body.weight(.semibold))
                            Text(effect.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(active ? .black : .primary)
                        .background(
                            active ? Color.yellow : Color(.secondarySystemBackground),
                            in: .rect(cornerRadius: 12))
                    }
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .accessibilityIdentifier("live-effect-\(effect.rawValue)")
                }
            }
        }
    }

    private var keyPhotoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Key Photo")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.2f s", keyFrameMs / 1000.0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !scrubberImages.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(scrubberImages.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                            .clipped()
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
            }
            Slider(
                value: Binding(
                    get: { keyFrameMs },
                    set: { newValue in
                        keyFrameMs = newValue
                        keyFrameEdited = true
                    }),
                in: 0...Double(max(durationMs, 100))
            )
            .accessibilityLabel("Key photo frame")
            .accessibilityIdentifier("live-keyframe-slider")
            Text(
                selectedEffect == .live
                    ? "Move the slider to choose a different frame as the key photo. The original Live Photo stays untouched."
                    : "The effect is rendered on this iPhone and synced non-destructively; you can revert to Live at any time."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func loadMedia() async {
        if let decoded = await app.pipeline.image(for: asset, pixels: 512) {
            previewImage = UIImage(cgImage: decoded.cgImage)
        }
        guard let video = try? await app.media.pairedVideo(of: asset) else { return }
        let ms = await LivePhotoEffectRenderer.durationMs(of: video)
        if ms > 0 {
            durationMs = ms
            if keyFrameMs > Double(ms) { keyFrameMs = Double(ms) }
        }
        let thumbs = await LivePhotoEffectRenderer.scrubberFrames(of: video, count: 8)
        scrubberImages = thumbs.map { UIImage(cgImage: $0) }
    }

    private func apply() {
        busy = true
        problem = nil
        let effect = selectedEffect
        let chosenKeyMs: Int64? = keyFrameEdited ? Int64(keyFrameMs.rounded()) : asset.edit?.liveKeyFrameMs
        Task {
            defer { busy = false }
            do {
                try await app.applyLiveEffect(asset.id, effect: effect, keyFrameMs: chosenKeyMs)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
