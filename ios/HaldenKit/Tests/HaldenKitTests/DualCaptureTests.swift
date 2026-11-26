import CoreGraphics
import CoreImage
import Foundation
import HaldenKit
import ImageIO
import Testing

@Suite("Dual Capture & Outside Frame")
struct DualCaptureTests {
    @Test("PiP layout positions, clamps and snaps cleanly to all four corners")
    func pipLayoutMath() {
        let size = CGSize(width: 400, height: 600)
        let tl = PiPLayout.rect(in: size, corner: .topLeft)
        let tr = PiPLayout.rect(in: size, corner: .topRight)
        let bl = PiPLayout.rect(in: size, corner: .bottomLeft)
        let br = PiPLayout.rect(in: size, corner: .bottomRight)

        #expect(tl.minX < tr.minX)
        #expect(tl.minY < bl.minY)
        #expect(tr.maxX <= size.width - PiPLayout.defaultMargin + 0.5)
        #expect(br.maxY <= size.height - PiPLayout.defaultMargin + 0.5)

        #expect(PiPLayout.nearestCorner(for: CGPoint(x: 50, y: 80), in: size) == .topLeft)
        #expect(PiPLayout.nearestCorner(for: CGPoint(x: 350, y: 80), in: size) == .topRight)
        #expect(PiPLayout.nearestCorner(for: CGPoint(x: 50, y: 520), in: size) == .bottomLeft)
        #expect(PiPLayout.nearestCorner(for: CGPoint(x: 350, y: 520), in: size) == .bottomRight)

        let clamped = PiPLayout.clamp(center: CGPoint(x: -100, y: 999), pipSize: tl.size, in: size)
        #expect(clamped.x >= PiPLayout.defaultMargin + tl.width / 2)
        #expect(clamped.y <= size.height - PiPLayout.defaultMargin - tl.height / 2)
    }

    @Test("DualCompositor places secondary camera feed in the chosen corner and encodes HEIC")
    func dualCompositorPixelVerification() throws {
        // Blue primary (640x480), bright red secondary (320x240) placed in topRight.
        let primary = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let secondary = CIImage(color: CIColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))

        let encoded = try #require(
            DualCompositor.encodePhoto(primary: primary, secondary: secondary, corner: .topRight, preferHEIC: true))
        #expect(encoded.width == 640)
        #expect(encoded.height == 480)
        #expect(encoded.data.count > 200)

        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: 640 * 480 * 4)
        let ctx = try #require(
            CGContext(
                data: &pixels, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 640, height: 480))

        // Top-right area (in UI coords -> top-right of CGImage bitmap, row ~60, col ~560) should be red.
        let trOffset = (60 * 640 + 560) * 4
        #expect(pixels[trOffset] > 180, "top-right PiP should be red")
        #expect(pixels[trOffset + 2] < 80)

        // Bottom-left area (row ~400, col ~60) should still be blue primary.
        let blOffset = (400 * 640 + 60) * 4
        #expect(pixels[blOffset + 2] > 170, "bottom-left primary should stay blue")
        #expect(pixels[blOffset] < 80)
    }

    @Test("Outside-frame activation requires Photo mode, ultra-wide lens, and zoom >= 1x")
    func outsideFrameRules() {
        #expect(OutsideFrameMath.isActive(enabled: true, isPhotoMode: true, zoom: 1.0, hasUltraWide: true))
        #expect(OutsideFrameMath.isActive(enabled: true, isPhotoMode: true, zoom: 2.0, hasUltraWide: true))
        #expect(!OutsideFrameMath.isActive(enabled: true, isPhotoMode: true, zoom: 0.5, hasUltraWide: true))
        #expect(!OutsideFrameMath.isActive(enabled: false, isPhotoMode: true, zoom: 1.0, hasUltraWide: true))
        #expect(!OutsideFrameMath.isActive(enabled: true, isPhotoMode: false, zoom: 1.0, hasUltraWide: true))
        #expect(!OutsideFrameMath.isActive(enabled: true, isPhotoMode: true, zoom: 1.0, hasUltraWide: false))
        #expect(abs(OutsideFrameMath.innerFraction(zoom: 1.0) - 0.5) < 0.001)
        #expect(abs(OutsideFrameMath.innerFraction(zoom: 2.0) - 0.25) < 0.001)
    }
}
