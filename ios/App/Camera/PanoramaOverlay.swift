import HaldenKit
import SwiftUI

/// Apple-style Panorama guide strip in the center of the viewfinder:
/// - Yellow center line with tappable direction arrow (tap reverses direction)
/// - Orientation button (Horizontal / Vertical sweep)
/// - Live progress bar, off-axis arrow offset, and CoreMotion hints ("Move slower.", "Keep arrow on the line.")
struct PanoramaOverlay: View {
    let direction: PanoramaDirection
    let capturing: Bool
    let stitching: Bool
    let progress: Double
    let offAxis: Double
    let hint: PanoramaHint?
    let onReverse: () -> Void
    let onToggleOrientation: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if stitching {
                HStack(spacing: 8) {
                    ProgressView().tint(.yellow)
                    Text("Stitching panorama…")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.72), in: .capsule)
                .accessibilityIdentifier("panorama-stitching")
            } else if let hint {
                Text(hint.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.yellow, in: .capsule)
                    .accessibilityIdentifier("panorama-hint")
            }

            if direction.isVertical {
                verticalStrip
            } else {
                horizontalStrip
            }

            if !capturing && !stitching {
                Button(action: onToggleOrientation) {
                    Label(
                        direction.isVertical ? "Vertical" : "Horizontal",
                        systemImage: direction.isVertical ? "arrow.up.and.down" : "arrow.left.and.right"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.black.opacity(0.68), in: .capsule)
                }
                .accessibilityLabel(
                    direction.isVertical
                        ? "Vertical panorama, switch to horizontal"
                        : "Horizontal panorama, switch to vertical"
                )
                .accessibilityIdentifier("panorama-orientation")
            }
        }
        .padding(.horizontal, 20)
    }

    private var horizontalStrip: some View {
        let stripWidth: CGFloat = 280
        let stripHeight: CGFloat = 58
        let fillWidth = max(0, min(stripWidth, stripWidth * CGFloat(progress)))
        let arrowX: CGFloat =
            direction == .leftToRight
            ? -stripWidth / 2 + 28 + (stripWidth - 56) * CGFloat(progress)
            : stripWidth / 2 - 28 - (stripWidth - 56) * CGFloat(progress)
        let arrowY = capturing ? CGFloat(offAxis) * 18 : 0

        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.58))
                .frame(width: stripWidth, height: stripHeight)

            // Progress fill
            HStack(spacing: 0) {
                if direction == .rightToLeft { Spacer(minLength: 0) }
                Rectangle()
                    .fill(.yellow.opacity(0.28))
                    .frame(width: fillWidth, height: stripHeight)
                if direction == .leftToRight { Spacer(minLength: 0) }
            }
            .frame(width: stripWidth, height: stripHeight)
            .clipShape(.rect(cornerRadius: 8))

            // Yellow center guide line
            Rectangle()
                .fill(.yellow)
                .frame(width: stripWidth - 16, height: 1.5)

            // Tappable arrow button (min 44×44 pt)
            Button(action: onReverse) {
                Image(systemName: direction.arrowSymbol)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: .circle)
            }
            .disabled(capturing || stitching)
            .offset(x: arrowX, y: arrowY)
            .accessibilityLabel("\(direction.accessibilityTitle), tap to reverse")
            .accessibilityIdentifier("panorama-direction")
        }
        .frame(width: stripWidth, height: stripHeight)
    }

    private var verticalStrip: some View {
        let stripWidth: CGFloat = 58
        let stripHeight: CGFloat = 200
        let fillHeight = max(0, min(stripHeight, stripHeight * CGFloat(progress)))
        let arrowY: CGFloat =
            direction == .bottomToTop
            ? stripHeight / 2 - 28 - (stripHeight - 56) * CGFloat(progress)
            : -stripHeight / 2 + 28 + (stripHeight - 56) * CGFloat(progress)
        let arrowX = capturing ? CGFloat(offAxis) * 18 : 0

        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.58))
                .frame(width: stripWidth, height: stripHeight)

            VStack(spacing: 0) {
                if direction == .bottomToTop { Spacer(minLength: 0) }
                Rectangle()
                    .fill(.yellow.opacity(0.28))
                    .frame(width: stripWidth, height: fillHeight)
                if direction == .topToBottom { Spacer(minLength: 0) }
            }
            .frame(width: stripWidth, height: stripHeight)
            .clipShape(.rect(cornerRadius: 8))

            Rectangle()
                .fill(.yellow)
                .frame(width: 1.5, height: stripHeight - 16)

            Button(action: onReverse) {
                Image(systemName: direction.arrowSymbol)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: .circle)
            }
            .disabled(capturing || stitching)
            .offset(x: arrowX, y: arrowY)
            .accessibilityLabel("\(direction.accessibilityTitle), tap to reverse")
            .accessibilityIdentifier("panorama-direction")
        }
        .frame(width: stripWidth, height: stripHeight)
    }
}
