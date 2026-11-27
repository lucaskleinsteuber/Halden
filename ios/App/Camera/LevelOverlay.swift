import CoreMotion
import HaldenKit
import Observation
import SwiftUI

/// Reads CoreMotion gravity, rotation rate and user acceleration to drive:
/// - horizon & overhead (flat-lay) level (`LevelOverlay`)
/// - tripod stability detection (`isOnTripod`) for up to 30 s Night Mode exposures
/// - live "Hold still" drift crosshair during Night Mode capture.
@MainActor
@Observable
final class MotionTracker {
    private(set) var reading: LevelReading = .hidden
    private(set) var isOnTripod = ProcessInfo.processInfo.arguments.contains("-ui-testing-tripod")
    private(set) var holdStillOffset: CGPoint = .zero
    private(set) var panoramaProgress = 0.0
    private(set) var panoramaOffAxis = 0.0
    private(set) var panoramaHint: PanoramaHint?
    private(set) var panoramaCompleted = false
    var showLevel = false {
        didSet {
            if !showLevel {
                reading = .hidden
            } else if running && !manager.isDeviceMotionAvailable {
                reading = .horizon(degrees: 4.5, aligned: false)
            }
        }
    }

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var visibility = LevelVisibility()
    @ObservationIgnored private var tripod = TripodDetector()
    @ObservationIgnored private var panoramaGuide = PanoramaGuide()
    @ObservationIgnored private var panoramaDirection: PanoramaDirection?
    @ObservationIgnored private var lastMotionTime: Double?
    @ObservationIgnored private var lastGravity = (x: 0.0, y: -1.0)
    @ObservationIgnored private var holdAnchor: (x: Double, y: Double)?
    @ObservationIgnored private var running = false

    func anchorHoldStill() {
        holdAnchor = lastGravity
        holdStillOffset = .zero
    }

    func clearHoldStill() {
        holdAnchor = nil
        holdStillOffset = .zero
    }

    func startPanorama(direction: PanoramaDirection) {
        panoramaGuide.reset()
        panoramaDirection = direction
        panoramaProgress = 0
        panoramaOffAxis = 0
        panoramaHint = nil
        panoramaCompleted = false
    }

    func stopPanorama() {
        panoramaDirection = nil
        panoramaProgress = 0
        panoramaOffAxis = 0
        panoramaHint = nil
        panoramaCompleted = false
    }

    func start() {
        guard !running else { return }
        running = true
        visibility = LevelVisibility()
        tripod = TripodDetector()
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-tripod") {
            isOnTripod = true
        }
        guard manager.isDeviceMotionAvailable else {
            // Simulator / devices without motion hardware: show a gentle sample tilt when level is on.
            if showLevel { reading = .horizon(degrees: 4.5, aligned: false) }
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let g = motion.gravity
            let rot = motion.rotationRate
            let acc = motion.userAcceleration
            let raw = LevelMath.reading(gravityX: g.x, y: g.y, z: g.z)
            let now = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.lastGravity = (g.x, g.y)
                if self.showLevel {
                    let shown = self.visibility.update(with: raw, at: now)
                    if self.reading != shown { self.reading = shown }
                } else if self.reading != .hidden {
                    self.reading = .hidden
                }
                let onTripod = self.tripod.update(
                    rotationX: rot.x, rotationY: rot.y, rotationZ: rot.z,
                    accelX: acc.x, accelY: acc.y, accelZ: acc.z, at: now)
                if self.isOnTripod != onTripod { self.isOnTripod = onTripod }
                if let anchor = self.holdAnchor {
                    let drift = TripodDetector.holdStillOffset(
                        gravityX: g.x, gravityY: g.y, anchorX: anchor.x, anchorY: anchor.y)
                    let offset = CGPoint(x: drift.dx, y: drift.dy)
                    if self.holdStillOffset != offset { self.holdStillOffset = offset }
                }
                if let dir = self.panoramaDirection {
                    let dt = self.lastMotionTime.map { min(max(now - $0, 0), 0.2) } ?? (1.0 / 30.0)
                    let pano = self.panoramaGuide.update(
                        rotationX: rot.x, rotationY: rot.y, rotationZ: rot.z, dt: dt, direction: dir)
                    // Only what changed, so only what shows it is drawn again.
                    if self.panoramaProgress != pano.progress { self.panoramaProgress = pano.progress }
                    if self.panoramaOffAxis != pano.offAxisNormalized { self.panoramaOffAxis = pano.offAxisNormalized }
                    if self.panoramaHint != pano.hint { self.panoramaHint = pano.hint }
                    if self.panoramaCompleted != pano.completed { self.panoramaCompleted = pano.completed }
                }
                self.lastMotionTime = now
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        reading = .hidden
        holdAnchor = nil
        holdStillOffset = .zero
    }
}

