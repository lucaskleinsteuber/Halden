import HaldenKit
import SwiftUI

/// Apple-style Photographic Style selector with a 2D Tone / Color control pad and a Palette
/// intensity slider. Shared between the in-camera control drawer and the photo editor (`EditView`).
struct StylePadView: View {
    @Binding var style: PhotographicStyle?
    var compact: Bool = true

    private var current: PhotographicStyle {
        style ?? PhotographicStyle()
    }

    var body: some View {
        VStack(spacing: 8) {
            // Preset picker strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotographicStylePreset.allCases) { preset in
                        let selected = current.preset == preset
                        Button {
                            var next = current
                            next.preset = preset
                            if preset == .standard && abs(next.tone) < 0.005 && abs(next.color) < 0.005 {
                                style = nil
                            } else {
                                style = next
                            }
                        } label: {
                            Text(preset.title)
                                .font(.caption.bold())
                                .lineLimit(1)
                                .foregroundStyle(selected ? .black : .white)
                                .padding(.horizontal, 12)
                                .frame(minWidth: 44, minHeight: 44)
                                .background(selected ? Color.yellow : Color.white.opacity(0.14), in: .capsule)
                        }
                        .accessibilityIdentifier("style-preset-\(preset.rawValue)")
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 44)

            // 2D Tone / Color pad + Palette slider
            HStack(spacing: 12) {
                toneColorPad
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tone \(signed(current.tone))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        // Black and white has no colour to turn up or down.
                        if !current.preset.isMonochrome {
                            Text("Color \(signed(current.color))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    // Standard has no character of its own for the palette to scale.
                    if current.preset != .standard {
                        HStack(spacing: 6) {
                            Text("Palette")
                                .font(.caption2.bold())
                                .foregroundStyle(.white.opacity(0.85))
                            Slider(
                                value: Binding(
                                    get: { current.palette },
                                    set: { value in
                                        var next = current
                                        next.palette = value
                                        style = next.isDefault ? nil : next
                                    }),
                                in: 0...1
                            )
                            .tint(.yellow)
                            .accessibilityLabel("Style palette")
                            .accessibilityIdentifier("style-palette-slider")
                        }
                    }
                    Button {
                        style = nil
                    } label: {
                        Text("Reset Style")
                            .font(.caption.bold())
                            .foregroundStyle(current.isDefault ? .white.opacity(0.45) : .yellow)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white.opacity(0.12), in: .capsule)
                    }
                    .disabled(current.isDefault)
                    .accessibilityIdentifier("style-reset")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.black.opacity(compact ? 0.72 : 0.45), in: .rect(cornerRadius: 14))
        .padding(.horizontal, compact ? 12 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("style-pad")
    }

    private var toneColorPad: some View {
        let size: CGFloat = compact ? 92 : 112
        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let x = CGFloat((current.color + 1) / 2) * w
            let y = CGFloat((1 - current.tone) / 2) * h
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.08))
                // Subtle 3×3 grid inside pad
                Path { path in
                    for frac in [0.25, 0.5, 0.75] {
                        path.move(to: CGPoint(x: w * frac, y: 0))
                        path.addLine(to: CGPoint(x: w * frac, y: h))
                        path.move(to: CGPoint(x: 0, y: h * frac))
                        path.addLine(to: CGPoint(x: w, y: h * frac))
                    }
                }
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
                Circle()
                    .fill(.yellow)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: min(max(x, 7), w - 7), y: min(max(y, 7), h - 7))
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let color = min(max((value.location.x / w) * 2 - 1, -1), 1)
                        let tone = min(max(1 - (value.location.y / h) * 2, -1), 1)
                        var next = current
                        next.color = current.preset.isMonochrome ? 0 : (color * 20).rounded() / 20
                        next.tone = (tone * 20).rounded() / 20
                        style = next.isDefault ? nil : next
                    }
            )
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Tone and Color pad")
        .accessibilityValue("Tone \(signed(current.tone)), Color \(signed(current.color))")
        .accessibilityIdentifier("style-tone-color-pad")
    }

    private func signed(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return pct > 0 ? "+\(pct)" : "\(pct)"
    }
}

/// The filters as small pictures, each showing the live picture (or the photo being edited) with
/// that filter, Original first; shared by the camera and the editor. Without a picture, plain
/// buttons with the names.
struct FilterStripView: View {
    @Binding var filter: PhotoFilter?
    /// A small picture to show each filter on (the camera's live picture, a few times a second).
    var sample: CGImage? = nil
    /// The style applied underneath, so the tiles look like the result.
    var style: PhotographicStyle? = nil
    /// Small pictures (with a placeholder until the first sample arrives) instead of names; the
    /// strip keeps one height either way, so nothing moves when the pictures come.
    var pictures = false
    @State private var tiles = FilterTiles()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tile(nil, title: "Original", id: "filter-original")
                    ForEach(PhotoFilter.allCases) { item in
                        tile(item, title: item.title, id: "filter-\(item.rawValue)")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: pictures ? 84 : 44)
        .task(id: TileKey(sample: sample.map(ObjectIdentifier.init), style: style)) {
            await tiles.render(sample: sample, style: style)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filter-strip")
    }

    private struct TileKey: Equatable {
        var sample: ObjectIdentifier?
        var style: PhotographicStyle?
    }

    @ViewBuilder private func tile(_ item: PhotoFilter?, title: String, id: String) -> some View {
        let selected = filter == item
        Button {
            filter = item
        } label: {
            if pictures {
                VStack(spacing: 3) {
                    ZStack {
                        Color.white.opacity(0.1)
                        if let image = tiles.images[item?.rawValue ?? "original"] {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.yellow : .clear, lineWidth: 2))
                    Text(title)
                        .font(.caption2.weight(selected ? .bold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? .yellow : .white)
                }
                .frame(minWidth: 56)
                .contentShape(.rect)
                .accessibilityElement(children: .ignore)
            } else {
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? .black : .white)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(selected ? Color.yellow : Color.black.opacity(0.65), in: .capsule)
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// Renders the filter tiles off the main thread whenever the sample changes.
@MainActor
@Observable
final class FilterTiles {
    private(set) var images: [String: CGImage] = [:]

    func render(sample: CGImage?, style: PhotographicStyle?) async {
        guard let sample else {
            images = [:]
            return
        }
        let rendered = await Task.detached(priority: .userInitiated) { () -> [String: CGImage] in
            let base = CIImage(cgImage: sample)
            let side = min(base.extent.width, base.extent.height)
            let square = base.cropped(
                to: CGRect(
                    x: base.extent.midX - side / 2, y: base.extent.midY - side / 2, width: side, height: side))
            var result: [String: CGImage] = [:]
            for item in [nil] + PhotoFilter.allCases.map(Optional.some) {
                let looked = LookRenderer.apply(style: style, filter: item, to: square).cropped(to: square.extent)
                if let image = ImagePipeline.editContext.createCGImage(looked, from: square.extent) {
                    result[item?.rawValue ?? "original"] = image
                }
            }
            return result
        }.value
        if !Task.isCancelled { images = rendered }
    }
}
