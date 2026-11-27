import Foundation

/// What Halden knows about an iPhone model from its identifier (`utsname.machine`, such as
/// "iPhone15,4" for the iPhone 15): its name, chip and camera hardware.
///
/// AVFoundation's runtime checks always have the last word (`DeviceCapabilities`). The profile
/// adds what those checks can't tell well or only late (USB-C recording, Action mode, which lenses
/// a camera has before the camera ever ran), can veto a runtime check that is too optimistic, and
/// names the iPhone in Settings. Models Halden doesn't know yet simply use the runtime checks.
public struct DeviceProfile: Sendable, Equatable, Codable {
    public var identifier: String
    public var name: String
    public var chip: String
    public var hasUltraWide: Bool
    /// Optical tele zoom (2, 2.5, 3, 4 or 5), `nil` without a tele camera.
    public var tele: Double?
    /// The main camera takes 48 MP photos (and 24 MP by default).
    public var has48MP: Bool
    public var proRAW: Bool
    public var proRes: Bool
    public var appleLog: Bool
    public var macro: Bool
    public var actionMode: Bool
    public var cinematic: Bool
    public var spatialVideo: Bool
    public var cameraControl: Bool
    /// Records video straight to a USB-C drive (Pro models with USB 3).
    public var externalRecording: Bool
    /// Front and back camera at once (`AVCaptureMultiCamSession`).
    public var multiCam: Bool
    /// 1 = older (A14/A15), 2 = A16–A18, 3 = Pro chips from A17 Pro on: how much live work the
    /// camera may do (preview effects, Live Text).
    public var performanceTier: Int

    public init(
        identifier: String, name: String, chip: String, hasUltraWide: Bool = true, tele: Double? = nil,
        has48MP: Bool = false, proRAW: Bool = false, proRes: Bool = false, appleLog: Bool = false,
        macro: Bool = false, actionMode: Bool = false, cinematic: Bool = false, spatialVideo: Bool = false,
        cameraControl: Bool = false, externalRecording: Bool = false, multiCam: Bool = true,
        performanceTier: Int = 2
    ) {
        self.identifier = identifier
        self.name = name
        self.chip = chip
        self.hasUltraWide = hasUltraWide
        self.tele = tele
        self.has48MP = has48MP
        self.proRAW = proRAW
        self.proRes = proRes
        self.appleLog = appleLog
        self.macro = macro
        self.actionMode = actionMode
        self.cinematic = cinematic
        self.spatialVideo = spatialVideo
        self.cameraControl = cameraControl
        self.externalRecording = externalRecording
        self.multiCam = multiCam
        self.performanceTier = performanceTier
    }

    /// "iPhone 15 · A16".
    public var title: String { "\(name) · \(chip)" }

    /// This iPhone's model identifier ("iPhone15,4"); in the simulator the simulated model's.
    public static var currentIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The profile for a model identifier, or `nil` for a model Halden doesn't know.
    public static func named(_ identifier: String) -> DeviceProfile? {
        known.first { $0.identifier == identifier }
    }

