import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Made-up photos and videos: for the stand-in camera (the simulator has no camera, UI tests
/// need one that answers the same every time) and for tests. Every `seed` gives different
/// content, so the server never takes two of them for the same photo.
public enum SampleMedia {
    /// A JPEG of coloured blocks.
    public static func photo(seed: Int, width: Int = 1600, height: Int = 1200) -> Data? {
        guard let image = picture(seed: seed, frame: 0, width: width, height: height) else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// A QuickTime video (H.264, 30 frames a second) of moving blocks, with `metadata` in it.
    public static func video(
        at url: URL, seed: Int, seconds: Double, width: Int = 640, height: Int = 360,
        metadata: [AVMetadataItem] = []
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = max(1, Int(seconds * 30))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            {
                draw(in: context, seed: seed, frame: frame, width: width, height: height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func picture(seed: Int, frame: Int, width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        draw(in: context, seed: seed, frame: frame, width: width, height: height)
        return context.makeImage()
    }

    static func draw(in context: CGContext, seed: Int, frame: Int, width: Int, height: Int) {
        var state = UInt64(truncatingIfNeeded: seed) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<24 {
            context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
            let size = CGSize(width: next() * Double(width) / 3, height: next() * Double(height) / 3)
            let x = (next() * Double(width) + Double(frame * 8)).truncatingRemainder(dividingBy: Double(width))
            context.fill(CGRect(origin: CGPoint(x: x, y: next() * Double(height)), size: size))
        }
    }
}
