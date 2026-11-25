import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import Vision

/// User setting for Night Mode in Photo capture.
public enum NightModeSetting: Codable, Sendable, Equatable {
    case off
    case auto
    case seconds(Int)

    public var isOff: Bool {
        if case .off = self { return true }
        return false
    }

    public var manualSeconds: Int? {
        if case .seconds(let value) = self { return value }
        return nil
    }

    public func label(suggested: Int?, onTripod: Bool) -> String {
        switch self {
        case .off:
            return "OFF"
        case .auto:
            if let suggested { return "\(suggested)s" }
            return "AUTO"
        case .seconds(let value):
            let clamped = min(max(value, 0), NightMath.maxSeconds(onTripod: onTripod))
            return clamped == 0 ? "OFF" : "\(clamped)s"
        }
    }
}

/// Pure exposure & timing rules for Night Mode.
public enum NightMath {
    /// Maximum manual exposure time handheld (matches Apple Camera).
    public static let handheldMaxSeconds = 10
    /// Maximum exposure time when stabilized on a tripod.
    public static let tripodMaxSeconds = 30

    public static func maxSeconds(onTripod: Bool) -> Int {
        onTripod ? tripodMaxSeconds : handheldMaxSeconds
    }

    /// True when the scene is dark enough to suggest Night Mode.
    public static func isDark(iso: Double, shutterSeconds: Double) -> Bool {
        guard iso > 0, shutterSeconds > 0 else { return false }
        return (iso >= 800 && shutterSeconds >= 1.0 / 35.0) || iso >= 1600
    }

    /// Suggested Night Mode capture duration: 1–3 s handheld, 10–30 s on a tripod, or `nil` in bright light.
    public static func suggestedSeconds(iso: Double, shutterSeconds: Double, onTripod: Bool) -> Int? {
        guard isDark(iso: iso, shutterSeconds: shutterSeconds) else { return nil }
        let darkness = iso * max(shutterSeconds, 1.0 / 1000.0)
        if onTripod {
            if darkness < 60 { return 10 }
            if darkness < 140 { return 15 }
            if darkness < 260 { return 20 }
            return 30
        } else {
            if darkness < 60 { return 1 }
            if darkness < 140 { return 2 }
            return 3
        }
    }

    /// Effective Night Mode seconds for the shutter press (`0` means normal single-frame capture).
    public static func effectiveSeconds(setting: NightModeSetting, suggested: Int?, onTripod: Bool) -> Int {
        switch setting {
        case .off:
            return 0
        case .auto:
            return suggested ?? 0
        case .seconds(let s):
            return min(max(s, 0), maxSeconds(onTripod: onTripod))
        }
    }

    /// Number of short exposures captured and stacked for a given Night duration.
    public static func frameCount(forSeconds seconds: Int) -> Int {
        guard seconds > 0 else { return 1 }
        switch seconds {
        case 1: return 4
        case 2: return 6
        case 3: return 8
        case 4...10: return min(12, 6 + seconds / 2)
        default: return min(16, 10 + seconds / 5)
        }
    }
}

/// CoreMotion stability detector that recognises when the iPhone is mounted on a tripod or resting
/// completely still, unlocking up to 30 s Night Mode captures.
public struct TripodDetector: Sendable, Equatable {
    public static let minStableSeconds = 1.5
    private static let quietRotationThreshold = 0.035  // rad/s
    private static let quietAccelThreshold = 0.025  // g
    private static let moveRotationThreshold = 0.08
    private static let moveAccelThreshold = 0.06

    public private(set) var isOnTripod = false
    private var quietSince: Double?

    public init() {}

    @discardableResult
    public mutating func update(
        rotationX: Double, rotationY: Double, rotationZ: Double,
        accelX: Double, accelY: Double, accelZ: Double,
        at timestamp: Double
    ) -> Bool {
        let rot = sqrt(rotationX * rotationX + rotationY * rotationY + rotationZ * rotationZ)
        let acc = sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ)
        if rot > Self.moveRotationThreshold || acc > Self.moveAccelThreshold {
            quietSince = nil
            isOnTripod = false
            return false
        }
        if rot <= Self.quietRotationThreshold && acc <= Self.quietAccelThreshold {
            if let start = quietSince {
                if timestamp - start >= Self.minStableSeconds {
                    isOnTripod = true
                }
            } else {
                quietSince = timestamp
            }
        } else if !isOnTripod {
            quietSince = nil
        }
        return isOnTripod
    }

    /// Normalized drift (-1…+1) from the anchor gravity vector for the "Hold still" target crosshair.
    public static func holdStillOffset(
        gravityX: Double, gravityY: Double, anchorX: Double, anchorY: Double
    ) -> (dx: Double, dy: Double) {
        let scale = 6.0
        let dx = min(max((gravityX - anchorX) * scale, -1), 1)
        let dy = min(max((anchorY - gravityY) * scale, -1), 1)
        return (dx, dy)
    }
}

