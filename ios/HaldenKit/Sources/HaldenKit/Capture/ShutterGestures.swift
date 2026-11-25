import Foundation

/// What a drag gesture starting on the photo shutter button means right now.
public enum ShutterDragAction: Equatable, Sendable {
    case none
    /// Dragged left from the shutter: capture a burst of photos.
    case burst
    /// Dragged right while recording QuickTake: lock recording hands-free.
    case lockQuickTake
    /// Dragged up while holding QuickTake: smoothly zoom in / out.
    case quickTakeZoom(Double)
}

/// Pure rules and math for camera shutter gestures (QuickTake hold/lock/zoom, burst swipe left,
/// tap-to-focus sun EV drag, and pause/resume elapsed recording time).
public enum ShutterGestures {
    /// Hold duration (seconds) on the photo shutter before QuickTake video starts.
    public static let quickTakeHoldSeconds = 0.35
    /// Horizontal drag distance (points) to trigger burst (left) or QuickTake lock (right).
    public static let horizontalThreshold = 44.0
    /// Vertical drag distance (points) upward before QuickTake zoom starts moving.
    public static let zoomDeadzone = 16.0
    /// Points dragged upward during QuickTake for one doubling of zoom.
    public static let zoomPointsPerDoubling = 140.0
    /// Points dragged vertically on the focus sun slider per 1 EV stop.
    public static let sunPointsPerStop = 40.0

    /// Evaluates a drag translation `(dx, dy)` on the shutter button.
    public static func evaluateDrag(
        dx: Double, dy: Double, quickTaking: Bool, locked: Bool, startZoom: Double, zoomRange: ClosedRange<Double>
    ) -> ShutterDragAction {
        if !quickTaking {
            if dx <= -horizontalThreshold, abs(dx) > abs(dy) {
                return .burst
            }
            return .none
        }
        guard !locked else { return .none }
        if dx >= horizontalThreshold, abs(dx) > abs(dy) {
            return .lockQuickTake
        }
        if dy < -zoomDeadzone {
            let effective = -dy - zoomDeadzone
            let target = startZoom * pow(2.0, effective / zoomPointsPerDoubling)
            return .quickTakeZoom(min(max(target, zoomRange.lowerBound), zoomRange.upperBound))
        }
        return .none
    }

    /// Computes a new exposure bias (EV) from dragging vertically beside the focus square:
    /// dragging up (`dy < 0`) brightens, dragging down (`dy > 0`) darkens.
    public static func sunExposureBias(
        from startBias: Double, dy: Double, range: ClosedRange<Double> = CameraControls.exposureBiasRange
    ) -> Double {
        let delta = -dy / sunPointsPerStop
        let raw = min(max(startBias + delta, range.lowerBound), range.upperBound)
        let rounded = (raw * 10).rounded() / 10
        return abs(rounded) < 0.05 ? 0 : rounded
    }

    /// Elapsed active recording duration excluding paused intervals.
    public static func recordingElapsed(
        started: Date, pausedAt: Date?, totalPaused: TimeInterval, now: Date
    ) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(started) - totalPaused)
    }
}
