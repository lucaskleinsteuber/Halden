import CoreImage
import Foundation
import Testing

@testable import HaldenKit

@Suite struct PanoramaTests {
    @Test func directionsAndCoreMotionGuideEmitSpeedAndLineHints() {
        #expect(PanoramaDirection.leftToRight.reversed == .rightToLeft)
        #expect(PanoramaDirection.rightToLeft.reversed == .leftToRight)
        #expect(PanoramaDirection.bottomToTop.reversed == .topToBottom)
        #expect(PanoramaDirection.topToBottom.reversed == .bottomToTop)
        #expect(PanoramaDirection.leftToRight.toggledOrientation.isVertical)
        #expect(!PanoramaDirection.bottomToTop.toggledOrientation.isVertical)

        // Steady horizontal sweep: advances progress cleanly with no hints.
        var guide = PanoramaGuide()
        let steady = guide.update(rotationX: 0.0, rotationY: -0.35, rotationZ: 0.0, dt: 0.5, direction: .leftToRight)
        #expect(steady.progress > 0.03)
        #expect(steady.hint == nil)
        #expect(!steady.completed)

        // Too fast pan triggers "Move slower."
        let fast = guide.update(rotationX: 0.0, rotationY: -1.1, rotationZ: 0.0, dt: 0.2, direction: .leftToRight)
        #expect(fast.hint == .moveSlower)

        // Off-axis tilt > 4.3° triggers "Keep arrow on the line."
        guide.reset()
        let tilted = guide.update(rotationX: 0.3, rotationY: -0.25, rotationZ: 0.0, dt: 0.4, direction: .leftToRight)
        #expect(tilted.hint == .keepOnLine)

        // Completing full sweep sets completed = true.
        guide.reset()
        var last = guide.update(rotationX: 0, rotationY: -0.5, rotationZ: 0, dt: 1.0, direction: .leftToRight)
        for _ in 0..<8 {
            last = guide.update(rotationX: 0, rotationY: -0.5, rotationZ: 0, dt: 1.0, direction: .leftToRight)
        }
        #expect(last.completed)
        #expect(last.progress == 1.0)
    }

    @Test func stitcherReconstructsHorizontalAndVerticalPanoramasAndBenchmarks() throws {
        // 1. Horizontal panorama (leftToRight): slice a 1530×360 textured landscape into 8 overlapping 480×360 tiles (~69% overlap).
        let wideScene = makeTexturedScene(width: 1530, height: 360)
        var horizTiles: [CIImage] = []
        for i in 0..<8 {
            let x = i * 150
            let tile = wideScene.cropped(to: CGRect(x: x, y: 0, width: 480, height: 360))
            horizTiles.append(tile)
        }
        let horizResult = try #require(
            PanoramaStitcher.stitch(frames: horizTiles, direction: .leftToRight, preferHEIC: true))
        #expect(horizResult.frameCount == 8)
        #expect(horizResult.width >= 1450 && horizResult.width <= 1560, "width \(horizResult.width)")
        #expect(horizResult.height >= 340 && horizResult.height <= 365, "height \(horizResult.height)")
        #expect(horizResult.data.count > 5000)