/// Aligns a burst of short low-light exposures with Vision (`VNHomographicImageRegistrationRequest`),
/// merges them with a Metal outlier-rejecting trimmed-mean kernel, denoises via Core Image, and
/// encodes the final HEIC image.
public enum NightStacker {
    public struct StackResult: Sendable {
        public let data: Data
        public let heic: Bool
        public let width: Int
        public let height: Int
        public let alignedFrames: Int
        public let usedMetal: Bool
    }

    private static let metalKernel = MetalNightKernel()

    /// Stacks encoded image frames (`Data`) into one denoised HEIC (or JPEG fallback) photo.
    public static func stack(frameData: [Data], preferHEIC: Bool = true) -> StackResult? {
        let images = frameData.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
        return stack(frames: images, preferHEIC: preferHEIC)
    }

    /// Aligns, outlier-reject averages on Metal, denoises and encodes a series of `CIImage` exposures.
    public static func stack(frames: [CIImage], preferHEIC: Bool = true) -> StackResult? {
        guard let first = frames.first else { return nil }
        let width = Int(first.extent.width.rounded())
        let height = Int(first.extent.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let targetExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let reference = normalize(first, to: targetExtent)
        let context = metalKernel.ciContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. Align frames[1...] to reference via Vision homographic registration.
        var aligned: [CIImage] = [reference]
        var alignedCount = 1
        for candidate in frames.dropFirst().prefix(15) {
            let norm = normalize(candidate, to: targetExtent)
            if let warped = align(floating: norm, to: reference, extent: targetExtent) {
                aligned.append(warped)
                alignedCount += 1
            } else {
                aligned.append(norm)
            }
        }

        // 2. Render aligned frames into RGBA8 planes and run Metal outlier-rejected averaging.
        let bytesPerRow = width * 4
        let planeBytes = bytesPerRow * height
        let count = aligned.count
        var packed = [UInt8](repeating: 0, count: planeBytes * count)
        packed.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for (index, frame) in aligned.enumerated() {
                context.render(
                    frame,
                    toBitmap: base.advanced(by: index * planeBytes),
                    rowBytes: bytesPerRow,
                    bounds: targetExtent,
                    format: .RGBA8,
                    colorSpace: colorSpace)
            }
        }

        var merged = [UInt8](repeating: 0, count: planeBytes)
        let usedMetal: Bool
        if count > 1, metalKernel.merge(packed: packed, count: count, width: width, height: height, into: &merged) {
            usedMetal = true
        } else {
            usedMetal = false
            cpuTrimmedMean(packed: packed, count: count, pixelCount: width * height, into: &merged)
        }

        // 3. Subtle shadow recovery followed by Core Image noise reduction so shadow lift never
        // re-amplifies grain.
        let mergedData = Data(merged)
        var output = CIImage(
            bitmapData: mergedData, bytesPerRow: bytesPerRow,
            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: colorSpace)

        if let shadow = CIFilter(name: "CIHighlightShadowAdjust") {
            shadow.setValue(output, forKey: kCIInputImageKey)
            shadow.setValue(0.08, forKey: "inputShadowAmount")
            shadow.setValue(1.0, forKey: "inputHighlightAmount")
            if let lifted = shadow.outputImage?.cropped(to: targetExtent) {
                output = lifted
            }
        }

        let nr = CIFilter.noiseReduction()
        nr.inputImage = output
        nr.noiseLevel = 0.04
        nr.sharpness = 0.15
        if let denoised = nr.outputImage?.cropped(to: targetExtent) {
            output = denoised
        }

        guard let cgImage = context.createCGImage(output, from: targetExtent) else { return nil }
        let encoded = encode(cgImage, preferHEIC: preferHEIC)
        guard let encoded else { return nil }
        return StackResult(
            data: encoded.data, heic: encoded.heic, width: width, height: height,
            alignedFrames: alignedCount, usedMetal: usedMetal)
    }

