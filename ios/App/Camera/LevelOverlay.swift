import CoreMotion
import HaldenKit
import Observation
import SwiftUI

/// Reads CoreMotion gravity to drive the camera's horizon and overhead (flat-lay) level.
/// In the simulator (where CoreMotion has no accelerometer), shows a slight sample tilt when
/// enabled so the overlay can be verified visually and in layout tests.
@MainActor
@Observable
final class MotionTracker {
    private(set) var reading: LevelReading = .hidden
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var visibility = LevelVisibility()
    @ObservationIgnored private var running = false

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard !running else { return }
        running = true
        visibility = LevelVisibility()
        guard manager.isDeviceMotionAvailable else {
            // Simulator / devices without motion hardware: show a gentle sample tilt.
            reading = .horizon(degrees: 4.5, aligned: false)
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            let raw = LevelMath.reading(gravityX: gravity.x, y: gravity.y, z: gravity.z)
            let now = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                let shown = self.visibility.update(with: raw, at: now)
                if self.reading != shown { self.reading = shown }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        reading = .hidden
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
