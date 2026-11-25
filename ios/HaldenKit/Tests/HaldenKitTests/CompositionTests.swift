import Foundation
import Testing

@testable import HaldenKit

struct CompositionTests {
    @Test func horizonLevelAnglesAndThresholds() {
        // Upright portrait: aligned at 0°.
        #expect(LevelMath.reading(gravityX: 0, y: -1, z: 0) == .horizon(degrees: 0, aligned: true))

        // Landscape right (1, 0, 0) and left (-1, 0, 0): also cardinal aligned.
        #expect(LevelMath.reading(gravityX: 1, y: 0, z: 0) == .horizon(degrees: 0, aligned: true))
        #expect(LevelMath.reading(gravityX: -1, y: 0, z: 0) == .horizon(degrees: 0, aligned: true))

        // Slight 5° tilt right: visible, not aligned.
        let fiveRad = 5.0 * .pi / 180
        let tilted = LevelMath.reading(gravityX: sin(fiveRad), y: -cos(fiveRad), z: 0)
        if case .horizon(let degrees, let aligned) = tilted {
            #expect(!aligned)
            #expect(abs(degrees - 5.0) < 0.05)
        } else {
            Issue.record("Expected tilted horizon, got \(tilted)")
        }

        // Steep 30° tilt: hidden so diagonal shots stay uncluttered.
        let thirtyRad = 30.0 * .pi / 180
        #expect(LevelMath.reading(gravityX: sin(thirtyRad), y: -cos(thirtyRad), z: 0) == .hidden)
    }

    @Test func overheadFlatLayCrosshairs() {
        // Flat face-down: aligned crosshairs at (0, 0).
        #expect(LevelMath.reading(gravityX: 0, y: 0, z: -1) == .overhead(dx: 0, dy: 0, aligned: true))
        // Flat face-up (looking straight up): also aligned.
        #expect(LevelMath.reading(gravityX: 0.01, y: -0.01, z: 0.99) == .overhead(dx: 0, dy: 0, aligned: true))

        // Slight tilt while looking down: non-zero normalized offset.
        let off = LevelMath.reading(gravityX: 0.125, y: 0.125, z: -0.95)
        if case .overhead(let dx, let dy, let aligned) = off {
            #expect(!aligned)
            #expect(abs(dx - 0.5) < 0.01)
            #expect(abs(dy + 0.5) < 0.01)
        } else {
            Issue.record("Expected overhead reading, got \(off)")
        }
    }

    @Test func horizonVisibilityHidesWhenSteadyAndFadesAfterLeveling() {
        var visibility = LevelVisibility()
        // Starting steady and level stays hidden.
        #expect(visibility.update(with: .horizon(degrees: 0, aligned: true), at: 10) == .hidden)
        // Slight tilt makes it appear.
        #expect(
            visibility.update(with: .horizon(degrees: 4, aligned: false), at: 11)
                == .horizon(degrees: 4, aligned: false))
        // Leveling back snaps yellow and stays briefly.
        #expect(
            visibility.update(with: .horizon(degrees: 0, aligned: true), at: 12) == .horizon(degrees: 0, aligned: true))
        #expect(
            visibility.update(with: .horizon(degrees: 0, aligned: true), at: 13) == .horizon(degrees: 0, aligned: true))
        // After holdAlignedSeconds it fades out again.
        #expect(visibility.update(with: .horizon(degrees: 0, aligned: true), at: 14) == .hidden)
        // Overhead crosshairs remain visible even when aligned.
        #expect(
            visibility.update(with: .overhead(dx: 0, dy: 0, aligned: true), at: 15)
                == .overhead(dx: 0, dy: 0, aligned: true))
    }

    @Test func focalLengthTapCyclesMainLensOnly() {
        let range = 0.5...10.0
        // Already on 1× (24 mm): tap cycles 24 → 28 → 35 → 24 mm.
        let to28 = LevelMath.focalTap(
            currentZoom: 1.0, defaultFocal: .mm24, activePreset: 1.0, presetTapped: 1.0, isBackCamera: true,
            zoomRange: range)
        #expect(to28.zoom == 1.2)
        #expect(to28.badge == .mm28)

        let to35 = LevelMath.focalTap(
            currentZoom: 1.2, defaultFocal: .mm24, activePreset: 1.0, presetTapped: 1.0, isBackCamera: true,
            zoomRange: range)
        #expect(to35.zoom == 1.5)
        #expect(to35.badge == .mm35)

        let backTo24 = LevelMath.focalTap(
            currentZoom: 1.5, defaultFocal: .mm24, activePreset: 1.0, presetTapped: 1.0, isBackCamera: true,
            zoomRange: range)
        #expect(backTo24.zoom == 1.0)
        #expect(backTo24.badge == .mm24)

        // Coming from 2× goes to default focal length (e.g. 28 mm).
        let fromTwo = LevelMath.focalTap(
            currentZoom: 2.0, defaultFocal: .mm28, activePreset: 2.0, presetTapped: 1.0, isBackCamera: true,
            zoomRange: range)
        #expect(fromTwo.zoom == 1.2)
        #expect(fromTwo.badge == .mm28)

        // Tapping 2× or tapping 1× on front camera does not cycle focal lengths.
        let tapTwo = LevelMath.focalTap(
            currentZoom: 2.0, defaultFocal: .mm24, activePreset: 2.0, presetTapped: 2.0, isBackCamera: true,
            zoomRange: range)
        #expect(tapTwo.zoom == 2.0)
        #expect(tapTwo.badge == nil)

        let front = LevelMath.focalTap(
            currentZoom: 1.0, defaultFocal: .mm24, activePreset: 1.0, presetTapped: 1.0, isBackCamera: false,
            zoomRange: 1.0...5.0)
        #expect(front.zoom == 1.0)
        #expect(front.badge == nil)
    }
}
