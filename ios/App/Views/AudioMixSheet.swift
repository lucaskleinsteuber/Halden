import AVFoundation
import AVKit
import HaldenKit
import SwiftUI

#if canImport(Cinematic)
    import Cinematic
#endif

/// Post-capture Spatial Audio Mix sheet for videos recorded with Spatial Audio (`firstOrderAmbisonics`).
/// Uses Apple's `Cinematic.framework` (`CNAssetSpatialAudioInfo.audioMix`) on supported iOS devices
/// to audition mixes live, while storing the chosen style and intensity non-destructively in `EditRecipe`.
struct AudioMixSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let asset: LocalAsset

    @State private var style: AudioMixStyle
    @State private var intensity: Double
    @State private var player: AVPlayer?
    @State private var statusNote: String?
    #if canImport(Cinematic)
        @State private var spatialInfo: CNAssetSpatialAudioInfo?
    #endif

    init(asset: LocalAsset) {
        self.asset = asset
        _style = State(initialValue: asset.edit?.audioMix ?? .standard)
        _intensity = State(initialValue: asset.edit?.audioMixIntensity ?? ProDeviceRules.defaultAudioMixIntensity)
    }

    static var isSupportedOnThisDevice: Bool {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-basic-device") { return false }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing")
            || ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in")
        {
            return true
        }
        #if canImport(Cinematic)
            return CNAssetSpatialAudioInfo.isSupported
        #else
            return false
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        Color.black
                        Image(systemName: "waveform")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .padding(.horizontal)

                if let statusNote {
                    Text(statusNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                VStack(spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(AudioMixStyle.allCases) { option in
                            let selected = option == style
                            Button {
                                style = option
                                applyPreviewMix()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: option.symbol)
                                        .font(.body.weight(.semibold))
                                    Text(option.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .padding(.horizontal, 10)
                                .foregroundStyle(selected ? .black : .primary)
                                .background(
                                    selected ? Color.yellow : Color.secondary.opacity(0.14),
                                    in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("audio-mix-\(option.rawValue)")
                        }
                    }

                    Text(style.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)

                if style != .standard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Mix intensity")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int((intensity * 100).rounded()))%")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(.yellow)
                        }
                        Slider(
                            value: Binding(
                                get: { intensity },
                                set: { value in
                                    intensity = ProDeviceRules.clampAudioMixIntensity(value)
                                    applyPreviewMix()
                                }),
                            in: 0...1
                        )
                        .tint(.yellow)
                        .accessibilityLabel("Audio Mix intensity")
                        .accessibilityIdentifier("audio-mix-intensity")
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Audio Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("audio-mix-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("audio-mix-save")
                }
            }
            .task { await loadAudio() }
        }
    }

    private func loadAudio() async {
        guard let avAsset = app.playable(asset) else {
            statusNote = "Video is not downloaded yet; mix settings will still save non-destructively."
            return
        }
        player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
        #if canImport(Cinematic)
            if await CNAssetSpatialAudioInfo.assetContainsSpatialAudio(asset: avAsset),
                let info = try? await CNAssetSpatialAudioInfo(asset: avAsset)
            {
                spatialInfo = info
                applyPreviewMix()
                statusNote = "Spatial Audio track loaded for live Audio Mix audition."
                return
            }
        #endif
        statusNote = "Saved non-destructively in Halden's edit recipe."
    }

    private func applyPreviewMix() {
        #if canImport(Cinematic)
            guard let spatialInfo, let item = player?.currentItem else { return }
            let rendering: CNSpatialAudioRenderingStyle =
                switch style {
                case .standard: .standard
                case .inFrame: .inFrame
                case .studio: .studio
                case .cinematic: .cinematic
                }
            item.audioMix = spatialInfo.audioMix(effectIntensity: Float(intensity), renderingStyle: rendering)
        #endif
    }

    private func save() {
        var recipe = asset.edit ?? EditRecipe()
        recipe.audioMix = style == .standard ? nil : style
        recipe.audioMixIntensity = style == .standard ? nil : ProDeviceRules.clampAudioMixIntensity(intensity)
        app.setEdit(asset.id, recipe.isEmpty ? nil : recipe)
        dismiss()
    }
}
