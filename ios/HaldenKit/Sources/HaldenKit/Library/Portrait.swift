import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

/// Portrait lighting effects, built in Halden from depth/matte and Vision face detection so they
/// can be applied live and changed non-destructively after capture.
public enum PortraitLighting: String, Codable, Sendable, CaseIterable, Identifiable {
    case natural
    case studio
    case contour
    case stage
    case stageMono
    case highKeyMono

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .natural: "Natural"
        case .studio: "Studio"
        case .contour: "Contour"
        case .stage: "Stage"
        case .stageMono: "Stage Mono"
        case .highKeyMono: "High-Key Mono"
        }
    }

    public var symbol: String {
        switch self {
        case .natural: "cube"
        case .studio: "sun.max"
        case .contour: "circle.lefthalf.filled"
        case .stage: "circle.inset.filled"
        case .stageMono: "circle.fill"
        case .highKeyMono: "circle"
        }
    }
}

/// Live guidance hints shown in Portrait mode when distance or lighting isn't ideal.
public enum PortraitHint: String, Sendable, Equatable {
    case moveFartherAway = "Move farther away."
    case placeSubjectCloser = "Place subject within 2.5 m."
    case moreLightRequired = "More light required."
}

/// Pure rules for Portrait aperture (f/1.4–f/16), blur mapping, and live subject distance hints.
public enum PortraitMath {
    public static let apertureRange: ClosedRange<Double> = 1.4...16.0
    public static let defaultAperture = 4.5
    public static let apertureStops: [Double] = [
        1.4, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10, 11, 13, 14, 16,
    ]

    public static func clampedAperture(_ value: Double) -> Double {
        let clamped = min(max(value, apertureRange.lowerBound), apertureRange.upperBound)
        return (clamped * 10).rounded() / 10
    }

    public static func formatAperture(_ f: Double) -> String {
        let clamped = clampedAperture(f)
        return clamped >= 10 && clamped == clamped.rounded()
            ? "f/\(Int(clamped))" : String(format: "f/%.1f", clamped)
    }

    /// Maps an f-number (1.4…16) to a Core Image blur radius for fallback / matte-based bokeh
    /// (strongest at f/1.4, virtually sharp at f/16).
    public static func blurRadius(forAperture f: Double, imageMaxEdge: Double = 1000) -> Double {
        let clamped = clampedAperture(f)
        let normalized = (log2(16.0) - log2(clamped)) / (log2(16.0) - log2(1.4))
        let scale = max(imageMaxEdge / 1000.0, 0.4)
        return max(0, normalized * 18.0 * scale)
    }

    /// Evaluates subject distance (meters) and scene light (ISO) for Apple-style Portrait guidance.
    public static func hint(distanceMeters: Double?, iso: Double?) -> PortraitHint? {
        if let d = distanceMeters {
            if d > 0 && d < 0.45 { return .moveFartherAway }
            if d > 2.5 { return .placeSubjectCloser }
        }
        if let iso, iso > 2400 { return .moreLightRequired }
        return nil
    }
}

/// Core Image + Vision portrait bokeh and portrait lighting renderer.
public enum PortraitRenderer {
    /// Extracts embedded disparity/depth map and portrait effects matte from a HEIC/JPEG file,
    /// when captured with depth delivery.
    public static func extractAuxiliary(from url: URL) -> (depth: CIImage?, matte: CIImage?) {
        let depth =
            CIImage(contentsOf: url, options: [.auxiliaryDisparity: true])
            ?? CIImage(contentsOf: url, options: [.auxiliaryDepth: true])
        let matte = CIImage(contentsOf: url, options: [.auxiliaryPortraitEffectsMatte: true])
        return (depth, matte)
    }

    /// Detects normalized face rectangles (0…1, Core Image bottom-left origin) using Vision.
    public static func detectFaces(in image: CIImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
            let results = request.results
        else { return [] }
        return results.map(\.boundingBox)
    }

    /// Applies depth-of-field blur (`aperture`, f/1.4–f/16) and/or Portrait Lighting (`lighting`)
    /// using real depth/matte maps when available, or a face-centered subject mask fallback.
    public static func apply(
        to image: CIImage, depthMap: CIImage? = nil, matte: CIImage? = nil,
        aperture: Double?, lighting: PortraitLighting?, faceRects: [CGRect] = []
    ) -> CIImage {
        let hasBlur = aperture != nil
        let hasLighting = lighting != nil && lighting != .natural
        guard hasBlur || hasLighting else { return image }

        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let mask = subjectMask(for: extent, matte: matte, depthMap: depthMap, faceRects: faceRects)
        var output = image

        // 1. Depth-of-field background blur
        if let aperture {
            let clamped = PortraitMath.clampedAperture(aperture)
            if let depthMap,
                let blur = CIFilter(name: "CIDepthBlurEffect")
            {
                blur.setValue(output, forKey: kCIInputImageKey)
                blur.setValue(depthMap, forKey: "inputDisparityImage")
                if let matte { blur.setValue(matte, forKey: "inputMatteImage") }
                blur.setValue(Float(clamped), forKey: "inputAperture")
                if let rendered = blur.outputImage?.cropped(to: extent) {
                    output = rendered
                }
            } else {
                let radius = PortraitMath.blurRadius(
                    forAperture: clamped, imageMaxEdge: Double(max(extent.width, extent.height)))
                if radius > 0.4 {
                    let blurred =
                        output
                        .clampedToExtent()
                        .applyingGaussianBlur(sigma: radius)
                        .cropped(to: extent)
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = output
                    blend.backgroundImage = blurred
                    blend.maskImage = mask
                    output = blend.outputImage?.cropped(to: extent) ?? output
                }
            }
        }

        // 2. Portrait Lighting (matte/face-guided subject & background relighting)
        if let lighting, lighting != .natural {
            output = applyLighting(lighting, to: output, mask: mask, extent: extent)
        }
        return output
    }