    /// Every iPhone Halden knows, from the iPhone 12 on.
    public static let known: [DeviceProfile] = [
        // iPhone 12 (A14)
        DeviceProfile(identifier: "iPhone13,1", name: "iPhone 12 mini", chip: "A14", performanceTier: 1),
        DeviceProfile(identifier: "iPhone13,2", name: "iPhone 12", chip: "A14", performanceTier: 1),
        DeviceProfile(
            identifier: "iPhone13,3", name: "iPhone 12 Pro", chip: "A14", tele: 2, proRAW: true, performanceTier: 1),
        DeviceProfile(
            identifier: "iPhone13,4", name: "iPhone 12 Pro Max", chip: "A14", tele: 2.5, proRAW: true,
            performanceTier: 1),
        // iPhone 13 (A15)
        DeviceProfile(
            identifier: "iPhone14,4", name: "iPhone 13 mini", chip: "A15", cinematic: true, performanceTier: 1),
        DeviceProfile(identifier: "iPhone14,5", name: "iPhone 13", chip: "A15", cinematic: true, performanceTier: 1),
        DeviceProfile(
            identifier: "iPhone14,2", name: "iPhone 13 Pro", chip: "A15", tele: 3, proRAW: true, proRes: true,
            macro: true, cinematic: true, performanceTier: 1),
        DeviceProfile(
            identifier: "iPhone14,3", name: "iPhone 13 Pro Max", chip: "A15", tele: 3, proRAW: true, proRes: true,
            macro: true, cinematic: true, performanceTier: 1),
        DeviceProfile(
            identifier: "iPhone14,6", name: "iPhone SE (3rd generation)", chip: "A15", hasUltraWide: false,
            multiCam: false, performanceTier: 1),
        // iPhone 14
        DeviceProfile(
            identifier: "iPhone14,7", name: "iPhone 14", chip: "A15", actionMode: true, cinematic: true,
            performanceTier: 1),
        DeviceProfile(
            identifier: "iPhone14,8", name: "iPhone 14 Plus", chip: "A15", actionMode: true, cinematic: true,
            performanceTier: 1),
        DeviceProfile(
            identifier: "iPhone15,2", name: "iPhone 14 Pro", chip: "A16", tele: 3, has48MP: true, proRAW: true,
            proRes: true, macro: true, actionMode: true, cinematic: true),
        DeviceProfile(
            identifier: "iPhone15,3", name: "iPhone 14 Pro Max", chip: "A16", tele: 3, has48MP: true, proRAW: true,
            proRes: true, macro: true, actionMode: true, cinematic: true),
        // iPhone 15
        DeviceProfile(
            identifier: "iPhone15,4", name: "iPhone 15", chip: "A16", has48MP: true, actionMode: true,
            cinematic: true),
        DeviceProfile(
            identifier: "iPhone15,5", name: "iPhone 15 Plus", chip: "A16", has48MP: true, actionMode: true,
            cinematic: true),
        DeviceProfile(
            identifier: "iPhone16,1", name: "iPhone 15 Pro", chip: "A17 Pro", tele: 3, has48MP: true, proRAW: true,
            proRes: true, appleLog: true, macro: true, actionMode: true, cinematic: true, spatialVideo: true,
            externalRecording: true, performanceTier: 3),
        DeviceProfile(
            identifier: "iPhone16,2", name: "iPhone 15 Pro Max", chip: "A17 Pro", tele: 5, has48MP: true,
            proRAW: true, proRes: true, appleLog: true, macro: true, actionMode: true, cinematic: true,
            spatialVideo: true, externalRecording: true, performanceTier: 3),
        // iPhone 16
        DeviceProfile(
            identifier: "iPhone17,3", name: "iPhone 16", chip: "A18", has48MP: true, macro: true, actionMode: true,
            cinematic: true, spatialVideo: true, cameraControl: true),
        DeviceProfile(
            identifier: "iPhone17,4", name: "iPhone 16 Plus", chip: "A18", has48MP: true, macro: true,
            actionMode: true, cinematic: true, spatialVideo: true, cameraControl: true),
        DeviceProfile(
            identifier: "iPhone17,1", name: "iPhone 16 Pro", chip: "A18 Pro", tele: 5, has48MP: true, proRAW: true,
            proRes: true, appleLog: true, macro: true, actionMode: true, cinematic: true, spatialVideo: true,
            cameraControl: true, externalRecording: true, performanceTier: 3),
        DeviceProfile(
            identifier: "iPhone17,2", name: "iPhone 16 Pro Max", chip: "A18 Pro", tele: 5, has48MP: true,
            proRAW: true, proRes: true, appleLog: true, macro: true, actionMode: true, cinematic: true,
            spatialVideo: true, cameraControl: true, externalRecording: true, performanceTier: 3),
        DeviceProfile(
            identifier: "iPhone17,5", name: "iPhone 16e", chip: "A18", hasUltraWide: false, has48MP: true,
            actionMode: true, multiCam: false),
        // iPhone 17
        DeviceProfile(
            identifier: "iPhone18,3", name: "iPhone 17", chip: "A19", has48MP: true, macro: true, actionMode: true,
            cinematic: true, spatialVideo: true, cameraControl: true),
        DeviceProfile(
            identifier: "iPhone18,4", name: "iPhone Air", chip: "A19 Pro", hasUltraWide: false, has48MP: true,
            actionMode: true, cinematic: true, cameraControl: true, multiCam: false, performanceTier: 3),
        DeviceProfile(
            identifier: "iPhone18,1", name: "iPhone 17 Pro", chip: "A19 Pro", tele: 4, has48MP: true, proRAW: true,
            proRes: true, appleLog: true, macro: true, actionMode: true, cinematic: true, spatialVideo: true,
            cameraControl: true, externalRecording: true, performanceTier: 3),
        DeviceProfile(
            identifier: "iPhone18,2", name: "iPhone 17 Pro Max", chip: "A19 Pro", tele: 4, has48MP: true,
            proRAW: true, proRes: true, appleLog: true, macro: true, actionMode: true, cinematic: true,
            spatialVideo: true, cameraControl: true, externalRecording: true, performanceTier: 3),
    ]