        // Reversed direction (rightToLeft): feed tiles in reverse order.
        let rtlResult = try #require(
            PanoramaStitcher.stitch(frames: Array(horizTiles.reversed()), direction: .rightToLeft, preferHEIC: true))
        #expect(rtlResult.width >= 1450 && rtlResult.width <= 1560, "RTL width \(rtlResult.width)")

        // 2. Vertical panorama (bottomToTop): slice a 360×1110 textured scene into 7 overlapping 360×420 tiles (~73% overlap).
        let tallScene = makeTexturedScene(width: 360, height: 1110)
        var vertTiles: [CIImage] = []
        for i in 0..<7 {
            let y = i * 115
            let tile = tallScene.cropped(to: CGRect(x: 0, y: y, width: 360, height: 420))
            vertTiles.append(tile)
        }
        let vertResult = try #require(
            PanoramaStitcher.stitch(frames: vertTiles, direction: .bottomToTop, preferHEIC: true))
        #expect(vertResult.height >= 1060 && vertResult.height <= 1140, "vertical height \(vertResult.height)")
        #expect(vertResult.width >= 340 && vertResult.width <= 365, "vertical width \(vertResult.width)")

        // 2b. Gyroscope fallback aligns even completely textureless frames (e.g., clear blue sky).
        let sky = CIImage(color: CIColor(red: 0.35, green: 0.62, blue: 0.92)).cropped(
            to: CGRect(x: 0, y: 0, width: 320, height: 240))
        let skyHints = [CGVector(dx: 100, dy: 0), CGVector(dx: 100, dy: 0)]
        let skyResult = try #require(
            PanoramaStitcher.stitch(
                frames: [sky, sky, sky], direction: .leftToRight, gyroHints: skyHints, preferHEIC: true))
        #expect(skyResult.width == 520 && skyResult.height == 240)

        // 3. Benchmark: 12 overlapping 1280×720 frames -> ~4500×720 HEIC panorama (time + memory).
        let benchScene = makeTexturedScene(width: 4580, height: 720)
        var benchTiles: [CIImage] = []
        for i in 0..<12 {
            benchTiles.append(benchScene.cropped(to: CGRect(x: i * 300, y: 0, width: 1280, height: 720)))
        }
        let memBefore = PanoramaStitcher.currentMemoryBytes()
        let start = ContinuousClock.now
        let benchResult = try #require(
            PanoramaStitcher.stitch(frames: benchTiles, direction: .leftToRight, preferHEIC: true))
        let elapsed = ContinuousClock.now - start
        let ms =
            Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        let peakMB = Double(benchResult.peakMemoryBytes) / (1024 * 1024)
        let deltaMB =
            Double(benchResult.peakMemoryBytes > memBefore ? benchResult.peakMemoryBytes - memBefore : 0)
            / (1024 * 1024)
        print(
            String(
                format:
                    "BENCHMARK_C10_PANO: 12x 1280x720 -> %dx%d stitched in %.1f ms (heic=%@, bytes=%d, peak=%.1f MB, delta=%.1f MB)",
                benchResult.width, benchResult.height, ms, String(benchResult.heic),
                benchResult.data.count, peakMB, deltaMB))
    }

    /// Generates a richly textured, aperiodic multi-scale landscape so Vision translational
    /// registration has unique features everywhere without periodic aliasing.
    private func makeTexturedScene(width: Int, height: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Generate deterministic unique landmarks (coloured rectangles & circles) across the canvas.
        var rng: UInt64 = 0x517C_C1B7_2722_0A95
        func nextRand() -> UInt64 {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return rng >> 32
        }
        for y in 0..<height {
            let yf = Double(y) / Double(height)
            for x in 0..<width {
                let xf = Double(x) / Double(width)
                let idx = (y * width + x) * 4
                let hVal = Int(nextRand() % 24)
                bytes[idx] = UInt8(min(255, 50 + Int(xf * 90) + hVal))
                bytes[idx + 1] = UInt8(min(255, 70 + Int(yf * 85) + hVal))
                bytes[idx + 2] = UInt8(min(255, 110 + Int((1 - xf) * 70) + hVal))
            }
        }
        let landmarkCount = max(80, (width * height) / 4500)
        for _ in 0..<landmarkCount {
            let rw = 14 + Int(nextRand() % 44)
            let rh = 14 + Int(nextRand() % 44)
            let rx = Int(nextRand() % UInt64(max(1, width - rw)))
            let ry = Int(nextRand() % UInt64(max(1, height - rh)))
            let r = UInt8(30 + nextRand() % 210)
            let g = UInt8(30 + nextRand() % 210)
            let b = UInt8(30 + nextRand() % 210)
            for y in ry..<(ry + rh) {
                for x in rx..<(rx + rw) {
                    let idx = (y * width + x) * 4
                    bytes[idx] = r
                    bytes[idx + 1] = g
                    bytes[idx + 2] = b
                }
            }
        }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: width * 4,
            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
