import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Direction of a panorama sweep (horizontal or vertical; reversible by tapping the arrow).
public enum PanoramaDirection: String, Codable, Sendable, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft
    case bottomToTop
    case topToBottom

    public var id: String { rawValue }

    public var isVertical: Bool {
        self == .bottomToTop || self == .topToBottom
    }

    /// Reverses the sweep direction along the same axis (tap arrow).
    public var reversed: PanoramaDirection {
        switch self {
        case .leftToRight: .rightToLeft
        case .rightToLeft: .leftToRight
        case .bottomToTop: .topToBottom
        case .topToBottom: .bottomToTop
        }
    }

    /// Switches between horizontal and vertical panorama capture.
    public var toggledOrientation: PanoramaDirection {
        switch self {
        case .leftToRight: .bottomToTop
        case .rightToLeft: .topToBottom
        case .bottomToTop: .leftToRight
        case .topToBottom: .rightToLeft
        }
    }

    public var arrowSymbol: String {
        switch self {
        case .leftToRight: "arrow.right"
        case .rightToLeft: "arrow.left"
        case .bottomToTop: "arrow.up"
        case .topToBottom: "arrow.down"
        }
    }

    public var accessibilityTitle: String {
        switch self {
        case .leftToRight: "Sweep right"
        case .rightToLeft: "Sweep left"
        case .bottomToTop: "Sweep up"
        case .topToBottom: "Sweep down"
        }
    }
}

/// Live CoreMotion guidance messages during a panorama sweep.
public enum PanoramaHint: String, Sendable, Equatable {
    case moveSlower = "Move slower."
    case keepOnLine = "Keep arrow on the line."
}

/// CoreMotion state machine tracking panorama progress, off-axis drift and speed warnings.
public struct PanoramaGuide: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public let progress: Double
        public let offAxisNormalized: Double
        public let hint: PanoramaHint?
        public let sweepDeltaRadians: Double
        public let completed: Bool
    }

    /// Full panorama sweep angle (~210°).
    public static let maxSweepRadians = 3.65
    /// Angular speed above which "Move slower." is shown (rad/s, ~37°/s).
    public static let maxAngularSpeed = 0.65
    /// Off-axis angular drift above which "Keep arrow on the line." is shown (~4.3°).
    public static let maxOffAxisRadians = 0.075

    public private(set) var sweptRadians = 0.0
    public private(set) var offAxisRadians = 0.0

    public init() {}

    public mutating func reset() {
        sweptRadians = 0
        offAxisRadians = 0
    }

    /// Integrates gyroscope rotation rates (`rad/s`) over `dt` seconds.
    public mutating func update(
        rotationX: Double, rotationY: Double, rotationZ: Double,
        dt: Double, direction: PanoramaDirection
    ) -> Reading {
        guard dt > 0 else {
            return Reading(
                progress: min(max(sweptRadians / Self.maxSweepRadians, 0), 1),
                offAxisNormalized: min(max(offAxisRadians / (Self.maxOffAxisRadians * 2), -1), 1),
                hint: nil, sweepDeltaRadians: 0, completed: sweptRadians >= Self.maxSweepRadians)
        }
        let primaryRate: Double
        let offAxisRate: Double
        switch direction {
        case .leftToRight:
            primaryRate = -rotationY
            offAxisRate = rotationX
        case .rightToLeft:
            primaryRate = rotationY
            offAxisRate = rotationX
        case .bottomToTop:
            primaryRate = rotationX
            offAxisRate = rotationY
        case .topToBottom:
            primaryRate = -rotationX
            offAxisRate = rotationY
        }

        let delta = max(0, primaryRate * dt)
        sweptRadians += delta
        offAxisRadians += offAxisRate * dt

        let speed = abs(primaryRate)
        let hint: PanoramaHint? =
            if speed > Self.maxAngularSpeed {
                .moveSlower
            } else if abs(offAxisRadians) > Self.maxOffAxisRadians {
                .keepOnLine
            } else {
                nil
            }

        let progress = min(max(sweptRadians / Self.maxSweepRadians, 0), 1)
        let offNorm = min(max(offAxisRadians / (Self.maxOffAxisRadians * 2), -1), 1)
        return Reading(
            progress: progress, offAxisNormalized: offNorm, hint: hint,
            sweepDeltaRadians: delta, completed: progress >= 1.0)
    }
}

