import AVFoundation
import CoreImage
import HaldenKit
import Metal
import QuartzCore
import UIKit

/// The camera's own viewfinder, drawn with Core Image into a Metal layer: only while a
/// Photographic Style, a filter, Portrait or the scopes need it; otherwise hidden, and the
/// system's `AVCaptureVideoPreviewLayer` shows the picture with the least delay and heat.
///
/// It draws on the frames' own queue, never on the main thread, so a busy screen (a slider being
/// dragged, a sheet sliding in) never makes the picture stutter.
final class MetalPreviewView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    nonisolated(unsafe) private var activeStyle: PhotographicStyle?
    nonisolated(unsafe) private var activeFilter: PhotoFilter?
    nonisolated(unsafe) private var activeFilterIntensity = 1.0
    nonisolated(unsafe) private var portraitAperture: Double?
    nonisolated(unsafe) private var portraitLighting: PortraitLighting?
    nonisolated(unsafe) private var extraTransform: (@Sendable (CIImage) -> CIImage)?
    nonisolated(unsafe) private var frameObserver: (@Sendable (CIImage) -> Void)?
    /// Drawing wanted (set on the main thread, read on the frames' queue).
    nonisolated(unsafe) private var rendering = false
    /// Shown only once the first frame is drawn, so it never appears black or stale.
    nonisolated(unsafe) private var revealPending = false
    nonisolated(unsafe) private var targetSize = CGSize.zero
    nonisolated(unsafe) private var onRevealed: (@MainActor () -> Void)?
    nonisolated(unsafe) private var metal: CAMetalLayer?

    override init(frame: CGRect = .zero) {
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        ciContext = device.map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false, .priorityRequestLow: false])
        }
        super.init(frame: frame)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.device = device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = false
            metalLayer.isOpaque = true
            metal = metalLayer
        }
        backgroundColor = .black
        isUserInteractionEnabled = false
        isHidden = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        metal?.contentsScale = scale
        metal?.drawableSize = size
        lock.withLock { targetSize = size }
    }

    /// Updates the live Core Image look & portrait parameters (thread-safe).
    nonisolated func configure(
        style: PhotographicStyle?, filter: PhotoFilter?, filterIntensity: Double = 1,
        portraitAperture: Double? = nil, portraitLighting: PortraitLighting? = nil,
        extraTransform: (@Sendable (CIImage) -> CIImage)? = nil,
        frameObserver: (@Sendable (CIImage) -> Void)? = nil
    ) {
        lock.withLock {
            activeStyle = style
            activeFilter = filter
            activeFilterIntensity = filterIntensity
            self.portraitAperture = portraitAperture
            self.portraitLighting = portraitLighting
            self.extraTransform = extraTransform
            self.frameObserver = frameObserver
        }
    }

    /// Starts drawing; `revealed` runs once the first frame is on screen.
    func startRendering(revealed: @escaping @MainActor () -> Void) {
        let alreadyVisible = !isHidden
        lock.withLock {
            rendering = true
            revealPending = !alreadyVisible
            onRevealed = revealed
        }
        if alreadyVisible { revealed() }
    }

    /// Stops drawing and hides (the system layer is showing the picture again by then).
    func stopRendering() {
        lock.withLock {
            rendering = false
            revealPending = false
            onRevealed = nil
        }
        isHidden = true
    }

    /// A new camera frame (plus live depth data in Portrait mode), on the frames' queue.
    nonisolated func enqueue(
        pixelBuffer: CVPixelBuffer, depthData: AVDepthData? = nil,
        orientation: CGImagePropertyOrientation = .up
    ) {
        let (style, filter, intensity, aperture, lighting, extra, observer, draw) = lock.withLock {
            (
                activeStyle, activeFilter, activeFilterIntensity, portraitAperture, portraitLighting, extraTransform,
                frameObserver, rendering
            )
        }
        guard draw || observer != nil else { return }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if orientation != .up { image = image.oriented(orientation) }
        if aperture != nil || (lighting != nil && lighting != .natural) {
            let depthCI = depthData.map { CIImage(cvPixelBuffer: $0.depthDataMap) }
            image = PortraitRenderer.apply(to: image, depthMap: depthCI, aperture: aperture, lighting: lighting)
        }
        if let extra { image = extra(image) }
        image = LookRenderer.apply(style: style, filter: filter, filterIntensity: intensity, to: image)
        observer?(image)
        if draw { render(image) }
    }

    nonisolated private func render(_ source: CIImage) {
        let target = CGRect(origin: .zero, size: lock.withLock { targetSize })
        guard let ciContext, let commandQueue, let metal, target.width > 0, target.height > 0,
            source.extent.width > 0, source.extent.height > 0,
            let drawable = metal.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        // Aspect-fill, matching `AVCaptureVideoPreviewLayer.resizeAspectFill`.
        let scale = max(target.width / source.extent.width, target.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = target.midX - scaled.extent.midX
        let dy = target.midY - scaled.extent.midY
        let centered = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: target)
        ciContext.render(
            centered, to: drawable.texture, commandBuffer: commandBuffer, bounds: target, colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        let reveal: (@MainActor () -> Void)? = lock.withLock {
            guard revealPending, rendering else { return nil }
            revealPending = false
            return onRevealed
        }
        if let reveal {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.rendering }) else { return }
                self.isHidden = false
                reveal()
            }
        }
    }
}

