import Foundation
import Testing

@testable import HaldenKit

@Suite struct ManualTests {
    let iPhone = ManualLimits(shutter: (1.0 / 8000)...1, iso: 50...3200, exposureBias: -8...8)

    @Test func theStepsAreTheUsualOnesTheCameraCanDo() {
        let shutters = iPhone.shutterSteps
        #expect(shutters.first == 1.0 / 8000 && shutters.last == 1)
        #expect(shutters.contains(1.0 / 125) && !shutters.contains(2))
        let isos = iPhone.isoSteps
        #expect(isos.first == 50 && isos.last == 3200)
        #expect(isos.contains(100) && isos.contains(800))
        #expect(isos.count == 19, "six stops in thirds: \(isos)")
    }

    @Test func settingsAreMovedIntoWhatTheCameraCanDo() {
        let wild = ManualSettings(
            shutter: 5, iso: 10, whiteBalance: .init(kelvin: 20000, tint: -400), focus: 1.5, exposureBias: 12)
        let fitted = iPhone.fitted(wild)
        #expect(fitted.shutter == 1 && fitted.iso == 50 && fitted.focus == 1 && fitted.exposureBias == 8)
        #expect(fitted.whiteBalance == .init(kelvin: 10000, tint: -150))
        let noFocus = ManualLimits(shutter: 0.001...1, iso: 50...800, canFocus: false, canSetWhiteBalance: false)
        let without = noFocus.fitted(wild)
        #expect(without.focus == nil && without.whiteBalance == nil)
    }

    @Test func automaticIsTheStart() {
        var settings = ManualSettings()
        #expect(settings.isAutomatic && !settings.exposureIsManual)
        settings.iso = 400
        #expect(!settings.isAutomatic && settings.exposureIsManual)
        settings = ManualSettings(exposureBias: 0.7)
        #expect(!settings.isAutomatic && !settings.exposureIsManual)
    }

    @Test func valuesAreWrittenLikeOnACamera() {
        #expect(ManualText.shutter(1.0 / 125) == "1/125")
        #expect(ManualText.shutter(1.0 / 8000) == "1/8000")
        #expect(ManualText.shutter(0.5) == "0.5\"" && ManualText.shutter(2) == "2\"")
        #expect(ManualText.iso(400.2) == "ISO 400")
        #expect(ManualText.kelvin(5530) == "5550 K")
        #expect(ManualText.bias(0.66) == "+0.7" && ManualText.bias(-1.33) == "−1.3" && ManualText.bias(0.01) == "0")
    }
}
