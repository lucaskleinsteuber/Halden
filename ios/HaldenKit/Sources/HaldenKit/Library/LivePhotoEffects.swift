@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Non-destructive playback effects for Live Photos, matching Apple Photos.
/// The original photo and `paired_video` stay untouched; the active choice lives in
/// `EditRecipe.liveEffect`, and the rendered result is stored on the server under the
/// `live_effect` derived role.
public enum LivePhotoEffect: String, Codable, Sendable, CaseIterable, Identifiable {
    case live
    case loop
    case bounce
    case longExposure = "long_exposure"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: "Live"
        case .loop: "Loop"
        case .bounce: "Bounce"
        case .longExposure: "Long Exposure"
        }
    }

    public var symbol: String {
        switch self {
        case .live: "livephoto"
        case .loop: "repeat"
        case .bounce: "arrow.left.arrow.right"
        case .longExposure: "camera.aperture"
        }
    }

    /// Loop and Bounce render as looping MP4 videos; Long Exposure renders as a blended still.
    public var isVideoOutput: Bool { self == .loop || self == .bounce }

    public var outputMimeType: String {
        isVideoOutput ? "video/mp4" : "image/heic"
    }

    public var outputExtension: String {
        isVideoOutput ? "mp4" : "heic"
    }
}

/// Pure helpers for Live Photo effect frame sequencing and key-frame clamping.
public enum LivePhotoEffectMath {
    public static let maxKeyFrameMs: Int64 = 600_000

    public static func clampKeyFrameMs(_ ms: Int64, durationMs: Int64? = nil) -> Int64 {
        let upper = durationMs.map { min(max($0, 0), maxKeyFrameMs) } ?? maxKeyFrameMs
        return min(max(ms, 0), upper)
    }

    /// Ping-pong sequence: `0, 1, ..., n-1, n-2, ..., 1` so the loop turnaround has no duplicate frames.
    public static func bounceIndices(frameCount: Int) -> [Int] {
        guard frameCount > 1 else { return frameCount == 1 ? [0] : [] }
        var indices = Array(0..<frameCount)
        if frameCount > 2 {
            indices.append(contentsOf: stride(from: frameCount - 2, through: 1, by: -1))
        }
        return indices
    }

    /// Number of overlap frames used to cross-fade the seam of a seamless Loop video.
    public static func loopCrossfadeCount(frameCount: Int) -> Int {
        guard frameCount >= 8 else { return 0 }
        return min(max(frameCount / 6, 2), 8)
    }

    /// Measures spatial pixel variance (0…1) of an image; useful to verify smoothing in Long Exposure.
    public static func spatialRoughness(_ image: CGImage) -> Double {
        let w = min(image.width, 160)
        let h = min(image.height, 120)
        guard w >= 4, h >= 4 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sumSq = 0.0
        var count = 0
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let i = (y * w + x) * 4
                let r = (y * w + x + 1) * 4
                let b = ((y + 1) * w + x) * 4
                let lum = 0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])
                let lumR = 0.299 * Double(bytes[r]) + 0.587 * Double(bytes[r + 1]) + 0.114 * Double(bytes[r + 2])
                let lumB = 0.299 * Double(bytes[b]) + 0.587 * Double(bytes[b + 1]) + 0.114 * Double(bytes[b + 2])
                let dx = (lumR - lum) / 255.0
                let dy = (lumB - lum) / 255.0
                sumSq += dx * dx + dy * dy
                count += 1
            }
        }
        return count > 0 ? sqrt(sumSq / Double(count)) : 0
    }
}

/// Output produced by rendering a Live Photo effect or extracting a key photo.
public struct RenderedLiveEffect: Sendable {
    public var url: URL
    public var data: Data
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var sha256: String

    public init(url: URL, data: Data, mimeType: String, width: Int, height: Int, sha256: String) {
        self.url = url
        self.data = data
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.sha256 = sha256
    }
}

public enum LivePhotoEffectError: Error, Sendable, LocalizedError {
    case noVideoTrack
    case noFrames
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "This Live Photo has no video track."
        case .noFrames: "No frames could be read from the Live Photo video."
        case .encodeFailed: "The Live Photo effect could not be encoded."
        }
    }
}