    /// Measures spatial high-frequency luminance noise (RMS residual against a sigma-2 blur) in 0…1.
    public static func noiseLevel(of image: CIImage) -> Double {
        let extent = image.extent
        let w = Int(extent.width.rounded())
        let h = Int(extent.height.rounded())
        guard w >= 12, h >= 12 else { return 0 }
        let norm = normalize(image, to: CGRect(x: 0, y: 0, width: w, height: h))
        let blurred = norm.clampedToExtent().applyingGaussianBlur(sigma: 2.0).cropped(to: norm.extent)
        let bytesPerRow = w * 4
        var a = [UInt8](repeating: 0, count: bytesPerRow * h)
        var b = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        metalKernel.ciContext.render(
            norm, toBitmap: &a, rowBytes: bytesPerRow, bounds: norm.extent, format: .RGBA8, colorSpace: cs)
        metalKernel.ciContext.render(
            blurred, toBitmap: &b, rowBytes: bytesPerRow, bounds: norm.extent, format: .RGBA8, colorSpace: cs)
        let margin = min(6, min(w, h) / 6)
        var sumSq = 0.0
        var n = 0
        for y in margin..<(h - margin) {
            for x in margin..<(w - margin) {
                let idx = (y * w + x) * 4
                let la =
                    (0.2126 * Double(a[idx]) + 0.7152 * Double(a[idx + 1]) + 0.0722 * Double(a[idx + 2])) / 255.0
                let lb =
                    (0.2126 * Double(b[idx]) + 0.7152 * Double(b[idx + 1]) + 0.0722 * Double(b[idx + 2])) / 255.0
                let diff = la - lb
                sumSq += diff * diff
                n += 1
            }
        }
        return n > 0 ? sqrt(sumSq / Double(n)) : 0
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

    private static func align(floating: CIImage, to reference: CIImage, extent: CGRect) -> CIImage? {
        // In Vision, VNImageRequestHandler holds the reference image and targetedCIImage is the
        // floating image; warpTransform / alignmentTransform map floating -> reference coordinates.
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: floating)
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        if (try? handler.perform([request])) != nil,
            let observation = request.results?.first as? VNImageHomographicAlignmentObservation
        {
            let h = observation.warpTransform
            if let warped = applyHomography(h, to: floating, extent: extent) {
                return warped
            }
        }
        // Fallback to translational registration when homography is ill-conditioned.
        let transReq = VNTranslationalImageRegistrationRequest(targetedCIImage: floating)
        let transHandler = VNImageRequestHandler(ciImage: reference, options: [:])
        if (try? transHandler.perform([transReq])) != nil,
            let obs = transReq.results?.first as? VNImageTranslationAlignmentObservation
        {
            let t = obs.alignmentTransform
            let maxShift = max(extent.width, extent.height) * 0.2
            if abs(t.tx) <= maxShift && abs(t.ty) <= maxShift {
                return floating.clampedToExtent().transformed(by: t).cropped(to: extent)
            }
        }
        return nil
    }

    private static func applyHomography(_ h: simd_float3x3, to image: CIImage, extent: CGRect) -> CIImage? {
        func project(_ pt: CGPoint) -> CGPoint? {
            let v = h * SIMD3<Float>(Float(pt.x), Float(pt.y), 1)
            guard abs(v.z) > 1e-4, v.x.isFinite, v.y.isFinite, v.z.isFinite else { return nil }
            return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
        }
        let w = extent.width
        let height = extent.height
        guard
            let bl = project(CGPoint(x: 0, y: 0)),
            let br = project(CGPoint(x: w, y: 0)),
            let tl = project(CGPoint(x: 0, y: height)),
            let tr = project(CGPoint(x: w, y: height))
        else { return nil }

        // Sanity guard against degenerate perspective warps on low-texture frames.
        let limit = max(w, height) * 0.22
        let corners = [
            (bl, CGPoint(x: 0, y: 0)), (br, CGPoint(x: w, y: 0)), (tl, CGPoint(x: 0, y: height)),
            (tr, CGPoint(x: w, y: height)),
        ]
        for (warped, orig) in corners {
            if hypot(warped.x - orig.x, warped.y - orig.y) > limit { return nil }
        }
        let perspective = CIFilter.perspectiveTransform()
        perspective.inputImage = image.clampedToExtent()
        perspective.bottomLeft = bl
        perspective.bottomRight = br
        perspective.topLeft = tl
        perspective.topRight = tr
        return perspective.outputImage?.cropped(to: extent)
    }

