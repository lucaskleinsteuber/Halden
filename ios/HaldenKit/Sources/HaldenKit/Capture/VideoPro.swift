import CoreImage
import Foundation

/// Audio channel configuration for video capture (`AVCaptureDeviceInput.multichannelAudioMode`).
public enum AudioChannelMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case spatial
    case stereo
    case mono

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spatial: "Spatial Audio"
        case .stereo: "Stereo"
        case .mono: "Mono"
        }
    }

    public var shortLabel: String {
        switch self {
        case .spatial: "SPATIAL"
        case .stereo: "STEREO"
        case .mono: "MONO"
        }
    }
}

/// Pure rules for Action Mode stabilization and low-light guidance.
public enum ActionModeRules {
    /// Action Mode crops and uses faster shutter speeds, requiring more light than standard video.
    public static let lowLightISOThreshold = 1600.0
    public static let lowLightHint = "More light required."

    public static func needsMoreLight(actionMode: Bool, iso: Double?) -> Bool {
        guard actionMode, let iso else { return false }
        return iso >= lowLightISOThreshold
    }
}

/// Pure rules for Cinematic Video simulated aperture (`f/2.0–f/16`).
public enum CinematicRules {
    public static let apertureRange: ClosedRange<Double> = 2.0...16.0
    public static let defaultAperture = 2.8

    public static func clampedAperture(_ value: Double, min lower: Double = 2.0, max upper: Double = 16.0) -> Double {
        let clamped = Swift.min(Swift.max(value, lower), upper)
        return (clamped * 10).rounded() / 10
    }

    public static func formatAperture(_ f: Double) -> String {
        let clamped = clampedAperture(f)
        return clamped >= 10 && clamped == clamped.rounded()
            ? "f/\(Int(clamped))" : String(format: "f/%.1f", clamped)
    }
}

/// One user-chosen focus shift along a Cinematic video timeline, stored non-destructively in `EditRecipe`.
public struct CinematicFocusPoint: Codable, Sendable, Hashable, Identifiable {
    public var timeMs: Int64
    public var x: Double
    public var y: Double

    public var id: String { "\(timeMs)-\(Int((x * 1000).rounded()))-\(Int((y * 1000).rounded()))" }

    public init(timeMs: Int64, x: Double, y: Double) {
        self.timeMs = timeMs
        self.x = x
        self.y = y
    }

    public var fitted: CinematicFocusPoint {
        CinematicFocusPoint(
            timeMs: max(0, timeMs),
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1))
    }
}

/// Live camera histogram (RGB + Luma) and luma waveform data computed from preview frames.
public struct LiveScopesData: Sendable, Equatable {
    public static let histogramBins = 32
    public static let waveformColumns = 32

    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]
    public let luma: [Float]
    public let waveformMin: [Float]
    public let waveformMean: [Float]
    public let waveformMax: [Float]
    public let clippedHighlights: Double
    public let crushedShadows: Double

    public init(
        red: [Float], green: [Float], blue: [Float], luma: [Float],
        waveformMin: [Float], waveformMean: [Float], waveformMax: [Float],
        clippedHighlights: Double, crushedShadows: Double
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luma = luma
        self.waveformMin = waveformMin
        self.waveformMean = waveformMean
        self.waveformMax = waveformMax
        self.clippedHighlights = clippedHighlights
        self.crushedShadows = crushedShadows
    }
}

