import AVFoundation
import HaldenKit

/// Writes a time-lapse from the camera's frames: of the pictures the camera delivers 30 times a
/// second, it keeps those `TimeLapsePlan` wants and writes them one after another at 30 frames
/// a second (HEVC). Everything happens on `queue`, the queue the camera delivers on (that is
/// what makes the `@unchecked Sendable` true).
final class TimeLapseRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "halden.timelapse", qos: .userInitiated)
    private var url: URL?
    private var metadata: [AVMetadataItem] = []
    private var plan = TimeLapsePlan()
    private var start: CMTime?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var stopping = false

    /// Starts keeping frames for a new time-lapse at `url`.
    func begin(url: URL, fixedInterval: Double?, metadata: [AVMetadataItem]) {
        // Made for this time-lapse and only read on `queue`.
        let carried = Carry(value: metadata)
        queue.async {
            self.reset()
            self.url = url
            self.metadata = carried.value
            self.plan = TimeLapsePlan(fixed: fixedInterval)
        }
    }

    /// Finishes the file. `done` gets it (or `nil` when not a single frame was kept) and which
    /// stretches were taken at which interval, to bring them to one speed.
    func finish(_ done: @escaping @Sendable (URL?, TimeLapsePlan) -> Void) {
        queue.async {
            let plan = self.plan
            guard let writer = self.writer, let input = self.input, let url = self.url, writer.status == .writing,
                plan.kept > 0
            else {
                self.reset()
                return done(nil, plan)
            }
            self.stopping = true
            input.markAsFinished()
            // The last picture is shown as long as every other one.
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(plan.kept), timescale: 30))
            let carried = Carry(value: writer)
            writer.finishWriting {
                let finished = carried.value.status == .completed
                done(finished ? url : nil, plan)
            }
            self.reset()
        }
    }

    private func reset() {
        url = nil
        start = nil
        writer = nil
        input = nil
        adaptor = nil
        stopping = false
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let url, !stopping, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if start == nil {
            start = time
            guard startWriting(to: url, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
            else { return }
        }
        guard let start, let input, let adaptor, input.isReadyForMoreMediaData,
            plan.keep(at: (time - start).seconds)
        else { return }
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(plan.kept - 1), timescale: 30))
    }

    private func startWriting(to url: URL, width: Int, height: Int) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        writer.metadata = metadata
        let codec: AVVideoCodecType = .hevc
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        return true
    }
}
