import AVFoundation
import AVKit
import HaldenKit
import SwiftUI

#if canImport(Cinematic)
    import Cinematic
#endif

/// Post-capture Cinematic Video focus & depth-of-field editor.
/// Uses Apple's `Cinematic.framework` (`CNAssetInfo`, `CNScript`, `CNDecision`) on real iOS
/// devices to read/update `fNumber` and subject focus transitions, while persisting the chosen
/// f-stop and tap-to-refocus timeline markers non-destructively in `EditRecipe`.
struct CinematicEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let asset: LocalAsset

    @State private var player: AVPlayer?
    #if canImport(Cinematic)
        @State private var script: CNScript?
    #endif
    @State private var aperture: Double
    @State private var focusPoints: [CinematicFocusPoint]
    @State private var currentTimeMs: Int64 = 0
    @State private var durationMs: Int64
    @State private var saving = false
    @State private var statusNote: String?

    init(asset: LocalAsset) {
        self.asset = asset
        _aperture = State(initialValue: asset.edit?.cinematicAperture ?? CinematicRules.defaultAperture)
        _focusPoints = State(initialValue: asset.edit?.cinematicFocusPoints ?? [])
        _durationMs = State(initialValue: max(1000, asset.durationMs ?? 3000))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                videoStage
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

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Depth of field", systemImage: "f.cursive")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(CinematicRules.formatAperture(aperture))
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(.yellow)
                    }
                    Slider(
                        value: Binding(
                            get: { aperture },
                            set: { value in
                                aperture = CinematicRules.clampedAperture(value)
                                #if canImport(Cinematic)
                                    script?.fNumber = Float(aperture)
                                #endif
                            }),
                        in: CinematicRules.apertureRange
                    )
                    .tint(.yellow)
                    .accessibilityLabel("Cinematic depth f-stop")
                    .accessibilityIdentifier("cinematic-editor-aperture")
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Timeline")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(formatTime(currentTimeMs))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(currentTimeMs) },
                            set: { value in
                                currentTimeMs = Int64(value.rounded())
                                let time = CMTime(value: currentTimeMs, timescale: 1000)
                                player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                            }),
                        in: 0...Double(max(durationMs, 1000))
                    )
                    .accessibilityLabel("Video timeline")
                    .accessibilityIdentifier("cinematic-editor-timeline")
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Focus shifts (\(focusPoints.count))")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !focusPoints.isEmpty {
                            Button("Clear all") {
                                focusPoints = []
                                #if canImport(Cinematic)
                                    script?.removeAllUserDecisions()
                                #endif
                            }
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("cinematic-editor-clear")
                        }
                    }
                    if focusPoints.isEmpty {
                        Text("Tap anywhere on the video frame to shift focus at the current time.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(focusPoints) { pt in
                                    Button {
                                        currentTimeMs = pt.timeMs
                                        player?.seek(to: CMTime(value: pt.timeMs, timescale: 1000))
                                    } label: {
                                        Label(formatTime(pt.timeMs), systemImage: "scope")
                                            .font(.caption.monospacedDigit())
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 36)
                                            .background(.secondary.opacity(0.16), in: .capsule)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Cinematic Focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cinematic-editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving)
                        .accessibilityIdentifier("cinematic-editor-save")
                }
            }
            .task { await loadAsset() }
        }
    }

    private var videoStage: some View {
        GeometryReader { geo in
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Color.black
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.5))
                }
                // Tap overlay to place a Cinematic focus decision at the current timestamp.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { location in
                        let nx = min(max(location.x / max(geo.size.width, 1), 0), 1)
                        let ny = min(max(location.y / max(geo.size.height, 1), 0), 1)
                        addFocusShift(nx: nx, ny: ny)
                    }
                    .accessibilityIdentifier("cinematic-editor-stage")

                if let active = nearestFocusPoint() {
                    Rectangle()
                        .strokeBorder(.yellow, lineWidth: 2)
                        .frame(width: 56, height: 56)
                        .position(x: active.x * geo.size.width, y: active.y * geo.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func loadAsset() async {
        guard let avAsset = app.playable(asset) else {
            statusNote = "Video file is not downloaded on this iPhone yet."
            return
        }
        player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
        if let dur = try? await avAsset.load(.duration), dur.seconds.isFinite, dur.seconds > 0 {
            durationMs = max(1000, Int64((dur.seconds * 1000).rounded()))
        }
        #if canImport(Cinematic)
            let isCinematic = await CNAssetInfo.isCinematic(asset: avAsset)
            if isCinematic, let loaded = try? await CNScript(asset: avAsset) {
                script = loaded
                if asset.edit?.cinematicAperture == nil {
                    aperture = CinematicRules.clampedAperture(Double(loaded.fNumber))
                } else {
                    loaded.fNumber = Float(aperture)
                }
                statusNote = "Cinematic depth track loaded (\(CinematicRules.formatAperture(aperture)))."
                return
            }
        #endif
        statusNote = "Saved non-destructively in Halden's edit recipe."
    }

    private func addFocusShift(nx: Double, ny: Double) {
        let point = CinematicFocusPoint(timeMs: currentTimeMs, x: nx, y: ny).fitted
        focusPoints.removeAll { abs($0.timeMs - currentTimeMs) < 250 }
        focusPoints.append(point)
        focusPoints.sort { $0.timeMs < $1.timeMs }

        #if canImport(Cinematic)
            // Apply directly to the real Cinematic script when a detected subject is near the tap.
            if let script {
                let cmTime = CMTime(value: currentTimeMs, timescale: 1000)
                let tol = CMTime(value: 200, timescale: 1000)
                if let frame = script.frame(at: cmTime, tolerance: tol) {
                    let target = CGPoint(x: nx, y: 1.0 - ny)
                    if let match = frame.allDetections.min(by: { a, b in
                        hypot(a.normalizedRect.midX - target.x, a.normalizedRect.midY - target.y)
                            < hypot(b.normalizedRect.midX - target.x, b.normalizedRect.midY - target.y)
                    }), let detectionID = match.detectionID {
                        _ = script.addUserDecision(CNDecision(time: cmTime, detectionID: detectionID, strong: true))
                    }
                }
            }
        #endif
    }

    private func nearestFocusPoint() -> CinematicFocusPoint? {
        focusPoints.min(by: { abs($0.timeMs - currentTimeMs) < abs($1.timeMs - currentTimeMs) })
    }

    private func save() {
        saving = true
        var recipe = asset.edit ?? EditRecipe()
        recipe.cinematicAperture = CinematicRules.clampedAperture(aperture)
        recipe.cinematicFocusPoints = focusPoints.isEmpty ? nil : focusPoints
        app.setEdit(asset.id, recipe.isEmpty ? nil : recipe)
        dismiss()
    }

    private func formatTime(_ ms: Int64) -> String {
        let totalSeconds = Double(ms) / 1000.0
        let mins = Int(totalSeconds) / 60
        let secs = totalSeconds - Double(mins * 60)
        return String(format: "%d:%04.1f", mins, secs)
    }
}
