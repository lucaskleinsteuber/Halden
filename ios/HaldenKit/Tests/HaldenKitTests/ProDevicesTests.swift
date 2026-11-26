import Foundation
import Testing

@testable import HaldenKit

struct ProDevicesTests {
    @Test func capabilityGatingDegradesGracefullyOnBasicDevices() {
        #expect(!ProDeviceRules.effectiveProRAW(enabled: true, capabilities: .basic))
        #expect(ProDeviceRules.effectiveProRAW(enabled: true, capabilities: .all))

        #expect(ProVideoFormat.available(for: .basic) == [.standard])
        #expect(ProVideoFormat.available(for: .all) == [.standard, .proRes, .proResLog])

        #expect(ProDeviceRules.effectiveVideoFormat(wanted: .proResLog, capabilities: .basic) == .standard)
        let proResOnly = DeviceCapabilities(canProRes: true, canAppleLog: false)
        #expect(ProDeviceRules.effectiveVideoFormat(wanted: .proResLog, capabilities: proResOnly) == .proRes)
        #expect(ProDeviceRules.effectiveVideoFormat(wanted: .proResLog, capabilities: .all) == .proResLog)

        #expect(ProDeviceRules.effectiveAudioChannel(wanted: .spatial, capabilities: .basic) == .stereo)
        #expect(ProDeviceRules.effectiveAudioChannel(wanted: .spatial, capabilities: .all) == .spatial)
        #expect(ProDeviceRules.effectiveAudioChannel(wanted: .mono, capabilities: .basic) == .mono)
    }

    @Test func externalStorageRoutingChecksFreeSpaceAndFormat() {
        let ssd = ExternalStorageInfo(displayName: "Samsung T7", freeBytes: 256 * 1024 * 1024 * 1024)
        let tiny = ExternalStorageInfo(displayName: "Tiny Stick", freeBytes: 1024 * 1024)

        #expect(!ProDeviceRules.shouldRecordToExternalStorage(enabled: true, storage: nil, format: .standard))
        #expect(!ProDeviceRules.shouldRecordToExternalStorage(enabled: true, storage: tiny, format: .proRes))
        #expect(!ProDeviceRules.shouldRecordToExternalStorage(enabled: false, storage: ssd, format: .standard))
        #expect(ProDeviceRules.shouldRecordToExternalStorage(enabled: true, storage: ssd, format: .standard))
        #expect(ProDeviceRules.shouldRecordToExternalStorage(enabled: false, storage: ssd, format: .proResLog))
        #expect(ssd.badgeLabel == "USB-C")
    }

    @Test func audioMixEditRecipeFitsAndRoundTrips() throws {
        var recipe = EditRecipe()
        recipe.audioMix = .studio
        recipe.audioMixIntensity = 1.4
        let fitted = recipe.fitted
        #expect(fitted.audioMix == .studio)
        #expect(fitted.audioMixIntensity == 1.0)
        #expect(!fitted.isEmpty)

        let data = try JSONEncoder().encode(fitted)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == fitted)

        var reset = fitted
        reset.audioMix = .standard
        #expect(reset.fitted.audioMix == nil)
        #expect(reset.fitted.audioMixIntensity == nil)
        #expect(reset.fitted.isEmpty)
    }

    @Test func preserveMacroAndProRAWResetWhenUnpreserved() {
        var settings = AppSettings()
        settings.captureProRAW = true
        settings.macroMode = .on
        settings.preserveResolution = false
        settings.preserveMacro = false

        let reset = CameraControls.resetUnpreserved(in: settings)
        #expect(!reset.captureProRAW)
        #expect(reset.macroMode == .auto)

        settings.preserveResolution = true
        settings.preserveMacro = true
        let kept = CameraControls.resetUnpreserved(in: settings)
        #expect(kept.captureProRAW)
        #expect(kept.macroMode == .on)
    }
}
