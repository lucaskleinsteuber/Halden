import Foundation

/// How the camera zooms, as people know it from Apple's camera: zoom works in doublings (0.5 →
/// 1 → 2 is two equal steps), a tap on a lens button glides there in about the same time however
/// far it is, and a finger on the screen or the dial is followed closely but smoothly.
public enum Zoom {
    /// How long a tap on a lens button takes to get there.
    public static let glideSeconds = 0.3

    /// The rate for `AVCaptureDevice.ramp(toVideoZoomFactor:withRate:)`, in doublings per second,
    /// so that going from `from` to `to` takes `seconds`.
    public static func glideRate(from: Double, to: Double, seconds: Double = glideSeconds) -> Float {
        guard from > 0, to > 0, seconds > 0 else { return 1 }
        let doublings = abs(log2(to / from))
        // Even a tiny step moves visibly, not in one jump.
        return Float(max(doublings / seconds, 0.25))
    }

    /// The rate while following a finger: about four frames behind a quick pinch, which smooths
    /// the steps between touches without feeling slow.
    public static let followRate: Float = 16

    /// The zoom for a pinch that began at `start` and has `scale` now. Pinching is already in
    /// doublings (twice as far apart, twice the zoom).
    public static func pinched(from start: Double, scale: Double, in range: ClosedRange<Double>) -> Double {
        clamp(start * max(scale, 0.01), to: range)
    }

    /// Points to drag the dial for one doubling.
    public static let dialPointsPerDoubling = 110.0

    /// The zoom after dragging the dial `points` to the left (negative: to the right) from
    /// `start`. Like Apple's dial: drag left to zoom in.
    public static func dialed(from start: Double, points: Double, in range: ClosedRange<Double>) -> Double {
        clamp(start * pow(2, points / dialPointsPerDoubling), to: range)
    }

    /// Where `value` sits on the dial, in points from the middle, while `current` is in the middle.
    public static func dialOffset(of value: Double, current: Double) -> Double {
        guard value > 0, current > 0 else { return 0 }
        return log2(value / current) * dialPointsPerDoubling
    }

    /// The marks on the dial between the lowest and the highest zoom: a long one at every lens
    /// button, short ones between (at 0.1 below 2×, at 0.5 below 10×, then every 1×).
    public static func dialMarks(in range: ClosedRange<Double>, presets: [Double]) -> [DialMark] {
        var marks: [DialMark] = []
        var value = (range.lowerBound * 10).rounded(.up) / 10
        while value <= range.upperBound + 0.0001 {
            let major = presets.contains { abs($0 - value) < 0.05 }
            marks.append(DialMark(value: value, major: major))
            let step = value < 2 - 0.0001 ? 0.1 : value < 10 - 0.0001 ? 0.5 : 1
            value = ((value + step) * 10).rounded() / 10
        }
        for preset in presets where !marks.contains(where: { abs($0.value - preset) < 0.05 }) {
            marks.append(DialMark(value: preset, major: true))
        }
        return marks.sorted { $0.value < $1.value }
    }

    /// The lens button a zoom belongs to: the highest one at or below it.
    public static func activePreset(for zoom: Double, presets: [Double]) -> Double? {
        presets.sorted().last { zoom >= $0 - 0.01 } ?? presets.min()
    }

    /// How a zoom is written: "0.5", "1", "2.4", "10".
    public static func text(_ factor: Double) -> String {
        let rounded = (factor * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A mark on the zoom dial.
public struct DialMark: Equatable, Sendable {
    public var value: Double
    /// At a lens button: long and labelled.
    public var major: Bool
}
