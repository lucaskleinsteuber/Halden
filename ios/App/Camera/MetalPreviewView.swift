import AVFoundation
import CoreImage
import HaldenKit
import MetalKit
import UIKit

/// Demand-driven Metal + Core Image camera viewfinder (`MTKView`). Only active when a
/// Photographic Style, Filter, Portrait preview or live Histogram/Waveform needs GPU rendering;
/// otherwise hidden so `AVCaptureVideoPreviewLayer` runs with minimal latency and heat.
final class MetalPreviewView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    nonisolated(unsafe) private var latestImage: CIImage?
    nonisolated(unsafe) private var activeStyle: PhotographicStyle?
    nonisolated(unsafe) private var activeFilter: PhotoFilter?
    nonisolated(unsafe) private var portraitAperture: Double?
    nonisolated(unsafe) private var portraitLighting: PortraitLighting?
    nonisolated(unsafe) private var extraTransform: (@Sendable (CIImage) -> CIImage)?
    nonisolated(unsafe) private var frameObserver: (@Sendable (CIImage) -> Void)?

    init(frame: CGRect = .zero) {
        let device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map {
            CIContext(
                mtlDevice: $0,
                options: [.cacheIntermediates: false, .priorityRequestLow: false])
        }
        super.init(frame: frame, device: device)
        self.delegate = self
        self.framebufferOnly = false
        self.isPaused = true
        self.enableSetNeedsDisplay = false
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.isOpaque = true
        self.isUserInteractionEnabled = false
        self.isHidden = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// Updates the live Core Image look & portrait parameters (thread-safe).
    nonisolated func configure(
        style: PhotographicStyle?, filter: PhotoFilter?,
        portraitAperture: Double? = nil, portraitLighting: PortraitLighting? = nil,
        extraTransform: (@Sendable (CIImage) -> CIImage)? = nil,
        frameObserver: (@Sendable (CIImage) -> Void)? = nil
    ) {
        lock.withLock {
            activeStyle = style
            activeFilter = filter
            self.portraitAperture = portraitAperture
            self.portraitLighting = portraitLighting
            self.extraTransform = extraTransform
            self.frameObserver = frameObserver
        }
    }

    /// Feeds a new camera pixel buffer (plus optional live depth data in Portrait mode) and renders.
    nonisolated func enqueue(
        pixelBuffer: CVPixelBuffer, depthData: AVDepthData? = nil,
        orientation: CGImagePropertyOrientation = .up
    ) {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if orientation != .up { image = image.oriented(orientation) }
        let (style, filter, aperture, lighting, extra, observer) = lock.withLock {
            (activeStyle, activeFilter, portraitAperture, portraitLighting, extraTransform, frameObserver)
        }
        if aperture != nil || (lighting != nil && lighting != .natural) {
            let depthCI = depthData.map { CIImage(cvPixelBuffer: $0.depthDataMap) }
            image = PortraitRenderer.apply(to: image, depthMap: depthCI, aperture: aperture, lighting: lighting)
        }
        if let extra { image = extra(image) }
        image = LookRenderer.apply(style: style, filter: filter, to: image)
        observer?(image)
        lock.withLock { latestImage = image }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isHidden else { return }
            self.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let ciContext, let commandQueue,
            let drawable = currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let source = lock.withLock({ latestImage })
        else { return }
        let target = CGRect(origin: .zero, size: drawableSize)
        guard target.width > 0, target.height > 0, source.extent.width > 0, source.extent.height > 0 else { return }
        // Aspect-fill into the Metal drawable, matching `AVCaptureVideoPreviewLayer.resizeAspectFill`.
        let scale = max(target.width / source.extent.width, target.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = target.midX - scaled.extent.midX
        let dy = target.midY - scaled.extent.midY
        let centered = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: target)
        ciContext.render(
            centered, to: drawable.texture, commandBuffer: commandBuffer, bounds: target, colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Hosts the system `AVCaptureVideoPreviewLayer` underneath and the optional `MetalPreviewView`
/// above it so switching between the fast system layer and GPU look preview never flickers.
final class PreviewContainerView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let metalView = MetalPreviewView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metalView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
        metalView.frame = bounds
    }

    func setMetalActive(_ active: Bool) {
        metalView.isHidden = !active
    }
}

/// Receives camera video (and optional synchronized depth) frames on a dedicated serial queue and
/// hands them to `MetalPreviewView`.
final class PreviewFrameRelay: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureDataOutputSynchronizerDelegate, @unchecked Sendable
{
    let queue = DispatchQueue(label: "halden.preview.frames", qos: .userInteractive)
    private let metalView: MetalPreviewView

    init(metalView: MetalPreviewView) {
        self.metalView = metalView
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        metalView.enqueue(pixelBuffer: buffer)
    }

    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        var pixelBuffer: CVPixelBuffer?
        var depthData: AVDepthData?
        for output in synchronizer.dataOutputs {
            if let video = synchronizedDataCollection.synchronizedData(for: output)
                as? AVCaptureSynchronizedSampleBufferData,
                !video.sampleBufferWasDropped,
                let buffer = CMSampleBufferGetImageBuffer(video.sampleBuffer)
            {
                pixelBuffer = buffer
            } else if let depth = synchronizedDataCollection.synchronizedData(for: output)
                as? AVCaptureSynchronizedDepthData,
                !depth.depthDataWasDropped
            {
                depthData = depth.depthData
            }
        }
        guard let pixelBuffer else { return }
        metalView.enqueue(pixelBuffer: pixelBuffer, depthData: depthData)
    }
}

/// Watches people, faces, dogs, cats (automatic depth) and QR codes in photo/portrait mode.
final class SubjectMetadataRelay: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.metadata.subjects", qos: .utility)
    var onDetect: (@Sendable (Bool) -> Void)?
    var onQRCode: (@Sendable (ScannedQRCode?) -> Void)?
    private var lastDetected = false
    private var qrHold = ScannerHoldState()
    private var lastQR: ScannedQRCode?

    func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let hasSubject = metadataObjects.contains { object in
            object.type == .face || object.type == .humanBody || object.type == .dogBody || object.type == .catBody
        }
        if hasSubject != lastDetected {
            lastDetected = hasSubject
            onDetect?(hasSubject)
        }
        let rawQR =
            metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .first(where: { $0.type == .qr })?
            .stringValue
        let stableQR = qrHold.update(raw: rawQR, now: ProcessInfo.processInfo.systemUptime)
        if stableQR != lastQR {
            lastQR = stableQR
            onQRCode?(stableQR)
        }
    }

    func resetQR() {
        queue.async {
            self.qrHold.clear()
            if self.lastQR != nil {
                self.lastQR = nil
                self.onQRCode?(nil)
            }
        }
    }
}