    private static func subjectMask(
        for extent: CGRect, matte: CIImage?, depthMap: CIImage?, faceRects: [CGRect]
    ) -> CIImage {
        if let matte, matte.extent.width > 0, matte.extent.height > 0 {
            let sx = extent.width / matte.extent.width
            let sy = extent.height / matte.extent.height
            return
                matte
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(
                    by: CGAffineTransform(
                        translationX: extent.minX - matte.extent.minX * sx,
                        y: extent.minY - matte.extent.minY * sy)
                )
                .cropped(to: extent)
        }
        if let depthMap, depthMap.extent.width > 0, depthMap.extent.height > 0 {
            let sx = extent.width / depthMap.extent.width
            let sy = extent.height / depthMap.extent.height
            return
                depthMap
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .cropped(to: extent)
        }
        // Fallback soft portrait oval centered on detected face (or upper-middle of frame).
        let center: CGPoint
        let radius: CGFloat
        if let face = faceRects.first {
            center = CGPoint(
                x: extent.minX + face.midX * extent.width,
                y: extent.minY + face.midY * extent.height)
            radius = max(face.width * extent.width, face.height * extent.height) * 1.15
        } else {
            center = CGPoint(x: extent.midX, y: extent.minY + extent.height * 0.56)
            radius = min(extent.width, extent.height) * 0.34
        }
        let radial = CIFilter.radialGradient()
        radial.center = center
        radial.radius0 = Float(radius * 0.65)
        radial.radius1 = Float(radius * 1.45)
        radial.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        radial.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        return radial.outputImage?.cropped(to: extent) ?? CIImage(color: .white).cropped(to: extent)
    }

    private static func applyLighting(
        _ lighting: PortraitLighting, to image: CIImage, mask: CIImage, extent: CGRect
    ) -> CIImage {
        switch lighting {
        case .natural:
            return image
        case .studio:
            let exp = CIFilter.exposureAdjust()
            exp.inputImage = image
            exp.ev = 0.28
            let lit = exp.outputImage?.cropped(to: extent) ?? image
            let blend = CIFilter.blendWithMask()
            blend.inputImage = lit
            blend.backgroundImage = image
            blend.maskImage = mask
            return blend.outputImage?.cropped(to: extent) ?? image
        case .contour:
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.contrast = 1.24
            cc.brightness = -0.02
            let sculpted = cc.outputImage?.cropped(to: extent) ?? image
            let darkBg = CIFilter.exposureAdjust()
            darkBg.inputImage = image
            darkBg.ev = -0.35
            let blend = CIFilter.blendWithMask()
            blend.inputImage = sculpted
            blend.backgroundImage = darkBg.outputImage?.cropped(to: extent) ?? image
            blend.maskImage = mask
            return blend.outputImage?.cropped(to: extent) ?? image
        case .stage:
            let black = CIImage(color: .black).cropped(to: extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image
            blend.backgroundImage = black
            blend.maskImage = mask
            return blend.outputImage?.cropped(to: extent) ?? image
        case .stageMono:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let cc = CIFilter.colorControls()
            cc.inputImage = mono.outputImage ?? image
            cc.contrast = 1.18
            let subject = cc.outputImage?.cropped(to: extent) ?? image
            let black = CIImage(color: .black).cropped(to: extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = subject
            blend.backgroundImage = black
            blend.maskImage = mask
            return blend.outputImage?.cropped(to: extent) ?? image
        case .highKeyMono:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = image
            let exp = CIFilter.exposureAdjust()
            exp.inputImage = mono.outputImage ?? image
            exp.ev = 0.22
            let cc = CIFilter.colorControls()
            cc.inputImage = exp.outputImage ?? image
            cc.contrast = 1.22
            let subject = cc.outputImage?.cropped(to: extent) ?? image
            let white = CIImage(color: .white).cropped(to: extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = subject
            blend.backgroundImage = white
            blend.maskImage = mask
            return blend.outputImage?.cropped(to: extent) ?? image
        }
    }
}
