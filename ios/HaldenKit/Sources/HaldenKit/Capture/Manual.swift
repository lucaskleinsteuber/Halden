import Foundation

/// Manual camera settings, as a photographer knows them: shutter speed in the usual steps (1/125,
/// 1/250 …), ISO in thirds of a stop, white balance in kelvin with a tint, focus from near to
/// far, and exposure compensation. Each one is either automatic (`nil`) or set; what the camera
/// can do limits what can be set.
public struct ManualSettings: Codable, Sendable, Equatable {
    /// Seconds the shutter is open.
    public var shutter: Double?
    public var iso: Double?
    /// Colour temperature in kelvin and tint (green −, magenta +).
    public var whiteBalance: WhiteBalance?
    /// 0 (nearest) to 1 (farthest), as the camera's lens position.
    public var focus: Double?
    /// Exposure compensation in stops, for automatic exposure.
    public var exposureBias: Double = 0

    public init(
        shutter: Double? = nil, iso: Double? = nil, whiteBalance: WhiteBalance? = nil, focus: Double? = nil,
        exposureBias: Double = 0
    ) {
        self.shutter = shutter
        self.iso = iso
        self.whiteBalance = whiteBalance
        self.focus = focus
        self.exposureBias = exposureBias
    }

    public struct WhiteBalance: Codable, Sendable, Equatable {
        public var kelvin: Double
        public var tint: Double

        public init(kelvin: Double, tint: Double = 0) {
            self.kelvin = kelvin
            self.tint = tint
        }
    }

    /// Everything automatic.
    public var isAutomatic: Bool {
        shutter == nil && iso == nil && whiteBalance == nil && focus == nil && exposureBias == 0
    }

    /// Exposure is set by hand as soon as either shutter or ISO is: the other one is then kept
    /// where the camera had it.
    public var exposureIsManual: Bool { shutter != nil || iso != nil }
}

/// What the camera in use can do, read from it.
public struct ManualLimits: Sendable, Equatable {
    public var shutter: ClosedRange<Double>
    public var iso: ClosedRange<Double>
    public var exposureBias: ClosedRange<Double>
    public var canFocus: Bool
    public var canSetWhiteBalance: Bool
    /// The colour temperatures this camera can really reach (beyond them its gains run out and
    /// the slider would do nothing).
    public var kelvin: ClosedRange<Double>

    public init(
        shutter: ClosedRange<Double>, iso: ClosedRange<Double>, exposureBias: ClosedRange<Double> = -8...8,
        canFocus: Bool = true, canSetWhiteBalance: Bool = true,
        kelvin: ClosedRange<Double> = ManualLimits.whiteBalanceKelvin
    ) {
        self.shutter = shutter
        self.iso = iso
        self.exposureBias = exposureBias
        self.canFocus = canFocus
        self.canSetWhiteBalance = canSetWhiteBalance
        let lower = max(kelvin.lowerBound, Self.whiteBalanceKelvin.lowerBound)
        let upper = min(kelvin.upperBound, Self.whiteBalanceKelvin.upperBound)
        self.kelvin = lower < upper ? lower...upper : Self.whiteBalanceKelvin
    }

    /// The range of temperatures whose gains `gainsFit` accepts, found in 100 K steps.
    public static func reachableKelvin(_ gainsFit: (Double) -> Bool) -> ClosedRange<Double> {
        let steps = stride(from: whiteBalanceKelvin.lowerBound, through: whiteBalanceKelvin.upperBound, by: 100)
        let fitting = steps.filter(gainsFit)
        guard let lowest = fitting.first, let highest = fitting.last, lowest < highest else {
            return whiteBalanceKelvin
        }
        return lowest...highest
    }

    public static let whiteBalanceKelvin: ClosedRange<Double> = 2500...10000
    public static let whiteBalanceTint: ClosedRange<Double> = -150...150

    /// The usual shutter speeds the camera can do, shortest first.
    public var shutterSteps: [Double] {
        Self.standardShutters.filter { shutter.contains($0) }
    }

    /// ISO in thirds of a stop, from the lowest the camera can do to the highest.
    public var isoSteps: [Double] {
        var steps: [Double] = []
        var value = iso.lowerBound
        while value <= iso.upperBound * 1.0001 {
            steps.append((value * 10).rounded() / 10)
            value *= pow(2, 1.0 / 3)
        }
        if let last = steps.last, last < iso.upperBound - 0.5 { steps.append(iso.upperBound) }
        return steps
    }

    /// Settings the camera can take: everything moved into its limits.
    public func fitted(_ settings: ManualSettings) -> ManualSettings {
        var fitted = settings
        fitted.shutter = settings.shutter.map { min(max($0, shutter.lowerBound), shutter.upperBound) }
        fitted.iso = settings.iso.map { min(max($0, iso.lowerBound), iso.upperBound) }
        fitted.focus = canFocus ? settings.focus.map { min(max($0, 0), 1) } : nil
        fitted.whiteBalance =
            canSetWhiteBalance
            ? settings.whiteBalance.map {
                ManualSettings.WhiteBalance(
                    kelvin: min(max($0.kelvin, kelvin.lowerBound), kelvin.upperBound),
                    tint: min(max($0.tint, Self.whiteBalanceTint.lowerBound), Self.whiteBalanceTint.upperBound))
            } : nil
        fitted.exposureBias = min(max(settings.exposureBias, exposureBias.lowerBound), exposureBias.upperBound)
        return fitted
    }

    /// Full and half stops from 1/8000 s to 30 s, as cameras show them.
    static let standardShutters: [Double] = [
        1 / 8000, 1 / 6400, 1 / 5000, 1 / 4000, 1 / 3200, 1 / 2500, 1 / 2000, 1 / 1600, 1 / 1250, 1 / 1000, 1 / 800,
        1 / 640, 1 / 500, 1 / 400, 1 / 320, 1 / 250, 1 / 200, 1 / 160, 1 / 125, 1 / 100, 1 / 80, 1 / 60, 1 / 50,
        1 / 40, 1 / 30, 1 / 25, 1 / 20, 1 / 15, 1 / 13, 1 / 10, 1 / 8, 1 / 6, 1 / 5, 1 / 4, 0.3, 0.4, 0.5, 0.6, 0.8, 1,
        1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30,
    ]
}

/// How manual values are written.
public enum ManualText {
    /// "1/125", "0.5\"", "2\"".
    public static func shutter(_ seconds: Double) -> String {
        if seconds < 0.3 { return "1/\(Int((1 / seconds).rounded()))" }
        let rounded = (seconds * 10).rounded() / 10
        return (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)) + "\""
    }

    public static func iso(_ value: Double) -> String { "ISO \(Int(value.rounded()))" }

    public static func kelvin(_ value: Double) -> String { "\(Int((value / 50).rounded() * 50)) K" }

    /// "+0.7", "0", "−1.3".
    public static func bias(_ stops: Double) -> String {
        let rounded = (stops * 10).rounded() / 10
        if rounded == 0 { return "0" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f", abs(rounded))
    }
}