/// Hosts the system `AVCaptureVideoPreviewLayer` and the `MetalPreviewView` above it. While the
/// Metal view shows the picture, the system layer stops drawing (no work done twice); switching
/// between them never shows a black or stale frame.
final class PreviewContainerView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    let metalView = MetalPreviewView()
    private var metalWanted = false
    private var stopTask: Task<Void, Never>?

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
        guard active != metalWanted else { return }
        metalWanted = active
        stopTask?.cancel()
        if active {
            metalView.startRendering { [weak self] in
                guard let self, self.metalWanted else { return }
                self.previewLayer.connection?.isEnabled = false
            }
        } else {
            // The system layer first, the Metal view a moment later once the layer draws again.
            previewLayer.connection?.isEnabled = true
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled, !self.metalWanted else { return }
                self.metalView.stopRendering()
            }
        }
    }
}

/// Receives the preview frames (and synchronized depth in Portrait) on its own queue: draws the
/// custom viewfinder, hands a frame now and then to Live Text and to the filter buttons, and tells
/// whoever waits that a new picture arrived (the end of a mode switch).
final class PreviewFrameRelay: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureDataOutputSynchronizerDelegate, @unchecked Sendable
{
    let queue = DispatchQueue(label: "halden.preview.frames", qos: .userInteractive)
    private let metalView: MetalPreviewView
    private let lock = NSLock()
    private var waiters: [@Sendable () -> Void] = []
    private var sampling = false
    private var lastSample: Double = 0
    private var detectText = false
    private let sampleContext = CIContext(options: [.cacheIntermediates: false])
    /// Live Text in the viewfinder (Photo mode).
    var textDetector: ViewfinderTextDetector?
    /// The small picture for the filter buttons.
    var lookSampled: (@Sendable (CGImage) -> Void)?

    init(metalView: MetalPreviewView) {
        self.metalView = metalView
    }

    /// `done` runs when the next frame arrives.
    func whenNextFrame(_ done: @escaping @Sendable () -> Void) {
        lock.withLock { waiters.append(done) }
    }

    func setSampling(_ on: Bool) {
        lock.withLock { sampling = on }
    }

    func setTextDetection(_ on: Bool) {
        lock.withLock { detectText = on }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handle(buffer, depth: nil)
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
        handle(pixelBuffer, depth: depthData)
    }

    private func handle(_ buffer: CVPixelBuffer, depth: AVDepthData?) {
        let now = ProcessInfo.processInfo.systemUptime
        let (ready, sample, text) = lock.withLock { () -> ([@Sendable () -> Void], Bool, Bool) in
            let ready = waiters
            waiters = []
            let sample = sampling && now - lastSample >= 0.2
            if sample { lastSample = now }
            return (ready, sample, detectText)
        }
        metalView.enqueue(pixelBuffer: buffer, depthData: depth)
        for waiter in ready { waiter() }
        if text { textDetector?.offer(buffer) }
        if sample, let lookSampled { makeSample(buffer).map(lookSampled) }
    }

    /// About 120 points wide, upright, without any look.
    private func makeSample(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 160 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return sampleContext.createCGImage(small, from: small.extent.integral)
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