/// Renders Loop, Bounce, Long Exposure, and Key Photo outputs from a Live Photo's paired video.
public enum LivePhotoEffectRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let maxEdge = 1280
    private static let maxFrames = 60

    /// Duration of the Live Photo video in milliseconds.
    public static func durationMs(of video: URL) async -> Int64 {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds.isFinite else {
            return 0
        }
        return max(0, Int64((duration.seconds * 1000).rounded()))
    }

    /// Renders the chosen Live Photo effect (`loop`, `bounce`, `longExposure`) into `destination`.
    public static func render(
        effect: LivePhotoEffect, video: URL, to destination: URL, preferHEIC: Bool = true
    ) async throws -> RenderedLiveEffect {
        switch effect {
        case .loop:
            try await renderLoop(video: video, to: destination)
        case .bounce:
            try await renderBounce(video: video, to: destination)
        case .longExposure:
            try await renderLongExposure(video: video, to: destination, preferHEIC: preferHEIC)
        case .live:
            try await extractKeyFrame(video: video, atMs: 0, to: destination, preferHEIC: preferHEIC)
        }
    }

    /// Seamless Loop MP4: cross-fades the tail into the head so the loop restarts smoothly.
    public static func renderLoop(video: URL, to destination: URL) async throws -> RenderedLiveEffect {
        let extracted = try await readFrames(from: video)
        let frames = extracted.frames
        let overlap = LivePhotoEffectMath.loopCrossfadeCount(frameCount: frames.count)
        let sequenced: [CGImage]
        if overlap > 0 {
            let coreCount = frames.count - overlap
            var out: [CGImage] = []
            out.reserveCapacity(coreCount)
            for i in 0..<coreCount {
                if i < overlap {
                    let alpha = CGFloat(i + 1) / CGFloat(overlap + 1)
                    let tailIndex = coreCount + i
                    out.append(blend(frames[tailIndex], over: frames[i], alpha: 1 - alpha) ?? frames[i])
                } else {
                    out.append(frames[i])
                }
            }
            sequenced = out
        } else {
            sequenced = frames
        }
        return try await writeVideo(frames: sequenced, fps: extracted.fps, to: destination)
    }

    /// Bounce MP4: plays forward to the last frame, then smoothly reverses back to frame 1.
    public static func renderBounce(video: URL, to destination: URL) async throws -> RenderedLiveEffect {
        let extracted = try await readFrames(from: video)
        let indices = LivePhotoEffectMath.bounceIndices(frameCount: extracted.frames.count)
        let sequenced = indices.map { extracted.frames[$0] }
        return try await writeVideo(frames: sequenced, fps: extracted.fps, to: destination)
    }

    /// Long Exposure still: aligns frames via Vision translational registration, then averages
    /// pixels across all frames to smooth moving water, clouds, or lights.
    public static func renderLongExposure(
        video: URL, to destination: URL, preferHEIC: Bool = true
    ) async throws -> RenderedLiveEffect {
        let extracted = try await readFrames(from: video, maxCount: 36)
        guard let first = extracted.frames.first else { throw LivePhotoEffectError.noFrames }
        let width = first.width
        let height = first.height
        let pixelCount = width * height

        var accumR = [Float](repeating: 0, count: pixelCount)
        var accumG = [Float](repeating: 0, count: pixelCount)
        var accumB = [Float](repeating: 0, count: pixelCount)
        let reference = CIImage(cgImage: first)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var usedCount = 0

        for (idx, frame) in extracted.frames.enumerated() {
            autoreleasepool {
                var image = CIImage(cgImage: frame)
                if idx > 0 {
                    let req = VNTranslationalImageRegistrationRequest(targetedCIImage: image)
                    let handler = VNImageRequestHandler(ciImage: reference, options: [:])
                    try? handler.perform([req])
                    if let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
                        let t = obs.alignmentTransform
                        if abs(t.tx) < CGFloat(width) * 0.2 && abs(t.ty) < CGFloat(height) * 0.2 {
                            image = image.transformed(by: t).clampedToExtent().cropped(to: extent)
                        }
                    }
                }
                var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
                ciContext.render(
                    image, toBitmap: &rgba, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB())
                for p in 0..<pixelCount {
                    let o = p * 4
                    accumR[p] += Float(rgba[o])
                    accumG[p] += Float(rgba[o + 1])
                    accumB[p] += Float(rgba[o + 2])
                }
                usedCount += 1
            }
        }
        guard usedCount > 0 else { throw LivePhotoEffectError.noFrames }

        let inv = 1.0 / Float(usedCount)
        var outBytes = [UInt8](repeating: 255, count: pixelCount * 4)
        for p in 0..<pixelCount {
            let o = p * 4
            outBytes[o] = UInt8(min(max((accumR[p] * inv).rounded(), 0), 255))
            outBytes[o + 1] = UInt8(min(max((accumG[p] * inv).rounded(), 0), 255))
            outBytes[o + 2] = UInt8(min(max((accumB[p] * inv).rounded(), 0), 255))
        }
        let provider = CGDataProvider(data: Data(outBytes) as CFData)!
        guard
            let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw LivePhotoEffectError.encodeFailed }

        return try encodeStill(cgImage, to: destination, preferHEIC: preferHEIC)
    }

    /// Extracts a single key-photo still at `atMs` milliseconds inside the Live Photo video.
    public static func extractKeyFrame(
        video: URL, atMs: Int64, to destination: URL, preferHEIC: Bool = true
    ) async throws -> RenderedLiveEffect {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let target = CMTime(value: max(0, atMs), timescale: 1000)
        let (cgImage, _) = try await generator.image(at: target)
        return try encodeStill(cgImage, to: destination, preferHEIC: preferHEIC)
    }

    /// Extracts evenly spaced thumbnail frames for the Key Photo scrubber strip.
    public static func scrubberFrames(of video: URL, count: Int = 8, maxEdge: CGFloat = 120) async -> [CGImage] {
        let asset = AVURLAsset(url: video)
        let duration = await durationMs(of: video)
        guard duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        var images: [CGImage] = []
        images.reserveCapacity(count)
        for i in 0..<count {
            let ms = count == 1 ? 0 : (duration * Int64(i)) / Int64(count - 1)
            let time = CMTime(value: ms, timescale: 1000)
            if let (cg, _) = try? await generator.image(at: time) {
                images.append(cg)
            }
        }
        return images
    }

    // MARK: Internals

    private struct ExtractedFrames {
        var frames: [CGImage]
        var fps: Int32
    }

    private static func readFrames(from video: URL, maxCount: Int = maxFrames) async throws -> ExtractedFrames {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LivePhotoEffectError.noVideoTrack
        }
        let transform = try await track.load(.preferredTransform)
        let nominal = try await track.load(.nominalFrameRate)
        let fps = Int32(min(max(nominal.rounded(), 12), 30))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LivePhotoEffectError.noFrames }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? LivePhotoEffectError.noFrames }

        var raw: [CGImage] = []
        while let sample = output.copyNextSampleBuffer() {
            autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                var ci = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
                let longSide = max(ci.extent.width, ci.extent.height)
                if longSide > CGFloat(maxEdge) {
                    let scale = CGFloat(maxEdge) / longSide
                    ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
                let rect = CGRect(
                    x: 0, y: 0,
                    width: max(2, Int(ci.extent.width.rounded()) & ~1),
                    height: max(2, Int(ci.extent.height.rounded()) & ~1))
                if let cg = ciContext.createCGImage(ci, from: rect) {
                    raw.append(cg)
                }
            }
        }
        guard !raw.isEmpty else { throw LivePhotoEffectError.noFrames }
        if raw.count <= maxCount {
            return ExtractedFrames(frames: raw, fps: fps)
        }
        // Uniformly subsample to keep memory and encode time crisp.
        var sampled: [CGImage] = []
        sampled.reserveCapacity(maxCount)
        for i in 0..<maxCount {
            let idx = (i * (raw.count - 1)) / max(1, maxCount - 1)
            sampled.append(raw[idx])
        }
        return ExtractedFrames(frames: sampled, fps: fps)
    }

    private static func blend(_ top: CGImage, over bottom: CGImage, alpha: CGFloat) -> CGImage? {
        let w = bottom.width
        let h = bottom.height
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(bottom, in: rect)
        ctx.setAlpha(alpha)
        ctx.draw(top, in: rect)
        return ctx.makeImage()
    }

    private static func writeVideo(frames: [CGImage], fps: Int32, to destination: URL) async throws
        -> RenderedLiveEffect
    {
        guard let first = frames.first else { throw LivePhotoEffectError.noFrames }
        let width = max(2, first.width & ~1)
        let height = max(2, first.height & ~1)
        try? FileManager.default.removeItem(at: destination)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 3_500_000
                ],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw LivePhotoEffectError.encodeFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LivePhotoEffectError.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: max(1, fps))
        for (index, frame) in frames.enumerated() {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing {
                    throw writer.error ?? LivePhotoEffectError.encodeFailed
                }
                waited += 1
                if waited > 6_000 {
                    writer.cancelWriting()
                    throw writer.error ?? LivePhotoEffectError.encodeFailed
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool else {
                throw writer.error ?? LivePhotoEffectError.encodeFailed
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { throw LivePhotoEffectError.encodeFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer),
                let ctx = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            {
                ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            if !adaptor.append(buffer, withPresentationTime: pts) {
                throw writer.error ?? LivePhotoEffectError.encodeFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? LivePhotoEffectError.encodeFailed
        }
        let data = try Data(contentsOf: destination)
        let sha = Hashing.sha256(of: data)
        return RenderedLiveEffect(
            url: destination, data: data, mimeType: "video/mp4", width: width, height: height, sha256: sha)
    }

    private static func encodeStill(
        _ cgImage: CGImage, to destination: URL, preferHEIC: Bool
    ) throws -> RenderedLiveEffect {
        let data = NSMutableData()
        let tryTypes: [(UTType, String)] =
            preferHEIC
            ? [(.heic, "image/heic"), (.jpeg, "image/jpeg")]
            : [(.jpeg, "image/jpeg")]
        for (utType, mime) in tryTypes {
            data.setData(Data())
            if let dest = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(
                    dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                if CGImageDestinationFinalize(dest), data.length > 0 {
                    let bytes = data as Data
                    try? FileManager.default.removeItem(at: destination)
                    try bytes.write(to: destination, options: .atomic)
                    return RenderedLiveEffect(
                        url: destination, data: bytes, mimeType: mime, width: cgImage.width, height: cgImage.height,
                        sha256: Hashing.sha256(of: bytes))
                }
            }
        }
        throw LivePhotoEffectError.encodeFailed
    }
}
