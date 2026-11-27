import CoreImage
import Foundation
import Testing

@testable import HaldenKit

@Suite struct NightModeTests {
    @Test func darknessDetectionHandheldTripodAndPreserveSettings() throws {
        // Bright daylight: no Night Mode suggested.
        #expect(!NightMath.isDark(iso: 100, shutterSeconds: 1.0 / 250))
        #expect(NightMath.suggestedSeconds(iso: 100, shutterSeconds: 1.0 / 250, onTripod: false) == nil)

        // An ordinary room in the evening: a normal photo, not Night Mode.
        #expect(!NightMath.isDark(iso: 1000, shutterSeconds: 1.0 / 25))
        #expect(!NightMath.isDark(iso: 1250, shutterSeconds: 1.0 / 30))

        // Really dim light handheld: 1–3 s.
        #expect(NightMath.isDark(iso: 1250, shutterSeconds: 1.0 / 15))
        let dimHandheld = try #require(NightMath.suggestedSeconds(iso: 1250, shutterSeconds: 1.0 / 15, onTripod: false))
        #expect((1...3).contains(dimHandheld))

        // Very dark scene handheld vs tripod (up to 30 s on tripod).
        let darkHandheld = try #require(
            NightMath.suggestedSeconds(iso: 3200, shutterSeconds: 1.0 / 10, onTripod: false))
        let darkTripod = try #require(NightMath.suggestedSeconds(iso: 3200, shutterSeconds: 1.0 / 10, onTripod: true))
        #expect(darkHandheld == 3)
        #expect(darkTripod == 30)

        // Effective seconds respect Off / Auto / manual clamping.
        #expect(NightMath.effectiveSeconds(setting: .off, suggested: 3, onTripod: false) == 0)
        #expect(NightMath.effectiveSeconds(setting: .auto, suggested: 2, onTripod: false) == 2)
        #expect(NightMath.effectiveSeconds(setting: .seconds(25), suggested: 3, onTripod: false) == 10)
        #expect(NightMath.effectiveSeconds(setting: .seconds(25), suggested: 20, onTripod: true) == 25)

        // TripodDetector requires >= 1.5 s of stillness and resets on movement.
        var detector = TripodDetector()
        let t1 = detector.update(rotationX: 0.01, rotationY: 0, rotationZ: 0, accelX: 0, accelY: 0, accelZ: 0, at: 1.0)
        let t2 = detector.update(rotationX: 0.01, rotationY: 0, rotationZ: 0, accelX: 0, accelY: 0, accelZ: 0, at: 2.0)
        let t3 = detector.update(rotationX: 0.01, rotationY: 0, rotationZ: 0, accelX: 0, accelY: 0, accelZ: 0, at: 2.6)
        let t4 = detector.update(rotationX: 0.25, rotationY: 0, rotationZ: 0, accelX: 0, accelY: 0, accelZ: 0, at: 2.8)
        #expect(!t1)
        #expect(!t2)
        #expect(t3)
        #expect(!t4)

