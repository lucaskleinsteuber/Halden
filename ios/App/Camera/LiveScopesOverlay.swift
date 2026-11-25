import HaldenKit
import SwiftUI

/// Compact live RGB+Luma Histogram and Luma Waveform HUD rendered from the demand-driven Metal
/// viewfinder frames. Non-interactive (`allowsHitTesting(false)`) so it never blocks camera touches.
struct LiveScopesOverlay: View {
    let data: LiveScopesData
    let showHistogram: Bool
    let showWaveform: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if showHistogram {
                histogramView
            }
            if showWaveform {
                waveformView
            }
        }
        .allowsHitTesting(false)
    }

    private var histogramView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("HIST")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                if data.clippedHighlights > 0.05 {
                    Circle().fill(.red).frame(width: 5, height: 5)
                }
            }
            Canvas { ctx, size in
                drawCurve(data.red, color: .red.opacity(0.55), in: ctx, size: size)
                drawCurve(data.green, color: .green.opacity(0.55), in: ctx, size: size)
                drawCurve(data.blue, color: .blue.opacity(0.55), in: ctx, size: size)
                drawCurve(data.luma, color: .white.opacity(0.75), strokeOnly: true, in: ctx, size: size)
            }
            .frame(width: 108, height: 42)
        }
        .padding(6)
        .background(.black.opacity(0.62), in: .rect(cornerRadius: 8))
        .accessibilityElement()
        .accessibilityLabel("Live histogram")
        .accessibilityIdentifier("live-histogram")
    }

    private var waveformView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WAVEFORM")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            Canvas { ctx, size in
                let cols = data.waveformMean.count
                guard cols > 1 else { return }
                // 0 / 50 / 100 IRE guide lines
                for level in [0.0, 0.5, 1.0] {
                    let y = size.height * (1 - level)
                    var guide = Path()
                    guide.move(to: CGPoint(x: 0, y: y))
                    guide.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(guide, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                }
                let step = size.width / CGFloat(cols - 1)
                var band = Path()
                for i in 0..<cols {
                    let x = CGFloat(i) * step
                    let yMax = size.height * CGFloat(1 - data.waveformMax[i])
                    if i == 0 {
                        band.move(to: CGPoint(x: x, y: yMax))
                    } else {
                        band.addLine(to: CGPoint(x: x, y: yMax))
                    }
                }
                for i in stride(from: cols - 1, through: 0, by: -1) {
                    let x = CGFloat(i) * step
                    let yMin = size.height * CGFloat(1 - data.waveformMin[i])
                    band.addLine(to: CGPoint(x: x, y: yMin))
                }
                band.closeSubpath()
                ctx.fill(band, with: .color(.green.opacity(0.35)))

                var meanPath = Path()
                for i in 0..<cols {
                    let x = CGFloat(i) * step
                    let y = size.height * CGFloat(1 - data.waveformMean[i])
                    if i == 0 {
                        meanPath.move(to: CGPoint(x: x, y: y))
                    } else {
                        meanPath.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                ctx.stroke(meanPath, with: .color(.green.opacity(0.95)), lineWidth: 1.2)
            }
            .frame(width: 108, height: 42)
        }
        .padding(6)
        .background(.black.opacity(0.62), in: .rect(cornerRadius: 8))
        .accessibilityElement()
        .accessibilityLabel("Live waveform")
        .accessibilityIdentifier("live-waveform")
    }

    private func drawCurve(
        _ bins: [Float], color: Color, strokeOnly: Bool = false, in ctx: GraphicsContext, size: CGSize
    ) {
        guard bins.count > 1 else { return }
        let step = size.width / CGFloat(bins.count - 1)
        var path = Path()
        if !strokeOnly { path.move(to: CGPoint(x: 0, y: size.height)) }
        for (i, value) in bins.enumerated() {
            let x = CGFloat(i) * step
            let y = size.height * CGFloat(1 - min(max(value, 0), 1))
            if strokeOnly && i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if strokeOnly {
            ctx.stroke(path, with: .color(color), lineWidth: 1)
        } else {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(color))
        }
    }
}
