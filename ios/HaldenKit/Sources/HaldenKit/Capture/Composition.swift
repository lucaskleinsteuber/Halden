import Foundation

/// What the camera's level shows, computed from the device's gravity vector.
public enum LevelReading: Equatable, Sendable {
    /// Steeply tilted or steady upright: stay out of the way, as in Apple's camera.
    case hidden
    /// Horizontal or vertical horizon line, tilted by `degrees` (−20…+20) from the nearest 90°.
    case horizon(degrees: Double, aligned: Bool)
    /// Looking straight down (flat-lay) or straight up: two crosshairs offset by `dx` and `dy`
    /// (normalized to −1…+1).
    case overhead(dx: Double, dy: Double, aligned: Bool)

    public var isAligned: Bool {
        switch self {
        case .hidden: false
        case .horizon(_, let aligned), .overhead(_, _, let aligned): aligned
        }
    }
}

/// Pure composition helpers: horizon & flat-lay level math (CoreMotion gravity vector) and
/// 24 / 28 / 35 mm focal length cycling on the 1× button.
public enum LevelMath {
    /// Horizon line appears only when within ±20° of horizontal or vertical.
    public static let horizonShowLimitDegrees = 20.0
    /// Within ±1° the horizon snaps straight and turns yellow.
    public static let horizonAlignedDegrees = 1.0
    /// Gravity |z| above this switches from horizon line to overhead / flat-lay crosshairs.
    public static let overheadZThreshold = 0.85
    /// Overhead horizontal gravity component below this snaps the crosshairs together.
    public static let overheadAlignedRadius = 0.03
    /// Overhead gravity magnitude that maps to full crosshair displacement (±1).
    public static let overheadFullScale = 0.25

    /// Turns a CoreMotion gravity vector (screen right +x, screen up +y, out of screen +z) into
    /// a level reading.
    public static func reading(gravityX x: Double, y: Double, z: Double) -> LevelReading {
        guard x.isFinite, y.isFinite, z.isFinite else { return .hidden }
        if abs(z) >= overheadZThreshold {
            let radius = hypot(x, y)
            let aligned = radius <= overheadAlignedRadius
            if aligned { return .overhead(dx: 0, dy: 0, aligned: true) }
            let dx = min(max(x / overheadFullScale, -1), 1)
            let dy = min(max(-y / overheadFullScale, -1), 1)
            return .overhead(dx: dx, dy: dy, aligned: false)
        }
        guard hypot(x, y) > 0.1 else { return .hidden }
        // Upright portrait is (0, -1) → 0°; tilted right is positive degrees.
        let rawDegrees = atan2(x, -y) * 180 / .pi
        let nearestCardinal = (rawDegrees / 90).rounded() * 90
        var tilt = rawDegrees - nearestCardinal
        if tilt > 45 { tilt -= 90 }
        if tilt < -45 { tilt += 90 }
        guard abs(tilt) <= horizonShowLimitDegrees else { return .hidden }
        let aligned = abs(tilt) <= horizonAlignedDegrees
        return .horizon(degrees: aligned ? 0 : tilt, aligned: aligned)
    }

    /// What tapping a zoom preset button does, supporting 24 / 28 / 35 mm cycling on the 1× button
    /// of the back camera (1.0× / 1.2× / 1.5×).
    public static func focalTap(
        currentZoom: Double, defaultFocal: FocalLength, activePreset: Double?, presetTapped: Double,
        isBackCamera: Bool, zoomRange: ClosedRange<Double>
    ) -> (zoom: Double, badge: FocalLength?) {
        let canCycle =
            isBackCamera && abs(presetTapped - 1.0) < 0.01 && zoomRange.contains(FocalLength.mm35.zoomFactor)
        guard canCycle else { return (presetTapped, nil) }

        let onMainPreset = activePreset.map { abs($0 - 1.0) < 0.01 } ?? false
        if onMainPreset {
            if let current = FocalLength.matching(zoom: currentZoom) {
                let next = current.next
                return (next.zoomFactor, next)
            }
            return (defaultFocal.zoomFactor, defaultFocal)
        }
        return (defaultFocal.zoomFactor, defaultFocal == .mm24 ? nil : defaultFocal)
    }
}

/// Applies Apple-like visibility hysteresis to the horizon level: stays hidden when steady and
/// upright, appears on slight tilt, turns yellow when leveled, and fades out again after staying
/// level for `holdAlignedSeconds`. Overhead crosshairs stay visible while aiming straight down/up.
public struct LevelVisibility: Equatable, Sendable {
    public static let holdAlignedSeconds: TimeInterval = 1.5

    private var wasTilted = false
    private var alignedSince: TimeInterval?

    public init() {}

    public mutating func update(with raw: LevelReading, at time: TimeInterval) -> LevelReading {
        switch raw {
        case .hidden:
            wasTilted = false
            alignedSince = nil
            return .hidden
        case .overhead:
            wasTilted = false
            alignedSince = nil
            return raw
        case .horizon(_, let aligned):
            if !aligned {
                wasTilted = true
                alignedSince = nil
                return raw
            }
            guard wasTilted else { return .hidden }
            if alignedSince == nil { alignedSince = time }
            if let since = alignedSince, time - since <= Self.holdAlignedSeconds {
                return .horizon(degrees: 0, aligned: true)
            }
            wasTilted = false
            alignedSince = nil
            return .hidden
        }
    }
}