/// Apple-style camera level overlay: a thin broken horizon bar that snaps yellow when straight,
/// or twin crosshairs when aiming straight down / up (flat-lay).
struct LevelOverlay: View {
    let reading: LevelReading

    var body: some View {
        Group {
            switch reading {
            case .hidden:
                EmptyView()
            case .horizon(let degrees, let aligned):
                horizon(degrees: degrees, aligned: aligned)
            case .overhead(let dx, let dy, let aligned):
                overhead(dx: dx, dy: dy, aligned: aligned)
            }
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: reading.isAligned) { _, aligned in
            aligned
        }
    }

    private func horizon(degrees: Double, aligned: Bool) -> some View {
        let color: Color = aligned ? .yellow : .white
        return ZStack {
            // Stationary side reference ticks
            HStack(spacing: aligned ? 0 : 72) {
                Rectangle().fill(color.opacity(aligned ? 0 : 0.85)).frame(width: 24, height: 1.5)
                Rectangle().fill(color.opacity(aligned ? 0 : 0.85)).frame(width: 24, height: 1.5)
            }
            // Rotating horizon bar (merges into one continuous yellow line when aligned)
            Rectangle()
                .fill(color)
                .frame(width: aligned ? 120 : 62, height: 1.5)
                .rotationEffect(.degrees(aligned ? 0 : -degrees))
        }
        .shadow(color: .black.opacity(0.6), radius: 1.5)
        .animation(.easeOut(duration: 0.08), value: aligned)
        .accessibilityElement()
        .accessibilityLabel(aligned ? "Camera level" : "Camera tilted")
        .accessibilityIdentifier("camera-level")
    }

    private func overhead(dx: Double, dy: Double, aligned: Bool) -> some View {
        let color: Color = aligned ? .yellow : .white
        return ZStack {
            crosshair(color: color.opacity(aligned ? 1 : 0.75))
            if !aligned {
                crosshair(color: .yellow)
                    .offset(x: dx * 32, y: dy * 32)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 1.5)
        .animation(.easeOut(duration: 0.08), value: aligned)
        .accessibilityElement()
        .accessibilityLabel(aligned ? "Camera flat and level" : "Camera overhead tilt")
        .accessibilityIdentifier("camera-level")
    }

    private func crosshair(color: Color) -> some View {
        ZStack {
            Rectangle().fill(color).frame(width: 28, height: 1.5)
            Rectangle().fill(color).frame(width: 1.5, height: 28)
        }
    }
}

/// Apple-style Night Mode capture overlay: stationary white crosshair + live yellow drift crosshair
/// and "Hold still" guidance while short exposures are captured and stacked.
struct NightHoldStillOverlay: View {
    let offset: CGPoint
    let secondsLeft: Int?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                crosshair(color: .white.opacity(0.75))
                crosshair(color: .yellow)
                    .offset(x: offset.x * 26, y: offset.y * 26)
            }
            .shadow(color: .black.opacity(0.65), radius: 2)

            HStack(spacing: 6) {
                Image(systemName: "moon.stars.fill")
                Text("Hold still")
                if let secondsLeft, secondsLeft > 0 {
                    Text("\(secondsLeft)s").monospacedDigit()
                }
            }
            .font(.caption.bold())
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.yellow, in: .capsule)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hold still for Night Mode")
        .accessibilityIdentifier("night-hold-still")
    }

    private func crosshair(color: Color) -> some View {
        ZStack {
            Rectangle().fill(color).frame(width: 30, height: 1.5)
            Rectangle().fill(color).frame(width: 1.5, height: 30)
        }
    }
}