/// Aligns a sequence of overlapping video-output frames using Vision translational registration
/// combined with gyroscope shift hints, blends strips with linear alpha feathering, and encodes
/// the finished panorama as HEIC.
public enum PanoramaStitcher {
    public struct StitchResult: Sendable {
        public let data: Data
        public let heic: Bool
        public let width: Int
        public let height: Int
        public let frameCount: Int
        public let peakMemoryBytes: UInt64
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let maxCanvasEdge = 8192

    /// Returns the process's current resident memory in bytes (for benchmarking).
    public static func currentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Stitches sequential overlapping `frames` along `direction` into a seamless HEIC panorama.
    /// Optional `gyroHints` (one per transition `1..<frames.count`) act as prior/fallback pixel shifts
    /// when a frame has very little visual texture.
    public static func stitch(
        frames: [CIImage], direction: PanoramaDirection,
        gyroHints: [CGVector]? = nil, preferHEIC: Bool = true
    ) -> StitchResult? {
        guard let first = frames.first else { return nil }
        let frameW = Int(first.extent.width.rounded())
        let frameH = Int(first.extent.height.rounded())
        guard frameW > 16, frameH > 16 else { return nil }

        let targetRect = CGRect(x: 0, y: 0, width: frameW, height: frameH)
        // Materialize each frame to a clean origin-zero CGImage once so Vision registration
        // never sees virtual Core Image crop/transform offsets.
        let cgFrames: [CGImage] = frames.compactMap { frame in
            let norm = normalize(frame, to: targetRect)
            return ciContext.createCGImage(norm, from: targetRect)
        }
        guard !cgFrames.isEmpty else { return nil }
        var peakMem = currentMemoryBytes()

        // Single-frame fallback: encode directly.
        if cgFrames.count == 1 {
            guard let encoded = encode(cgFrames[0], preferHEIC: preferHEIC) else { return nil }
            return StitchResult(
                data: encoded.data, heic: encoded.heic, width: frameW, height: frameH,
                frameCount: 1, peakMemoryBytes: max(peakMem, currentMemoryBytes()))
        }

        // 1. Pairwise Vision translational registration + gyro fallback/validation.
        var positions: [CGPoint] = [.zero]
        positions.reserveCapacity(cgFrames.count)
        let primaryLimit = CGFloat(direction.isVertical ? frameH : frameW) * 0.78
        let secondaryLimit = CGFloat(direction.isVertical ? frameW : frameH) * 0.25

        for i in 1..<cgFrames.count {
            let shift: CGVector = autoreleasepool {
                let prev = cgFrames[i - 1]
                let curr = cgFrames[i]
                let hint = (gyroHints != nil && (i - 1) < gyroHints!.count) ? gyroHints![i - 1] : nil
                return registerShift(
                    from: prev, to: curr, direction: direction, hint: hint,
                    primaryLimit: primaryLimit, secondaryLimit: secondaryLimit)
            }
            let last = positions[i - 1]
            positions.append(CGPoint(x: last.x + shift.dx, y: last.y + shift.dy))
        }

        // 2. Compute canvas bounds (Core Image y-up converted to RGBA bitmap y-down).
        let downPositions = positions.map { CGPoint(x: $0.x, y: -$0.y) }
        let minX = Int(floor(downPositions.map(\.x).min() ?? 0))
        let maxX = Int(ceil((downPositions.map(\.x).max() ?? 0) + CGFloat(frameW)))
        let minY = Int(floor(downPositions.map(\.y).min() ?? 0))
        let maxY = Int(ceil((downPositions.map(\.y).max() ?? 0) + CGFloat(frameH)))

        let rawW = maxX - minX
        let rawH = maxY - minY
        guard rawW > 0, rawH > 0 else { return nil }

        // Cap canvas edge if an extreme sweep exceeds maxCanvasEdge.
        let scale = min(1.0, Double(maxCanvasEdge) / Double(max(rawW, rawH)))
        let canvasW = max(1, Int((Double(rawW) * scale).rounded()))
        let canvasH = max(1, Int((Double(rawH) * scale).rounded()))

        // 3. Render each frame into RGBA8 and feather-blend strips onto the canvas.
        var canvas = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
        var weight = [Float](repeating: 0, count: canvasW * canvasH)
        let scaledW = max(1, Int((Double(frameW) * scale).rounded()))
        let scaledH = max(1, Int((Double(frameH) * scale).rounded()))
        var frameBuf = [UInt8](repeating: 0, count: scaledW * scaledH * 4)
        let featherPx = Float(min(max((direction.isVertical ? scaledH : scaledW) / 6, 16), 96))

        for (index, cgFrame) in cgFrames.enumerated() {
            autoreleasepool {
                let img = CIImage(cgImage: cgFrame)
                let scaledImg: CIImage =
                    scale < 0.999
                    ? img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    : img
                ciContext.render(
                    scaledImg, toBitmap: &frameBuf, rowBytes: scaledW * 4,
                    bounds: CGRect(x: 0, y: 0, width: scaledW, height: scaledH),
                    format: .RGBA8, colorSpace: colorSpace)
            }

            let originX = Int(((downPositions[index].x - CGFloat(minX)) * scale).rounded())
            let originY = Int(((downPositions[index].y - CGFloat(minY)) * scale).rounded())

            let xStart = max(0, originX)
            let xEnd = min(canvasW, originX + scaledW)
            let yStart = max(0, originY)
            let yEnd = min(canvasH, originY + scaledH)
            guard xEnd > xStart, yEnd > yStart else { continue }

            for cy in yStart..<yEnd {
                let sy = cy - originY
                let rowCanvas = cy * canvasW
                let rowSrc = sy * scaledW
                let edgeDistY = Float(min(sy, scaledH - 1 - sy))
                for cx in xStart..<xEnd {
                    let sx = cx - originX
                    let edgeDistX = Float(min(sx, scaledW - 1 - sx))
                    // Smooth triangular feather weight highest near frame center, tapering to edges.
                    let distPrimary = direction.isVertical ? edgeDistY : edgeDistX
                    let w = min(1.0, max(0.02, distPrimary / featherPx))

                    let pIdx = rowCanvas + cx
                    let dstIdx = pIdx * 4
                    let srcIdx = (rowSrc + sx) * 4
                    let prevW = weight[pIdx]
                    let nextW = prevW + w
                    let alpha = w / nextW
                    let inv = 1.0 - alpha

                    canvas[dstIdx] = UInt8(
                        min(255, max(0, Int(Float(canvas[dstIdx]) * inv + Float(frameBuf[srcIdx]) * alpha + 0.5))))
                    canvas[dstIdx + 1] = UInt8(
                        min(
                            255,
                            max(0, Int(Float(canvas[dstIdx + 1]) * inv + Float(frameBuf[srcIdx + 1]) * alpha + 0.5))))
                    canvas[dstIdx + 2] = UInt8(
                        min(
                            255,
                            max(0, Int(Float(canvas[dstIdx + 2]) * inv + Float(frameBuf[srcIdx + 2]) * alpha + 0.5))))
                    canvas[dstIdx + 3] = 255
                    weight[pIdx] = nextW
                }
            }
            peakMem = max(peakMem, currentMemoryBytes())
        }

        // 4. Crop off minor orthogonal wiggle edges so the panorama has clean solid borders.
        let cropRect: CGRect
        if direction.isVertical {
            let left = Int(((downPositions.map(\.x).max() ?? 0) - CGFloat(minX)) * scale)
            let right = Int(((downPositions.map(\.x).min() ?? 0) + CGFloat(frameW) - CGFloat(minX)) * scale)
            let cleanL = max(0, min(left, canvasW - 1))
            let cleanR = max(cleanL + 1, min(right, canvasW))
            cropRect =
                (cleanR - cleanL >= scaledW / 2)
                ? CGRect(x: cleanL, y: 0, width: cleanR - cleanL, height: canvasH)
                : CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        } else {
            let top = Int(((downPositions.map(\.y).max() ?? 0) - CGFloat(minY)) * scale)
            let bottom = Int(((downPositions.map(\.y).min() ?? 0) + CGFloat(frameH) - CGFloat(minY)) * scale)
            let cleanT = max(0, min(top, canvasH - 1))
            let cleanB = max(cleanT + 1, min(bottom, canvasH))
            cropRect =
                (cleanB - cleanT >= scaledH / 2)
                ? CGRect(x: 0, y: cleanT, width: canvasW, height: cleanB - cleanT)
                : CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        }

        let fullCI = CIImage(
            bitmapData: Data(canvas), bytesPerRow: canvasW * 4,
            size: CGSize(width: canvasW, height: canvasH), format: .RGBA8, colorSpace: colorSpace)
        // Core Image origin is bottom-left; flip cropRect.minY from top-down bitmap coordinates.
        let ciCrop = CGRect(
            x: cropRect.minX, y: CGFloat(canvasH) - cropRect.maxY,
            width: cropRect.width, height: cropRect.height)
        let cropped = fullCI.cropped(to: ciCrop)
        guard let cg = ciContext.createCGImage(cropped, from: cropped.extent),
            let encoded = encode(cg, preferHEIC: preferHEIC)
        else { return nil }

        peakMem = max(peakMem, currentMemoryBytes())
        return StitchResult(
            data: encoded.data, heic: encoded.heic, width: cg.width, height: cg.height,
            frameCount: cgFrames.count, peakMemoryBytes: peakMem)
    }

