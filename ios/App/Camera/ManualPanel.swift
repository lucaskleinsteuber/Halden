import HaldenKit
import SwiftUI

/// What the camera is doing right now, also when it decides itself: shown on the manual panel.
struct CameraReadings: Equatable, Sendable {
    var shutter: Double?
    var iso: Double?
    var kelvin: Double?
    var tint: Double?
    var focus: Double?
}

/// Manual control, value by value: ISO, shutter speed, white balance, focus and exposure
/// compensation. Every value shows what the camera does now (white when automatic, yellow when
/// set); a tap chooses it for the slider, "Auto" gives it back to the camera.
struct ManualPanel: View {
    enum Value: String, CaseIterable, Identifiable {
        case exposureBias, iso, shutter, whiteBalance, focus
        var id: String { rawValue }
    }

    let camera: CameraModel
    @Binding var chosen: Value?
    /// While the focus is turned: show the picture bigger, to see what is sharp.
    @Binding var focusing: Bool

    private var state: CameraState { camera.backend.state }
    private var manual: ManualSettings { camera.manual }

    var body: some View {
        if let limits = state.manualLimits {
            VStack(spacing: 8) {
                if let chosen { slider(for: chosen, limits: limits).transition(.opacity) }
                HStack(spacing: 6) {
                    ForEach(Value.allCases) { value in
                        if available(value, limits) { chip(value) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .animation(.snappy(duration: 0.2), value: chosen)
        }
    }

    private func available(_ value: Value, _ limits: ManualLimits) -> Bool {
        switch value {
        case .focus: limits.canFocus
        case .whiteBalance: limits.canSetWhiteBalance
        default: true
        }
    }

    private func isSet(_ value: Value) -> Bool {
        switch value {
        case .exposureBias: manual.exposureBias != 0
        case .iso: manual.iso != nil
        case .shutter: manual.shutter != nil
        case .whiteBalance: manual.whiteBalance != nil
        case .focus: manual.focus != nil
        }
    }

    private func text(_ value: Value) -> String {
        let readings = camera.backend.readings
        switch value {
        case .exposureBias: return "EV " + ManualText.bias(manual.exposureBias)
        case .iso: return (manual.iso ?? readings.iso).map(ManualText.iso) ?? "ISO"
        case .shutter: return (manual.shutter ?? readings.shutter).map(ManualText.shutter) ?? "Shutter"
        case .whiteBalance: return (manual.whiteBalance?.kelvin ?? readings.kelvin).map(ManualText.kelvin) ?? "WB"
        case .focus:
            let focus = manual.focus ?? readings.focus
            return focus.map { "F \(Int(($0 * 100).rounded()))" } ?? "Focus"
        }
    }

    private func chip(_ value: Value) -> some View {
        let set = isSet(value)
        return Button {
            chosen = chosen == value ? nil : value
        } label: {
            Text(text(value))
                .font(.caption2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(set ? .yellow : .white)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    chosen == value ? Color.white.opacity(0.3) : Color.black.opacity(0.5), in: .capsule)
        }
        .accessibilityLabel(text(value))
        .accessibilityValue(set ? "set" : "automatic")
        .accessibilityIdentifier("manual-\(value.rawValue)")
    }

    @ViewBuilder private func slider(for value: Value, limits: ManualLimits) -> some View {
        HStack(spacing: 10) {
            Button("Auto") { change(value, to: nil) }
                .font(.caption.bold())
                .foregroundStyle(isSet(value) ? .white : .yellow)
                .accessibilityIdentifier("manual-auto")
            switch value {
            case .exposureBias:
                Slider(
                    value: binding {
                        manual.exposureBias
                    } set: {
                        change(.exposureBias, to: ($0 * 3).rounded() / 3)
                    },
                    in: max(limits.exposureBias.lowerBound, -3)...min(limits.exposureBias.upperBound, 3))
            case .iso:
                stepped(limits.isoSteps, current: manual.iso ?? camera.backend.readings.iso) { change(.iso, to: $0) }
            case .shutter:
                stepped(limits.shutterSteps, current: manual.shutter ?? camera.backend.readings.shutter) {
                    change(.shutter, to: $0)
                }
            case .whiteBalance:
                VStack(spacing: 2) {
                    Slider(
                        value: binding {
                            manual.whiteBalance?.kelvin ?? camera.backend.readings.kelvin ?? 5000
                        } set: { kelvin in
                            camera.setManual { settings in
                                settings.whiteBalance = .init(kelvin: kelvin, tint: settings.whiteBalance?.tint ?? 0)
                            }
                        },
                        in: ManualLimits.whiteBalanceKelvin)
                    Slider(
                        value: binding {
                            manual.whiteBalance?.tint ?? 0
                        } set: { tint in
                            camera.setManual { settings in
                                settings.whiteBalance = .init(
                                    kelvin: settings.whiteBalance?.kelvin ?? camera.backend.readings.kelvin ?? 5000,
                                    tint: tint)
                            }
                        },
                        in: ManualLimits.whiteBalanceTint)
                }
            case .focus:
                Slider(
                    value: binding {
                        manual.focus ?? camera.backend.readings.focus ?? 0.5
                    } set: {
                        change(.focus, to: $0)
                    },
                    in: 0...1
                ) { editing in
                    focusing = editing
                }
            }
        }
        .tint(.yellow)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manual-slider")
    }

    /// A slider over fixed steps (ISO in thirds, the usual shutter speeds).
    private func stepped(_ steps: [Double], current: Double?, set: @escaping @MainActor @Sendable (Double) -> Void)
        -> some View
    {
        let index =
            current.flatMap { value in
                steps.indices.min { abs(log2(steps[$0] / value)) < abs(log2(steps[$1] / value)) }
            } ?? steps.count / 2
        return Slider(
            value: binding {
                Double(index)
            } set: { position in
                let step = Int(position.rounded())
                if steps.indices.contains(step) { set(steps[step]) }
            },
            in: 0...Double(max(steps.count - 1, 1)), step: 1)
    }

    private func binding(
        get: @escaping @MainActor @Sendable () -> Double, set: @escaping @MainActor @Sendable (Double) -> Void
    )
        -> Binding<Double>
    {
        Binding(get: get, set: set)
    }

    private func change(_ value: Value, to number: Double?) {
        camera.setManual { settings in
            switch value {
            case .exposureBias: settings.exposureBias = number ?? 0
            case .iso: settings.iso = number
            case .shutter: settings.shutter = number
            case .focus: settings.focus = number
            case .whiteBalance:
                settings.whiteBalance = number.map { .init(kelvin: $0, tint: settings.whiteBalance?.tint ?? 0) }
            }
        }
    }
}
