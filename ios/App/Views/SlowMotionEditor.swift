import HaldenKit
import SwiftUI

/// Where a slow-motion video is slow, and how slow. Only how it plays changes; the video stays
/// as it was recorded, and "As recorded" brings back the slow part it started with.
struct SlowMotionEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let asset: LocalAsset
    @State private var slow: SlowMotion?
    @State private var standard: SlowMotion?

    private var durationMs: Int64 { max(asset.durationMs ?? 1000, 200) }

    var body: some View {
        NavigationStack {
            Form {
                if let slow {
                    Section {
                        LabeledContent("Slow from", value: Self.seconds(slow.slowFromMs))
                        Slider(value: milliseconds(\.slowFromMs), in: 0...Double(durationMs))
                            .accessibilityIdentifier("slow-from")
                        LabeledContent("Slow until", value: Self.seconds(slow.slowToMs))
                        Slider(value: milliseconds(\.slowToMs), in: 0...Double(durationMs))
                            .accessibilityIdentifier("slow-to")
                        Picker("How slow", selection: rate) {
                            Text("½").tag(0.5)
                            Text("¼").tag(0.25)
                            Text("⅛").tag(0.125)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("slow-rate")
                    } footer: {
                        Text(
                            "Plays for \(Self.seconds(slow.playedMs(of: durationMs))). The video itself stays as it was recorded."
                        )
                    }
                    Section {
                        Button("As recorded") { self.slow = standard }
                            .disabled(slow == standard)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Slow motion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let slow {
                            // The standard needs no correction: then it follows the video.
                            app.setPlayback(asset.id, slow == standard ? nil : slow.fitted(to: durationMs))
                        }
                        dismiss()
                    }
                    .disabled(slow == nil)
                    .accessibilityIdentifier("save-slow-motion")
                }
            }
            .task {
                let standard = await app.standardSlowMotion(for: asset)
                self.standard = standard
                slow = (asset.playback ?? standard).fitted(to: durationMs)
            }
        }
    }

    private func milliseconds(_ keyPath: WritableKeyPath<SlowMotion, Int64>) -> Binding<Double> {
        Binding(
            get: { Double(slow?[keyPath: keyPath] ?? 0) },
            set: { value in slow?[keyPath: keyPath] = Int64(value.rounded()) })
    }

    private var rate: Binding<Double> {
        Binding(get: { slow?.rate ?? 0.125 }, set: { value in slow?.rate = value })
    }

    static func seconds(_ milliseconds: Int64) -> String {
        (Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }
}