    /// What the camera may offer: a feature only when the runtime check finds it **and** the
    /// profile (when the model is known) doesn't rule it out.
    public static func effective(runtime: DeviceCapabilities, profile: DeviceProfile?) -> DeviceCapabilities {
        guard let profile else { return runtime }
        var merged = runtime
        merged.canProRAW = runtime.canProRAW && profile.proRAW
        merged.canProRes = runtime.canProRes && profile.proRes
        merged.canAppleLog = runtime.canAppleLog && profile.appleLog
        merged.canExternalStorage = runtime.canExternalStorage && profile.externalRecording
        merged.canSpatialVideo = runtime.canSpatialVideo && profile.spatialVideo
        merged.canMacroControl = runtime.canMacroControl && profile.macro
        merged.canCameraControl = runtime.canCameraControl && profile.cameraControl
        merged.canSpatialAudio = runtime.canSpatialAudio && profile.spatialVideo
        merged.canAudioMix = runtime.canAudioMix && profile.spatialVideo
        merged.canActionMode = runtime.canActionMode && profile.actionMode
        merged.canCinematic = runtime.canCinematic && profile.cinematic
        return merged
    }

    /// What a known model can do, as the simulator's stand-in camera pretends
    /// (`-ui-testing-device iPhone15,4`).
    public var capabilities: DeviceCapabilities {
        DeviceCapabilities(
            canProRAW: proRAW, canProRes: proRes, canAppleLog: appleLog, canExternalStorage: externalRecording,
            canSpatialVideo: spatialVideo, canMacroControl: macro, canCameraControl: cameraControl,
            canSpatialAudio: spatialVideo, canAudioMix: spatialVideo, canActionMode: actionMode,
            canCinematic: cinematic, canDepth: true, canBayerRAW: true, canWindNoiseRemoval: false)
    }

    /// The zoom buttons this model shows on the back camera.
    public var backZoomPresets: [Double] {
        var presets: [Double] = []
        if hasUltraWide { presets.append(0.5) }
        presets.append(1)
        if let tele, tele > 2.05 {
            if has48MP { presets.append(2) }
            presets.append(tele)
        } else if has48MP || tele != nil {
            presets.append(2)
        }
        return presets
    }

    /// One line per thing the camera can do, for Settings › Camera › This iPhone.
    public var featureList: [String] {
        var lines: [String] = []
        let lenses = backZoomPresets.map { Zoom.text($0) + "×" }.joined(separator: " · ")
        lines.append("Lenses: \(lenses)")
        lines.append(has48MP ? "Photos up to 48 MP" : "Photos up to 12 MP")
        if proRAW { lines.append("Apple ProRAW") }
        if proRes { lines.append(appleLog ? "Apple ProRes and Log video" : "Apple ProRes video") }
        if cinematic { lines.append("Cinematic video") }
        if actionMode { lines.append("Action mode") }
        if macro { lines.append("Macro") }
        if spatialVideo { lines.append("Spatial video and audio") }
        if cameraControl { lines.append("Camera Control button") }
        if externalRecording { lines.append("Records straight to a USB-C drive") }
        if multiCam { lines.append("Front and back camera at once") }
        return lines
    }
}

/// The capabilities found the last time the back camera ran, so Settings shows what this iPhone
/// can do before the camera opens (and while the front camera is in use).
public struct CapabilityCache: Sendable {
    let key: String
    let suite: String?

    public init(key: String = "cameraCapabilities", suite: String? = nil) {
        self.key = key
        self.suite = suite
    }

    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> DeviceCapabilities? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeviceCapabilities.self, from: data)
    }

    public func save(_ capabilities: DeviceCapabilities) {
        if let data = try? JSONEncoder().encode(capabilities) { defaults.set(data, forKey: key) }
    }
}
