import HaldenKit
import SwiftUI

/// Movable Picture-in-Picture secondary camera window and Dual Capture controls (swap + photo/video).
struct DualPreviewOverlay: View {
    @Binding var corner: PiPCorner
    @Binding var kind: DualCaptureKind
    let swapped: Bool
    let recording: Bool
    /// Read here (not by the camera screen), since the small picture changes many times a second.
    let backend: any CaptureBackend
    let onSwap: () -> Void

    private var pipImage: UIImage? { backend.dualPipImage }

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let rect = PiPLayout.rect(in: geo.size, corner: corner)
            let targetCenter = CGPoint(x: rect.midX + dragOffset.width, y: rect.midY + dragOffset.height)
            let clamped = PiPLayout.clamp(center: targetCenter, pipSize: rect.size, in: geo.size)

            ZStack {
                // Draggable Picture-in-Picture window.
                ZStack(alignment: .bottomLeading) {
                    if let pipImage {
                        Image(uiImage: pipImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: swapped ? [.indigo, .teal] : [.orange, .pink],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    Text(swapped ? "BACK" : "FRONT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .capsule)
                        .padding(6)
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                .position(clamped)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in dragOffset = value.translation }
                        .onEnded { value in
                            let end = CGPoint(
                                x: rect.midX + value.translation.width, y: rect.midY + value.translation.height)
                            withAnimation(.snappy(duration: 0.25)) {
                                corner = PiPLayout.nearestCorner(for: end, in: geo.size)
                                dragOffset = .zero
                            }
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(swapped ? "Back camera picture in picture" : "Front camera picture in picture")
                .accessibilityIdentifier("dual-pip-window")

                // Top pill: Photo/Video toggle + Swap lenses, opposite the PiP when PiP is at the top.
                if !recording {
                    let pillAlignment: Alignment =
                        switch corner {
                        case .topRight: .topLeading
                        case .topLeft: .topTrailing
                        case .bottomLeft, .bottomRight: .top
                        }
                    VStack {
                        HStack(spacing: 8) {
                            Button {
                                kind = kind == .photo ? .video : .photo
                            } label: {
                                Label(kind.title, systemImage: kind.symbol)
                                    .font(.caption.bold())
                                    .foregroundStyle(.yellow)
                                    .padding(.horizontal, 12)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .background(.black.opacity(0.65), in: .capsule)
                            }
                            .accessibilityLabel("Dual capture \(kind.title)")
                            .accessibilityIdentifier("dual-kind-toggle")

                            Button {
                                onSwap()
                            } label: {
                                Image(systemName: "rectangle.2.swap")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.65), in: .circle)
                            }
                            .accessibilityLabel("Swap dual cameras")
                            .accessibilityIdentifier("dual-swap")
                        }
                        .frame(maxWidth: .infinity, alignment: pillAlignment)
                        .padding(.horizontal, 14)
                        .padding(.top, 32)
                        Spacer()
                    }
                }
            }
        }
    }
}

/// Dimmed ultra-wide surround shown outside the active viewfinder crop when "View Outside the Frame"
/// is enabled in Photo mode at zoom >= 1×.
struct OutsideFrameOverlay: View {
    let zoom: Double

    var body: some View {
        GeometryReader { geo in
            let inset = max(10, geo.size.width * OutsideFrameMath.surroundPaddingFraction(zoom: zoom) * 0.45)
            ZStack {
                Color.black.opacity(0.42)
                    .mask(
                        Rectangle()
                            .overlay(
                                Rectangle()
                                    .inset(by: inset)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )
                Rectangle()
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                    .padding(inset)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