    private static func cpuTrimmedMean(packed: [UInt8], count: Int, pixelCount: Int, into output: inout [UInt8]) {
        guard count > 0 else { return }
        if count == 1 {
            output.replaceSubrange(0..<(pixelCount * 4), with: packed.prefix(pixelCount * 4))
            return
        }
        let planeBytes = pixelCount * 4
        let threshold = 42
        var vals = [Int](repeating: 0, count: count)
        for p in 0..<pixelCount {
            let base = p * 4
            for ch in 0..<3 {
                for i in 0..<count {
                    vals[i] = Int(packed[i * planeBytes + base + ch])
                }
                // Insertion sort (tiny N <= 16).
                for i in 1..<count {
                    let key = vals[i]
                    var j = i - 1
                    while j >= 0 && vals[j] > key {
                        vals[j + 1] = vals[j]
                        j -= 1
                    }
                    vals[j + 1] = key
                }
                let median = vals[count / 2]
                var sum = 0
                var inliers = 0
                for i in 0..<count where abs(vals[i] - median) <= threshold {
                    sum += vals[i]
                    inliers += 1
                }
                output[base + ch] = UInt8(inliers > 0 ? sum / inliers : median)
            }
            output[base + 3] = 255
        }
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
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length > 0 {
                return (data as Data, isHEIC)
            }
        }
        return nil
    }
}

/// Compiles and executes the Metal outlier-rejected multi-frame averaging kernel.
private final class MetalNightKernel: @unchecked Sendable {
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let pipeline: MTLComputePipelineState?
    let ciContext: CIContext

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct NightParams {
            uint width;
            uint height;
            uint count;
            uint threshold;
        };

        kernel void night_trimmed_mean(
            const device uchar *frames [[buffer(0)]],
            device uchar *output [[buffer(1)]],
            constant NightParams &p [[buffer(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= p.width || gid.y >= p.height) { return; }
            uint pixelIndex = gid.y * p.width + gid.x;
            uint base = pixelIndex * 4;
            uint planeBytes = p.width * p.height * 4;
            uint n = min(p.count, 16u);

            for (uint ch = 0; ch < 3; ++ch) {
                uchar vals[16];
                for (uint i = 0; i < n; ++i) {
                    vals[i] = frames[i * planeBytes + base + ch];
                }
                for (uint i = 1; i < n; ++i) {
                    uchar key = vals[i];
                    int j = int(i) - 1;
                    while (j >= 0 && vals[j] > key) {
                        vals[j + 1] = vals[j];
                        --j;
                    }
                    vals[j + 1] = key;
                }
                int median = int(vals[n / 2]);
                int sum = 0;
                int inliers = 0;
                int limit = int(p.threshold);
                for (uint i = 0; i < n; ++i) {
                    int v = int(vals[i]);
                    if (abs(v - median) <= limit) {
                        sum += v;
                        ++inliers;
                    }
                }
                output[base + ch] = uchar(inliers > 0 ? (sum / inliers) : median);
            }
            output[base + 3] = 255;
        }
        """

    private struct NightParams {
        var width: UInt32
        var height: UInt32
        var count: UInt32
        var threshold: UInt32
    }

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        if let dev {
            self.ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
            if let library = try? dev.makeLibrary(source: Self.shaderSource, options: nil),
                let fn = library.makeFunction(name: "night_trimmed_mean"),
                let state = try? dev.makeComputePipelineState(function: fn)
            {
                self.pipeline = state
            } else {
                self.pipeline = nil
            }
        } else {
            self.ciContext = CIContext()
            self.pipeline = nil
        }
    }

    func merge(packed: [UInt8], count: Int, width: Int, height: Int, into output: inout [UInt8]) -> Bool {
        guard let device, let commandQueue, let pipeline else { return false }
        let planeBytes = width * height * 4
        guard packed.count >= planeBytes * count, output.count >= planeBytes else { return false }
        guard
            let inBuf = packed.withUnsafeBytes({ raw -> MTLBuffer? in
                guard let ptr = raw.baseAddress else { return nil }
                return device.makeBuffer(bytes: ptr, length: planeBytes * count, options: .storageModeShared)
            }),
            let outBuf = device.makeBuffer(length: planeBytes, options: .storageModeShared),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        var params = NightParams(
            width: UInt32(width), height: UInt32(height), count: UInt32(count), threshold: 42)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuf, offset: 0, index: 0)
        encoder.setBuffer(outBuf, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<NightParams>.stride, index: 2)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return false }

        output.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress else { return }
            dst.copyMemory(from: outBuf.contents(), byteCount: planeBytes)
        }
        return true
    }
}