    private static func normalize(_ image: CIImage, to extent: CGRect) -> CIImage {
        var result = image
        if result.extent.origin != .zero {
            result = result.transformed(
                by: CGAffineTransform(translationX: -result.extent.minX, y: -result.extent.minY))
        }
        if abs(result.extent.width - extent.width) > 0.5 || abs(result.extent.height - extent.height) > 0.5 {
            let sx = extent.width / max(result.extent.width, 1)
            let sy = extent.height / max(result.extent.height, 1)
            result = result.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        return result.cropped(to: extent)
    }

    private static func registerShift(
        from prev: CGImage, to curr: CGImage, direction: PanoramaDirection,
        hint: CGVector?, primaryLimit: CGFloat, secondaryLimit: CGFloat
    ) -> CGVector {
        // 1. Vision translational registration (skip on uniform/textureless frames such as clear sky).
        if hasTexture(prev) && hasTexture(curr) {
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: curr)
            let handler = VNImageRequestHandler(cgImage: prev, options: [:])
            if (try? handler.perform([request])) != nil,
                let obs = request.results?.first as? VNImageTranslationAlignmentObservation
            {
                let t = obs.alignmentTransform
                let primary = direction.isVertical ? abs(t.ty) : abs(t.tx)
                let secondary = direction.isVertical ? abs(t.tx) : abs(t.ty)
                let expectedSignOK: Bool =
                    switch direction {
                    case .leftToRight: t.tx >= -4
                    case .rightToLeft: t.tx <= 4
                    case .bottomToTop: t.ty >= -4
                    case .topToBottom: t.ty <= 4
                    }
                let gyroConsistent: Bool =
                    if let hint {
                        abs(t.tx - hint.dx) <= max(45, abs(hint.dx) * 0.45)
                            && abs(t.ty - hint.dy) <= max(45, abs(hint.dy) * 0.45)
                    } else {
                        true
                    }
                if t.tx.isFinite && t.ty.isFinite && primary >= 2 && primary <= primaryLimit
                    && secondary <= secondaryLimit && expectedSignOK && gyroConsistent
                {
                    return CGVector(dx: t.tx, dy: t.ty)
                }
            }
        }
        // 2. Fallback to gyroscope prior when provided (e.g., low-texture sky or periodic facade).
        if let hint { return hint }
        return .zero
    }

    /// Quick 16×12 contrast check so Vision registration is skipped on completely uniform frames.
    private static func hasTexture(_ image: CGImage) -> Bool {
        let w = 16
        let h = 12
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard
            let ctx = CGContext(
                data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lo = 255
        var hi = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let luma = (Int(buf[i]) * 21 + Int(buf[i + 1]) * 72 + Int(buf[i + 2]) * 7) / 100
            if luma < lo { lo = luma }
            if luma > hi { hi = luma }
        }
        return (hi - lo) >= 12
    }

    private static func encode(_ image: CGImage, preferHEIC: Bool) -> (data: Data, heic: Bool)? {
        let targets: [(CFString, Bool)] =
            preferHEIC
            ? [(UTType.heic.identifier as CFString, true), (UTType.jpeg.identifier as CFString, false)]
            : [(UTType.jpeg.identifier as CFString, false)]
        for (uti, isHEIC) in targets {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, uti, 1, nil) else { continue }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length > 0 {
                return (data as Data, isHEIC)
            }
        }
        return nil
    }
}
