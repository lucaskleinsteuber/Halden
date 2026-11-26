import AVFoundation
import CoreImage
import HaldenKit
import UIKit

/// Simultaneous back + front camera engine backed by `AVCaptureMultiCamSession` (iPhone 15 and
/// newer). Feeds the primary image into `MetalPreviewView`, delivers secondary Picture-in-Picture
/// preview frames, and composites Dual photos (HEIC/JPEG) and Dual videos (single `.mov`).
final class MultiCamEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.multicam", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let metalView: MetalPreviewView
    private var session: AVCaptureMultiCamSession?
    private let backOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private var latestBack: CIImage?
    private var latestFront: CIImage?
    private var swapped = false
    private var corner = PiPCorner.topRight
    private var lastPipDeliver: Double = 0
    var onPipImage: (@Sendable (UIImage?) -> Void)?

    // Composited Dual video recording state.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var recordingStart: CMTime?

    init(metalView: MetalPreviewView) {
        self.metalView = metalView
        super.init()
        for output in [backOutput, frontOutput] {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        }
    }

    static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    func start(swapped: Bool, corner: PiPCorner) {
        queue.async {
            self.swapped = swapped
            self.corner = corner
            guard Self.isSupported else { return }
            if self.session == nil {
                self.setupSession()
            }
            if let session = self.session, !session.isRunning {
                session.startRunning()
            }
        }
    }

    func updateLayout(swapped: Bool, corner: PiPCorner) {
        queue.async {
            self.swapped = swapped
            self.corner = corner
        }
    }

    func stop() {
        queue.async {
            if let session = self.session, session.isRunning {
                session.stopRunning()
            }
            self.latestBack = nil
            self.latestFront = nil
            self.onPipImage?(nil)
        }
    }

    private func setupSession() {
        let multi = AVCaptureMultiCamSession()
        multi.beginConfiguration()
        defer { multi.commitConfiguration() }

        guard
            let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let backInput = try? AVCaptureDeviceInput(device: back),
            let frontInput = try? AVCaptureDeviceInput(device: front),
            multi.canAddInput(backInput), multi.canAddInput(frontInput)
        else { return }

        multi.addInputWithNoConnections(backInput)
        multi.addInputWithNoConnections(frontInput)

        // Pick modest multi-cam compatible formats (~1080p/720p) to stay well within hardware bandwidth.
        for device in [back, front] {
            let compatible = device.formats.filter(\.isMultiCamSupported)
            if let chosen = compatible.first(where: {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width == 1280 && d.height == 720
            }) ?? compatible.first, (try? device.lockForConfiguration()) != nil {
                device.activeFormat = chosen
                device.unlockForConfiguration()
            }
        }

        if multi.canAddOutput(backOutput),
            let port = backInput.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: .back)
                .first
        {
            multi.addOutputWithNoConnections(backOutput)
            let conn = AVCaptureConnection(inputPorts: [port], output: backOutput)
            if multi.canAddConnection(conn) {
                multi.addConnection(conn)
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            }
            backOutput.setSampleBufferDelegate(self, queue: queue)
        }
        if multi.canAddOutput(frontOutput),
            let port = frontInput.ports(for: .video, sourceDeviceType: front.deviceType, sourceDevicePosition: .front)
                .first
        {
            multi.addOutputWithNoConnections(frontOutput)
            let conn = AVCaptureConnection(inputPorts: [port], output: frontOutput)
            if multi.canAddConnection(conn) {
                multi.addConnection(conn)
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                if conn.isVideoMirroringSupported { conn.isVideoMirrored = true }
            }
            frontOutput.setSampleBufferDelegate(self, queue: queue)
        }
        session = multi
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        if output === backOutput {
            latestBack = ci
        } else if output === frontOutput {
            latestFront = ci
        }

        let primaryBuffer = (swapped ? (output === frontOutput) : (output === backOutput))
        if primaryBuffer {
            metalView.enqueue(pixelBuffer: buffer, depthData: nil)
            appendVideoFrameIfRecording(sampleBuffer: sampleBuffer)
        } else {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPipDeliver >= 0.06 {
                lastPipDeliver = now
                if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                    onPipImage?(UIImage(cgImage: cg))
                }
            }
        }
    }

    func takePhoto(
        request: PhotoRequest, corner: PiPCorner, swapped: Bool,
        done: @escaping @Sendable (TakenPhoto?) -> Void
    ) {
        queue.async {
            self.corner = corner
            self.swapped = swapped
            let primary = swapped ? (self.latestFront ?? self.latestBack) : (self.latestBack ?? self.latestFront)
            let secondary = swapped ? self.latestBack : self.latestFront
            guard let primary else { return done(nil) }
            let sec = secondary ?? primary
            let preferHEIC = request.format == .heic
            DispatchQueue.global(qos: .userInitiated).async {
                guard
                    let encoded = DualCompositor.encodePhoto(
                        primary: primary, secondary: sec, corner: corner, preferHEIC: preferHEIC)
                else { return done(nil) }
                done(TakenPhoto(data: encoded.data, heic: encoded.heic, width: encoded.width, height: encoded.height))
            }
        }
    }

    func startRecording(request: VideoRequest, corner: PiPCorner, swapped: Bool) -> Bool {
        queue.async {
            self.corner = corner
            self.swapped = swapped
            try? FileManager.default.removeItem(at: request.url)
            guard let writer = try? AVAssetWriter(outputURL: request.url, fileType: .mov) else { return }
            let width = 720
            let height = 1280
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            guard writer.canAdd(input) else { return }
            writer.add(input)
            guard writer.startWriting() else { return }
            self.writer = writer
            self.writerInput = input
            self.adaptor = adaptor
            self.recordingURL = request.url
            self.recordingStart = nil
        }
        return true
    }

    func stopRecording(done: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            guard let writer = self.writer, let input = self.writerInput, let url = self.recordingURL else {
                return done(nil)
            }
            self.writer = nil
            self.writerInput = nil
            self.adaptor = nil
            self.recordingURL = nil
            self.recordingStart = nil
            input.markAsFinished()
            let box = CarriedWriter(writer: writer)
            writer.finishWriting {
                done(box.writer.status == .completed ? url : nil)
            }
        }
    }

    private struct CarriedWriter: @unchecked Sendable {
        let writer: AVAssetWriter
    }

    private func appendVideoFrameIfRecording(sampleBuffer: CMSampleBuffer) {
        guard let writer, let input = writerInput, let adaptor, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if recordingStart == nil {
            recordingStart = pts
            writer.startSession(atSourceTime: pts)
        }
        let primary = swapped ? (latestFront ?? latestBack) : (latestBack ?? latestFront)
        guard let primary else { return }
        let secondary = (swapped ? latestBack : latestFront) ?? primary
        let composed = DualCompositor.composite(primary: primary, secondary: secondary, corner: corner)
        guard let pool = adaptor.pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { return }
        let targetW = CVPixelBufferGetWidth(buffer)
        let targetH = CVPixelBufferGetHeight(buffer)
        let scaleX = CGFloat(targetW) / max(1, composed.extent.width)
        let scaleY = CGFloat(targetH) / max(1, composed.extent.height)
        let scaled = composed.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: buffer)
        adaptor.append(buffer, withPresentationTime: pts)
    }
}