/// Fast live analyzer computing normalized RGB+Luma histograms and horizontal luma waveforms
/// from viewfinder `CIImage` frames.
public enum LiveScopesAnalyzer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Downscales `image` to 64×36 and extracts 32-bin RGB/Luma histograms + 32-column waveform.
    public static func analyze(_ image: CIImage) -> LiveScopesData {
        let extent = image.extent
        let w = 64
        let h = 36
        guard extent.width > 0, extent.height > 0 else { return sample() }
        let sx = CGFloat(w) / extent.width
        let sy = CGFloat(h) / extent.height
        let scaled =
            image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(
            scaled, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBA8, colorSpace: colorSpace)
        return analyzeRGBA(bytes: bytes, width: w, height: h)
    }

    public static func analyzeRGBA(bytes: [UInt8], width: Int, height: Int) -> LiveScopesData {
        let bins = LiveScopesData.histogramBins
        let cols = LiveScopesData.waveformColumns
        var rBins = [Int](repeating: 0, count: bins)
        var gBins = [Int](repeating: 0, count: bins)
        var bBins = [Int](repeating: 0, count: bins)
        var yBins = [Int](repeating: 0, count: bins)
        var colMin = [Float](repeating: 1, count: cols)
        var colMax = [Float](repeating: 0, count: cols)
        var colSum = [Float](repeating: 0, count: cols)
        var colCount = [Int](repeating: 0, count: cols)
        var clipped = 0
        var crushed = 0
        let total = max(1, width * height)

        for row in 0..<height {
            for col in 0..<width {
                let idx = (row * width + col) * 4
                let r = Int(bytes[idx])
                let g = Int(bytes[idx + 1])
                let b = Int(bytes[idx + 2])
                let luma = (0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)) / 255.0
                rBins[min((r * bins) / 256, bins - 1)] += 1
                gBins[min((g * bins) / 256, bins - 1)] += 1
                bBins[min((b * bins) / 256, bins - 1)] += 1
                yBins[min(Int(luma * Float(bins)), bins - 1)] += 1
                if luma >= 0.98 { clipped += 1 }
                if luma <= 0.02 { crushed += 1 }

                let wfCol = min((col * cols) / max(width, 1), cols - 1)
                colMin[wfCol] = min(colMin[wfCol], luma)
                colMax[wfCol] = max(colMax[wfCol], luma)
                colSum[wfCol] += luma
                colCount[wfCol] += 1
            }
        }

        func normalize(_ counts: [Int]) -> [Float] {
            let peak = Float(max(counts.max() ?? 1, 1))
            return counts.map { Float($0) / peak }
        }
        let wfMean = (0..<cols).map { i -> Float in
            colCount[i] > 0 ? colSum[i] / Float(colCount[i]) : 0
        }
        let wfMin = (0..<cols).map { i -> Float in
            colCount[i] > 0 ? colMin[i] : 0
        }
        return LiveScopesData(
            red: normalize(rBins), green: normalize(gBins), blue: normalize(bBins), luma: normalize(yBins),
            waveformMin: wfMin, waveformMean: wfMean, waveformMax: colMax,
            clippedHighlights: Double(clipped) / Double(total),
            crushedShadows: Double(crushed) / Double(total))
    }

    /// Sample live scopes for the simulator stand-in camera so overlays render cleanly in previews and layout tests.
    public static func sample() -> LiveScopesData {
        let bins = LiveScopesData.histogramBins
        let cols = LiveScopesData.waveformColumns
        func bell(center: Float, width: Float) -> [Float] {
            (0..<bins).map { i in
                let x = Float(i) / Float(bins - 1)
                let d = (x - center) / width
                return exp(-0.5 * d * d)
            }
        }
        let wfMean = (0..<cols).map { i -> Float in
            let t = Float(i) / Float(cols - 1)
            return 0.32 + 0.36 * sin(t * .pi)
        }
        let wfMin = wfMean.map { max(0.05, $0 - 0.16) }
        let wfMax = wfMean.map { min(0.95, $0 + 0.18) }
        return LiveScopesData(
            red: bell(center: 0.42, width: 0.18),
            green: bell(center: 0.56, width: 0.2),
            blue: bell(center: 0.68, width: 0.18),
            luma: bell(center: 0.55, width: 0.22),
            waveformMin: wfMin, waveformMean: wfMean, waveformMax: wfMax,
            clippedHighlights: 0, crushedShadows: 0)
    }
}