        // Preserve Night Mode setting round-trip.
        var settings = AppSettings()
        settings.nightMode = .off
        settings.preserveNightMode = false
        #expect(CameraControls.resetUnpreserved(in: settings).nightMode == .auto)
        settings.preserveNightMode = true
        #expect(CameraControls.resetUnpreserved(in: settings).nightMode == .off)
    }

    @Test func nightStackerReducesNoiseRejectsOutliersAndBenchmarksSpeed() throws {
        // Synthesize a textured scene (smooth gradient + vertical stripes so Vision can align shifts)
        // and generate 6 noisy frames with +/- 2 px jitter and an outlier bright square in frame 3.
        let width = 320
        let height = 240
        var frames: [CIImage] = []
        for index in 0..<6 {
            let sx = index == 0 ? 0 : (index % 2 == 0 ? 2 : -2)
            let sy = index == 0 ? 0 : (index % 3 == 0 ? 1 : -1)
            frames.append(
                makeNoisyFrame(
                    width: width, height: height, seed: UInt64(1000 + index * 97),
                    shiftX: sx, shiftY: sy, noiseAmplitude: 38, injectOutlierSquare: index == 3))
        }
        // Measure pure high-frequency noise inside the smooth central gradient region (excluding
        // outer registration checkerboard landmarks).
        let smoothRegion = CGRect(x: 80, y: 60, width: 160, height: 120)
        let singleNoise = NightStacker.noiseLevel(of: frames[0].cropped(to: smoothRegion))
        let result = try #require(NightStacker.stack(frames: frames, preferHEIC: true))
        let stackedImage = try #require(CIImage(data: result.data))
        let stackedNoise = NightStacker.noiseLevel(of: stackedImage.cropped(to: smoothRegion))

        #expect(result.width == width && result.height == height)
        #expect(result.alignedFrames >= 1)
        #expect(singleNoise > 0.04, "synthetic input frame is measurably noisy (\(singleNoise))")
        #expect(
            stackedNoise < singleNoise * 0.55,
            "stacked image must have measurably less noise (\(stackedNoise)) than single noisy frame (\(singleNoise))")

        // Verify the bright white outlier square in frame 3 did NOT bleed into the center region.
        let centerLuma = sampleRegionLuma(stackedImage, x: 140, y: 100, w: 32, h: 32)
        #expect(centerLuma < 0.72, "outlier bright square should be rejected (center luma \(centerLuma))")

        // Benchmark 6x 1920x1080 frames to record real stacking latency.
        var hdFrames: [CIImage] = []
        for index in 0..<6 {
            let sx = index == 0 ? 0 : (index % 2 == 0 ? 2 : -1)
            hdFrames.append(
                makeNoisyFrame(
                    width: 1920, height: 1080, seed: UInt64(5000 + index * 31),
                    shiftX: sx, shiftY: 0, noiseAmplitude: 32, injectOutlierSquare: false))
        }
        let start = ContinuousClock.now
        let hdResult = try #require(NightStacker.stack(frames: hdFrames, preferHEIC: true))
        let elapsed = ContinuousClock.now - start
        let ms =
            Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        print(
            String(
                format:
                    "BENCHMARK_C8_NIGHT: 6x 1920x1080 stacked in %.1f ms (metal=%@, heic=%@, bytes=%d, singleNoise=%.4f, stackedNoise=%.4f)",
                ms, String(hdResult.usedMetal), String(hdResult.heic), hdResult.data.count, singleNoise, stackedNoise))
    }

    private func makeNoisyFrame(
        width: Int, height: Int, seed: UInt64, shiftX: Int, shiftY: Int,
        noiseAmplitude: Int, injectOutlierSquare: Bool
    ) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var rng = seed &+ 0x9E37_79B9_7F4A_7C15
        @inline(__always) func nextNoise() -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u = Int((rng >> 33) % UInt64(noiseAmplitude * 2 + 1))
            return u - noiseAmplitude
        }
        for y in 0..<height {
            let sy = min(max(y + shiftY, 0), height - 1)
            for x in 0..<width {
                let sx = min(max(x + shiftX, 0), width - 1)
                let idx = (y * width + x) * 4
                // Structured low-light scene: crisp outer registration landmarks + smooth interior gradient.
                let inBorder = sx < 72 || sx >= width - 72 || sy < 52 || sy >= height - 52
                let landmark = inBorder && ((sx / 24 + sy / 24) % 2 == 0) ? 45 : 0
                let baseR = 55 + (sx * 60) / width + landmark
                let baseG = 62 + (sy * 55) / height + landmark
                let baseB = 80 + ((sx + sy) * 35) / (width + height) + landmark
                let n1 = nextNoise()
                let n2 = nextNoise()
                let n3 = nextNoise()
                var r = min(max(baseR + n1, 0), 255)
                var g = min(max(baseG + n2, 0), 255)
                var b = min(max(baseB + n3, 0), 255)
                if injectOutlierSquare && sx >= 136 && sx < 176 && sy >= 96 && sy < 136 {
                    r = 250
                    g = 250
                    b = 250
                }
                bytes[idx] = UInt8(r)
                bytes[idx + 1] = UInt8(g)
                bytes[idx + 2] = UInt8(b)
                bytes[idx + 3] = 255
            }
        }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: width * 4,
            size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func sampleRegionLuma(_ image: CIImage, x: Int, y: Int, w: Int, h: Int) -> Double {
        let rect = CGRect(x: x, y: y, width: w, height: h)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(
            image, toBitmap: &bytes, rowBytes: w * 4, bounds: rect, format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        var sum = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum += (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255.0
        }
        return sum / Double(w * h)
    }
}
