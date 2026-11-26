import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which corner the Picture-in-Picture secondary camera window snaps to in Dual Capture mode.
public enum PiPCorner: String, Codable, Sendable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var id: String { rawValue }
}

/// Whether Dual Capture takes a composited still photo or records a composited video.
public enum DualCaptureKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case photo, video

    public var id: String { rawValue }

    public var title: String { self == .photo ? "Photo" : "Video" }
    public var symbol: String { self == .photo ? "camera.fill" : "video.fill" }
}

/// Pure geometry helpers for placing, clamping and corner-snapping the Dual Capture PiP window.
public enum PiPLayout {
    public static let defaultScale: CGFloat = 0.28
    public static let defaultMargin: CGFloat = 14

    /// Rect for the PiP window inside `container` (top-left origin, SwiftUI/UIKit coordinates).
    public static func rect(
        in container: CGSize, corner: PiPCorner, scale: CGFloat = defaultScale, margin: CGFloat = defaultMargin
    ) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        let clampedScale = min(max(scale, 0.15), 0.45)
        let w = (container.width * clampedScale).rounded()
        let h = (w * 4.0 / 3.0).rounded()
        let maxH = max(44, container.height - margin * 2)
        let finalH = min(h, maxH)
        let x: CGFloat =
            (corner == .topLeft || corner == .bottomLeft) ? margin : max(margin, container.width - w - margin)
        let y: CGFloat =
            (corner == .topLeft || corner == .topRight) ? margin : max(margin, container.height - finalH - margin)
        return CGRect(x: x, y: y, width: w, height: finalH)
    }

    /// Snaps a dragged point to whichever quadrant corner of `container` is closest.
    public static func nearestCorner(for point: CGPoint, in container: CGSize) -> PiPCorner {
        let left = point.x < container.width / 2
        let top = point.y < container.height / 2
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// Clamps a live drag center so the PiP window never leaves `container` bounds.
    public static func clamp(
        center: CGPoint, pipSize: CGSize, in container: CGSize, margin: CGFloat = defaultMargin
    ) -> CGPoint {
        let minX = margin + pipSize.width / 2
        let maxX = max(minX, container.width - margin - pipSize.width / 2)
        let minY = margin + pipSize.height / 2
        let maxY = max(minY, container.height - margin - pipSize.height / 2)
        return CGPoint(x: min(max(center.x, minX), maxX), y: min(max(center.y, minY), maxY))
    }
}

/// Geometry and activation rules for "View Outside the Frame" (dimmed ultra-wide surround).
public enum OutsideFrameMath {
    /// Active in Photo mode when enabled, an ultra-wide lens is available, and zoom is at least 1×.
    public static func isActive(enabled: Bool, isPhotoMode: Bool, zoom: Double, hasUltraWide: Bool) -> Bool {
        enabled && isPhotoMode && hasUltraWide && zoom >= 0.99
    }

    /// Fraction of the ultra-wide field of view covered by the active zoom (0.5 at 1×, 0.25 at 2×).
    public static func innerFraction(zoom: Double, ultraWideZoom: Double = 0.5) -> Double {
        let safeZoom = max(zoom, ultraWideZoom)
        return min(max(ultraWideZoom / safeZoom, 0.1), 1.0)
    }

    /// Expansion ratio applied to an ultra-wide surround layer behind the viewfinder frame.
    public static func surroundPaddingFraction(zoom: Double) -> Double {
        // Gentle fixed visual margin (like Apple's Camera) while scaling slightly with zoom.
        zoom >= 1.0 ? min(0.14 + (zoom - 1.0) * 0.02, 0.22) : 0
    }
}

/// Composites primary + secondary (PiP) camera frames into a single image or HEIC/JPEG file.
public enum DualCompositor {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Composites `secondary` as a rounded Picture-in-Picture overlay inside `primary`.
    /// Note: `CIImage` uses bottom-left origin; `corner` uses UI top-left semantics and is mapped cleanly.
    public static func composite(
        primary: CIImage, secondary: CIImage, corner: PiPCorner, scale: CGFloat = PiPLayout.defaultScale
    ) -> CIImage {
        let base = primary.transformed(
            by: CGAffineTransform(translationX: -primary.extent.origin.x, y: -primary.extent.origin.y))
        let canvas = base.extent
        guard canvas.width > 4, canvas.height > 4 else { return base }

        let margin = max(12, (min(canvas.width, canvas.height) * 0.03).rounded())
        let uiRect = PiPLayout.rect(in: canvas.size, corner: corner, scale: scale, margin: margin)
        // Flip Y from top-left UI coordinates into Core Image bottom-left coordinates.
        let ciRect = CGRect(
            x: uiRect.origin.x,
            y: canvas.height - uiRect.origin.y - uiRect.height,
            width: uiRect.width,
            height: uiRect.height)

        let secNorm = secondary.transformed(
            by: CGAffineTransform(translationX: -secondary.extent.origin.x, y: -secondary.extent.origin.y))
        guard secNorm.extent.width > 0, secNorm.extent.height > 0 else { return base }

        // Aspect-fill secondary into ciRect.
        let sx = ciRect.width / secNorm.extent.width
        let sy = ciRect.height / secNorm.extent.height
        let fillScale = max(sx, sy)
        let scaled = secNorm.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        let dx = ciRect.midX - scaled.extent.midX
        let dy = ciRect.midY - scaled.extent.midY
        let placed = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: ciRect)

        // Subtle crisp border behind the PiP rect.
        let borderThickness = max(2, (ciRect.width * 0.015).rounded())
        let borderRect = ciRect.insetBy(dx: -borderThickness, dy: -borderThickness).intersection(canvas)
        let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85)).cropped(to: borderRect)
        let withBorder = border.composited(over: base)
        return placed.composited(over: withBorder).cropped(to: canvas)
    }

    /// Composites and encodes a Dual Capture still photo as HEIC (with JPEG fallback).
    public static func encodePhoto(
        primary: CIImage, secondary: CIImage, corner: PiPCorner, preferHEIC: Bool = true
    ) -> (data: Data, heic: Bool, width: Int, height: Int)? {
        let merged = composite(primary: primary, secondary: secondary, corner: corner)
        let width = Int(merged.extent.width.rounded())
        let height = Int(merged.extent.height.rounded())
        guard width > 0, height > 0, let cg = ciContext.createCGImage(merged, from: merged.extent) else { return nil }
        let formats: [(UTType, Bool)] = preferHEIC ? [(.heic, true), (.jpeg, false)] : [(.jpeg, false)]
        for (utType, isHeic) in formats {
            let out = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(out, utType.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                if CGImageDestinationFinalize(dest), out.length > 0 {
                    return (out as Data, isHeic, width, height)
                }
            }
        }
        return nil
    }
}
