import HaldenKit
import Photos
import SwiftUI

/// The settings, in pages: at the top what matters most (is the server there, is everything
/// on it), then one page per topic, every setting with a line saying what it does.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    /// "0.1.0 (2)": the version and the build number.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let connection = app.connection {
                    Section {
                        NavigationLink {
                            UploadsView()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connection.name).font(.headline)
                                Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("uploads")
                    }
                }
                if let backup = app.backup, backup.onlyOneCopy {
                    Section {
                        Label(
                            "There is only one copy of your photos, on the server's disk. If it breaks, they are gone. Keep the photos on this iPhone too, or set up a mirror on the server (halden mirror set).",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("only-one-copy")
                    }
                }
                Section {
                    page("Server and account", "server.rack", value: app.connection?.username, id: "server-account") {
                        ServerAccountSettings()
                    }
                    page("Uploads", "arrow.up.circle", value: uploadRule, id: "upload-settings") {
                        UploadSettings()
                    }
                    page("Camera", "camera", value: cameraSummary, id: "camera-settings") { CameraSettings() }
                    page("Place", "location", id: "place-settings") { PlaceSettings() }
                    page("Apple Photos", "photo.on.rectangle", id: "photos-settings") { PhotosSettings() }
                    page(
                        "Storage on this iPhone", "internaldrive",
                        value: app.settings.keepLocalCopies ? "keep copies" : "server only", id: "storage-settings"
                    ) { StorageSettings() }
                    page("Formats", "doc.badge.gearshape", id: "formats") { FormatsView() }
                    page("Shared links", "link", id: "shared-links") { SharedLinksView() }
                    page("Trash", "trash", value: "\(app.trashDays) days", id: "trash-settings") { TrashView() }
                }
                if app.isOwner {
                    Section {
                        page("Look after the server", "wrench.and.screwdriver", id: "admin") { AdminView() }
                    } footer: {
                        Text("Status, settings, backups, accounts and updates. Only owners see this.")
                    }
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                        .accessibilityIdentifier("app-version")
                    NavigationLink {
                        CameraTimingsView()
                    } label: {
                        Label("Camera Timings", systemImage: "stopwatch")
                    }
                    .accessibilityIdentifier("camera-timings")
                }
                if let problem = app.problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func page<Destination: View>(
        _ title: String, _ symbol: String, value: String? = nil, id: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            LabeledContent {
                if let value { Text(value) }
            } label: {
                Label(title, systemImage: symbol)
            }
        }
        .accessibilityIdentifier(id)
    }

    private var statusLine: String {
        let connected = app.reachable ? "Connected" : "Not reachable right now"
        let waiting = app.uploads.count
        if waiting == 0 { return "\(connected) · everything is on the server" }
        return "\(connected) · \(waiting) waiting" + (app.uploadsWaitBecause.map { " · \($0)" } ?? "")
    }

    private var uploadRule: String {
        let settings = app.settings
        if settings.onlyOnHomeNetwork { return "home Wi-Fi" }
        if !settings.uploadOverCellular { return "Wi-Fi" }
        return settings.videosOnlyOnWiFi ? "Wi-Fi, photos also cellular" : "Wi-Fi and cellular"
    }

    private var cameraSummary: String {
        let settings = app.settings
        let size = settings.videoResolution == .uhd4K ? "4K" : "1080p"
        return "\(settings.photoFormat.rawValue.uppercased()) · \(size) \(settings.videoFrameRate)"
    }
}

extension AppModel {
    /// A binding to one setting; changing it saves it.
    func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

/// A setting's name with a line under it saying what it does.
struct Explained: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        Text(title)
        Text(detail)
    }
}

/// The server, the own account and its devices, and signing out.
struct ServerAccountSettings: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            if let connection = app.connection {
                Section("Server") {
                    LabeledContent("Name", value: connection.name)
                    LabeledContent("Addresses", value: connection.addresses.joined(separator: ", "))
                    LabeledContent("Account", value: connection.username)
                    LabeledContent("Connected", value: app.reachable ? "yes" : "not right now")
                    LabeledContent("Fingerprint") {
                        Text(Fingerprint.display(connection.fingerprint))
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
            Section {
                NavigationLink {
                    DevicesView()
                } label: {
                    LabeledContent(
                        "Devices", value: app.unconfirmedDevices > 0 ? "\(app.unconfirmedDevices) new" : "")
                }
                .accessibilityIdentifier("devices")
                NavigationLink("Add a device") { PairDeviceView() }.accessibilityIdentifier("pair-device")
                NavigationLink("Security log") { SecurityLogView() }
                NavigationLink("Password") { PasswordView() }
            } header: {
                Text("Account")
            } footer: {
                Text("Every device has its own key. A device you don't know can be blocked here.")
            }
            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
                    .accessibilityIdentifier("sign-out")
            } footer: {
                Text("Photos on this iPhone stay. Photos only on the server are no longer shown here.")
            }
        }
        .navigationTitle("Server and account")
        .confirmationDialog("Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await app.signOut() } }
        } message: {
            Text("Photos on this iPhone stay. Photos only on the server are no longer shown here.")
        }
    }
}

/// When photos and videos go to the server.
struct UploadSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    UploadsView()
                } label: {
                    LabeledContent("Waiting", value: String(app.uploads.count))
                }
                Button("Upload and sync now") { app.refresh() }
            }
            Section {
                Toggle(isOn: app.setting(\.uploadOverCellular)) {
                    Explained("Over cellular", "Without Wi-Fi, photos go over the mobile network.")
                }
                Toggle(isOn: app.setting(\.videosOnlyOnWiFi)) {
                    Explained("Videos only on Wi-Fi", "Videos are big; they wait for Wi-Fi. Also in Low Data Mode.")
                }
                Toggle(isOn: app.setting(\.makeSmallCopies)) {
                    Explained(
                        "Make small copies of videos",
                        "This iPhone makes the 720p copies to play on the go; off: the server makes them.")
                }
                Picker(selection: app.setting(\.videoCopy)) {
                    Text("Automatic").tag(AppSettings.VideoCopy.automatic)
                    Text("Small copy").tag(AppSettings.VideoCopy.small)
                    Text("Original").tag(AppSettings.VideoCopy.original)
                } label: {
                    Explained(
                        "Videos from the server",
                        "Automatic: the small copy on cellular and away from home, the original at home.")
                }
                .disabled(!app.settings.uploadOverCellular)
                Toggle(isOn: app.setting(\.onlyOnHomeNetwork)) {
                    Explained(
                        "Only at home",
                        "Only when the server answers at its home address, not over Tailscale or the internet.")
                }
            } footer: {
                Text("Halden uploads in the background as far as iOS lets it, and picks up where it stopped.")
            }
        }
        .navigationTitle("Uploads")
    }
}

/// What the camera measured about itself on this iPhone, next to the targets, to compare.
struct CameraTimingsView: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(CameraTimingKind.allCases) { kind in
                    let summary = CameraTimingLog.shared.summary(kind)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(kind.title)
                            Spacer()
                            if let summary {
                                Text("\(Self.ms(summary.median))")
                                    .monospacedDigit()
                                    .foregroundStyle(summary.median <= kind.targetMilliseconds ? .green : .orange)
                            } else {
                                Text("–").foregroundStyle(.secondary)
                            }
                        }
                        Text(Self.detail(summary, target: kind.targetMilliseconds))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("timing-\(kind.rawValue)")
                }
            } footer: {
                Text("The middle value of the last measurements. Green is within the target.")
            }
            .id(refresh)
            Section {
                Button("Clear", role: .destructive) {
                    CameraTimingLog.shared.clear()
                    refresh += 1
                }
            }
        }
        .navigationTitle("Camera Timings")
    }

    static func detail(_ summary: CameraTimingLog.Summary?, target: Double) -> String {
        guard let summary else { return "target \(ms(target))" }
        let times = summary.count == 1 ? "once" : "\(summary.count) times"
        return "last \(ms(summary.last)) · \(times) · target \(ms(target))"
    }

    static func ms(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1f s", value / 1000) : "\(Int(value.rounded())) ms"
    }
}

/// How photos and videos are taken, structured like Apple's Settings › Camera.
struct CameraSettings: View {
    @Environment(AppModel.self) private var app

    /// What this iPhone's back camera can do: from the camera when it runs, else as found the
    /// last time it ran, else from the model's profile.
    private var capabilities: DeviceCapabilities {
        let state = app.camera.backend.state
        if state.ready && state.side == .back { return state.capabilities }
        if let cached = CapabilityCache().load() { return cached }
        if let profile { return profile.capabilities }
        return state.capabilities
    }

    private var profile: DeviceProfile? { ThisIPhone.profile }

    /// The photo resolutions this iPhone has.
    private var resolutions: [PhotoResolution] {
        let state = app.camera.backend.state
        if state.ready && state.side == .back && app.camera.mode == .photo { return state.availableResolutions }
        if let profile { return profile.has48MP ? PhotoResolution.allCases : [.mp12] }
        return PhotoResolution.allCases
    }

    var body: some View {
        Form {
            Section {
                if let profile {
                    DisclosureGroup {
                        ForEach(profile.featureList, id: \.self) { line in
                            Text(line).font(.footnote)
                        }
                    } label: {
                        LabeledContent("This iPhone", value: profile.title)
                    }
                    .accessibilityIdentifier("camera-this-iphone")
                } else {
                    LabeledContent("This iPhone", value: DeviceProfile.currentIdentifier)
                        .accessibilityIdentifier("camera-this-iphone")
                }
            } footer: {
                Text("The camera offers only what this iPhone can do.")
            }

            Section {
                NavigationLink {
                    PreserveCameraSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preserve Settings")
                        Text("Choose which camera modes and adjustments stay when you return.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("camera-preserve-settings")

                NavigationLink {
                    TopBarControlsSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top Bar Controls")
                        Text("Choose which buttons sit along the top of the camera.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("camera-top-bar-settings")
            }

            Section("Formats") {
                Picker(selection: app.setting(\.photoFormat)) {
                    Text("High Efficiency (HEIC)").tag(AppSettings.PhotoFormat.heic)
                    Text("Most Compatible (JPEG)").tag(AppSettings.PhotoFormat.jpeg)
                } label: {
                    Explained("Photo format", "HEIC is half the size at the same quality; JPEG opens everywhere.")
                }
                Picker(selection: app.setting(\.photoResolution)) {
                    ForEach(resolutions) { res in
                        Text(res == .mp48 ? "48 MP (HEIF Max)" : res.label).tag(res)
                    }
                } label: {
                    Explained(
                        "Photo resolution", "Higher resolutions capture more detail on cameras that support them.")
                }
                Picker(selection: app.setting(\.photoAspectRatio)) {
                    ForEach(PhotoAspectRatio.allCases) { ratio in
                        Text(ratio.label).tag(ratio)
                    }
                } label: {
                    Explained(
                        "Aspect ratio",
                        "16:9 and 1:1 are kept non-destructively in Halden; Apple Photos gets the cropped copy.")
                }
                if capabilities.canBayerRAW {
                    Toggle(isOn: app.setting(\.captureRAW)) {
                        Explained(
                            "RAW (Bayer DNG)",
                            "Keep a RAW file alongside the photo: 12 MP, on the 1× lens, without Live Photo.")
                    }
                    .accessibilityIdentifier("settings-raw")
                }
                if capabilities.canProRAW {
                    Toggle(isOn: app.setting(\.captureProRAW)) {
                        Explained(
                            "Apple ProRAW",
                            "Capture 12-bit DNG with Apple computational pipeline up to 48 MP on Pro iPhones.")
                    }
                    .accessibilityIdentifier("settings-proraw")
                }
            }

            Section {
                Picker(selection: app.setting(\.videoResolution)) {
                    Text("4K").tag(AppSettings.VideoResolution.uhd4K)
                    Text("1080p").tag(AppSettings.VideoResolution.hd1080)
                } label: {
                    Explained("Size", "4K is sharper and about three times as big.")
                }
                Picker(selection: app.setting(\.videoFrameRate)) {
                    ForEach(CameraControls.videoFrameRates, id: \.self) { rate in
                        Text(CameraControls.frameRateLabel(rate)).tag(rate)
                    }
                } label: {
                    Explained("Frame rate", "60 fps is smoother in motion; 24 fps is cinematic; 25 fps is PAL.")
                }
                Toggle(isOn: app.setting(\.videoHDR)) {
                    Explained("HDR", "Brighter highlights on HDR screens; looks different elsewhere.")
                }
                if capabilities.hasProVideo {
                    Picker(selection: app.setting(\.proVideoFormat)) {
                        ForEach(ProVideoFormat.available(for: capabilities)) { format in
                            Text(format.title).tag(format)
                        }
                    } label: {
                        Explained(
                            "Pro video format",
                            "Record Apple ProRes or flat Apple Log for professional colour grading.")
                    }
                    .accessibilityIdentifier("settings-pro-video")
                }
                if capabilities.canExternalStorage {
                    Toggle(isOn: app.setting(\.recordToExternalStorage)) {
                        Explained(
                            "Record to external storage",
                            "Write videos directly to a connected USB-C SSD when attached.")
                    }
                    .accessibilityIdentifier("settings-external-storage")
                }
                Toggle(isOn: app.setting(\.autoLowLightFPS)) {
                    Explained(
                        "Auto FPS in low light",
                        "Automatically lowers the frame rate in dark scenes for brighter video.")
                }
                Picker(selection: app.setting(\.slowMotionRate)) {
                    Text("240 fps").tag(240)
                    Text("120 fps").tag(120)
                } label: {
                    Explained("Slow motion", "240 frames a second play eight times slower, 120 four times.")
                }
                Picker(selection: app.setting(\.timeLapseInterval)) {
                    Text("Automatic").tag(0.0)
                    ForEach([0.5, 1, 2, 5, 10], id: \.self) { seconds in
                        Text("every \(CameraMode.intervalText(seconds))").tag(seconds)
                    }
                } label: {
                    Explained("Time-lapse", "Automatic: however long it runs, the video is 20 to 40 seconds.")
                }
                Toggle(isOn: app.setting(\.allowAudioPlayback)) {
                    Explained(
                        "Allow audio playback",
                        "Let music or podcasts keep playing while recording video.")
                }
                let audioModes: [AudioChannelMode] =
                    capabilities.canSpatialAudio ? [.spatial, .stereo, .mono] : [.stereo, .mono]
                Picker(selection: app.setting(\.audioChannelMode)) {
                    ForEach(audioModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Explained(
                        "Record sound",
                        capabilities.canSpatialAudio
                            ? "Spatial Audio enables Audio Mix; Stereo is directional; Mono uses one channel."
                            : "Stereo captures directional sound; Mono uses a single channel.")
                }
                .accessibilityIdentifier("settings-audio-channel")
                if capabilities.canWindNoiseRemoval {
                    Toggle(isOn: app.setting(\.windNoiseRemoval)) {
                        Explained("Wind noise removal", "Reduce wind rumble during stereo video capture.")
                    }
                    .accessibilityIdentifier("settings-wind-noise")
                }
                Toggle(isOn: app.setting(\.allowAirPodsMic)) {
                    Explained("AirPods microphone", "Record video audio through connected AirPods or Bluetooth mic.")
                }
                .accessibilityIdentifier("settings-airpods-mic")
                Toggle(isOn: app.setting(\.showHistogram)) {
                    Explained("Live histogram", "Show RGB and luminance exposure distribution in the viewfinder.")
                }
                .accessibilityIdentifier("settings-show-histogram")
                Toggle(isOn: app.setting(\.showWaveform)) {
                    Explained("Live waveform", "Show horizontal luminance levels across the frame in the viewfinder.")
                }
                .accessibilityIdentifier("settings-show-waveform")
                Toggle(isOn: app.setting(\.lockVideoCamera)) {
                    Explained(
                        "Lock camera",
                        "Prevent automatic switching between lenses while recording video.")
                }
                .accessibilityIdentifier("settings-lock-camera")
                Toggle(isOn: app.setting(\.lockVideoWhiteBalance)) {
                    Explained(
                        "Lock white balance",
                        "Hold colour temperature steady once a video recording starts.")
                }
                .accessibilityIdentifier("settings-lock-wb")
            } header: {
                Text("Record Video")
            } footer: {
                Text("Also in the camera: tap the format at the top or open the control drawer.")
            }

            Section("Shooting") {
                Picker(selection: app.setting(\.defaultFocalLength)) {
                    ForEach(FocalLength.allCases) { focal in
                        Text(focal.label).tag(focal)
                    }
                } label: {
                    Explained("Main camera", "Default focal length on the 1× lens (24, 28 or 35 mm).")
                }
                Toggle(isOn: app.setting(\.prioritizeFasterShooting)) {
                    Explained(
                        "Prioritize faster shooting",
                        "Adapt image quality slightly so rapid shutter presses never wait.")
                }
                Toggle(isOn: app.setting(\.livePhotos)) {
                    Explained(
                        "Live Photos", "With 1.5 seconds of video and sound before and after; also on the camera.")
                }
                if capabilities.canDepth {
                    Toggle(isOn: app.setting(\.autoDepth)) {
                        Explained(
                            "Automatic depth",
                            "Keep depth with photos of people and pets, so they can become portraits later.")
                    }
                    .accessibilityIdentifier("settings-auto-depth")
                }
                Toggle(isOn: app.setting(\.volumeUpForBurst)) {
                    Explained("Volume Up for burst", "Hold Volume Up in photo mode to shoot a burst.")
                }
                Toggle(isOn: app.setting(\.scanQRCodes)) {
                    Explained("Scan QR Codes", "Show a quick action button when a QR code appears in the viewfinder.")
                }
                .accessibilityIdentifier("settings-scan-qr")
                Toggle(isOn: app.setting(\.showLiveText)) {
                    Explained("Show Detected Text", "Offer a Live Text button when text is spotted in the viewfinder.")
                }
                .accessibilityIdentifier("settings-live-text")
                if capabilities.canMacroControl {
                    Toggle(isOn: app.setting(\.macroControl)) {
                        Explained(
                            "Macro Control",
                            "Show a camera toggle to switch to the Ultra Wide lens for close-up photos and videos.")
                    }
                    .accessibilityIdentifier("settings-macro-control")
                }
            }

            Section("Composition") {
                Toggle(isOn: app.setting(\.showGrid)) {
                    Explained("Grid", "Lines in thirds over the picture, to line it up.")
                }
                .accessibilityIdentifier("settings-show-grid")
                Toggle(isOn: app.setting(\.showLevel)) {
                    Explained("Level", "Horizon line and overhead crosshairs when the iPhone is slightly tilted.")
                }
                .accessibilityIdentifier("settings-show-level")
                Toggle(isOn: app.setting(\.mirrorFrontCamera)) {
                    Explained("Mirror front camera", "Save selfies the same way they look in the preview.")
                }
                .accessibilityIdentifier("settings-mirror-front")
                Toggle(isOn: app.setting(\.lensCorrection)) {
                    Explained("Lens correction", "Straighten optical distortion on ultra-wide and front lenses.")
                }
                .accessibilityIdentifier("settings-lens-correction")
                Toggle(isOn: app.setting(\.viewOutsideTheFrame)) {
                    Explained(
                        "View Outside the Frame",
                        "Show the ultra-wide view dimly around the crop frame at 1× or higher.")
                }
                .accessibilityIdentifier("settings-outside-frame")
            }
        }
        .navigationTitle("Camera")
    }
}

/// Which camera modes and adjustments stay when you close and reopen the camera.
struct PreserveCameraSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Toggle(isOn: app.setting(\.preserveMode)) {
                    Explained("Camera mode", "Remember the last mode (such as Video) instead of resetting to Photo.")
                }
                .accessibilityIdentifier("preserve-mode")
                Toggle(isOn: app.setting(\.preserveStyle)) {
                    Explained(
                        "Photographic Style & Filter",
                        "Keep your chosen Photographic Style and filter when you reopen the camera.")
                }
                .accessibilityIdentifier("preserve-style")
                Toggle(isOn: app.setting(\.preservePortraitZoom)) {
                    Explained(
                        "Portrait depth & lighting",
                        "Remember your Portrait f-stop and lighting choice between sessions.")
                }
                .accessibilityIdentifier("preserve-portrait")
                Toggle(isOn: app.setting(\.preserveNightMode)) {
                    Explained(
                        "Night mode",
                        "Keep your Night Mode off or duration choice instead of resetting to Auto.")
                }
                .accessibilityIdentifier("preserve-night")
                Toggle(isOn: app.setting(\.preserveActionMode)) {
                    Explained(
                        "Action mode",
                        "Keep Action Mode stabilization on instead of resetting when the camera closes.")
                }
                .accessibilityIdentifier("preserve-action")
                Toggle(isOn: app.setting(\.preserveExposure)) {
                    Explained("Exposure adjustment", "Keep the EV offset instead of resetting to 0.")
                }
                .accessibilityIdentifier("preserve-exposure")
                Toggle(isOn: app.setting(\.preserveLivePhoto)) {
                    Explained("Live Photo", "Remember whether Live Photo is off instead of turning it back on.")
                }
                .accessibilityIdentifier("preserve-live")
                Toggle(isOn: app.setting(\.preserveResolution)) {
                    Explained("Resolution & RAW", "Keep 48 MP and RAW choices between sessions.")
                }
                .accessibilityIdentifier("preserve-resolution")
                if app.camera.backend.state.capabilities.canMacroControl {
                    Toggle(isOn: app.setting(\.preserveMacro)) {
                        Explained("Macro Control", "Preserve your manual Macro toggle instead of resetting to Auto.")
                    }
                    .accessibilityIdentifier("preserve-macro")
                }
                Toggle(isOn: app.setting(\.keepManualSettings)) {
                    Explained(
                        "Manual values",
                        "Off: ISO, shutter, white balance and focus go back to automatic when the camera closes.")
                }
                .accessibilityIdentifier("preserve-manual")
            } footer: {
                Text("Everything left off returns to its sensible default when the camera closes.")
            }
        }
        .navigationTitle("Preserve Settings")
    }
}

/// Choose up to four controls pinned to the camera's top bar.
struct TopBarControlsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                ForEach(TopBarControl.allCases) { control in
                    let selected = app.settings.topBarControls.contains(control)
                    let atLimit = app.settings.topBarControls.count >= CameraControls.maxTopBarControls && !selected
                    Toggle(
                        isOn: Binding(
                            get: { selected },
                            set: { on in
                                app.update { settings in
                                    var list = CameraControls.sanitizedTopBar(settings.topBarControls)
                                    if on {
                                        if !list.contains(control), list.count < CameraControls.maxTopBarControls {
                                            list.append(control)
                                        }
                                    } else if list.count > 1 {
                                        list.removeAll { $0 == control }
                                    }
                                    settings.topBarControls = list
                                }
                            })
                    ) {
                        Label(control.title, systemImage: control.symbol)
                    }
                    .disabled(atLimit || (selected && app.settings.topBarControls.count <= 1))
                    .accessibilityIdentifier("topbar-\(control.rawValue)")
                }
            } footer: {
                Text(
                    "Up to \(CameraControls.maxTopBarControls) controls sit in the top bar; every control stays reachable in the camera's expandable drawer."
                )
            }
            Section {
                Button("Reset to default") {
                    app.update { $0.topBarControls = CameraControls.defaultTopBarControls }
                }
                .accessibilityIdentifier("topbar-reset")
            }
        }
        .navigationTitle("Top Bar Controls")
    }
}

/// How precisely a place must be known, and what happens otherwise.
struct PlaceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Picker(selection: app.setting(\.locationAccuracyLimit)) {
                    ForEach([10.0, 20, 50, 100, 500], id: \.self) { metres in
                        Text("\(Int(metres)) m").tag(metres)
                    }
                } label: {
                    Explained("Precise means within", "A place known less precisely than this counts as imprecise.")
                }
                Picker(selection: app.setting(\.inaccurateLocation)) {
                    Text("Keep and mark").tag(AppSettings.InaccurateLocation.mark)
                    Text("Leave out").tag(AppSettings.InaccurateLocation.omit)
                } label: {
                    Explained("Imprecise places", "Kept and marked as imprecise, or not saved at all.")
                }
                Picker(selection: app.setting(\.tripKilometres)) {
                    ForEach([25.0, 50, 100, 200], id: \.self) { kilometres in
                        Text("\(Int(kilometres)) km").tag(kilometres)
                    }
                } label: {
                    Explained("Trips", "Days with photos farther from home than this are suggested as trip albums.")
                }
            } footer: {
                Text(
                    "Every photo keeps how precisely its place was known, its height and which way the camera looked. A place older than a minute is never used."
                )
            }
            Section {
                Toggle(isOn: app.setting(\.locateScreenshots)) {
                    Explained(
                        "Give screenshots a place",
                        "Screenshots have no GPS of their own; Halden can estimate where they were taken.")
                }
                .accessibilityIdentifier("locate-screenshots")
                if app.settings.locateScreenshots {
                    Picker(selection: app.setting(\.screenshotPlaceMaxMinutes)) {
                        ForEach([5, 15, 30, 60, 120], id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    } label: {
                        Explained(
                            "Use this iPhone's place up to",
                            "When a screenshot is older than this, Halden uses the nearest photo within two hours.")
                    }
                    .accessibilityIdentifier("screenshot-max-age")
                    Toggle(isOn: app.setting(\.locateScreenRecordings)) {
                        Explained("Screen recordings", "Give screen recordings an estimated place the same way.")
                    }
                    .accessibilityIdentifier("locate-screen-recordings")
                }
            } header: {
                Text("Screenshots")
            } footer: {
                Text(
                    "Stored in Halden only and marked as estimated; Apple Photos is never changed. Uses your current place only while Halden is open."
                )
            }
        }
        .navigationTitle("Place")
    }
}

/// What stays on this iPhone.
struct StorageSettings: View {
    @Environment(AppModel.self) private var app
    @State private var copies: (count: Int, bytes: Int64)?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: app.setting(\.keepLocalCopies)) {
                    Explained("Keep copies on this iPhone", "Off: photos leave this iPhone once the server has them.")
                }
                .accessibilityIdentifier("keep-copies")
                if let copies {
                    LabeledContent(
                        "On this iPhone",
                        value:
                            "\(copies.count) · \(ByteCountFormatter.string(fromByteCount: copies.bytes, countStyle: .file))"
                    )
                }
            } footer: {
                Text(
                    "A photo or video only leaves once the server has confirmed it by its hash and its thumbnail and preview are here. It is fetched from the server when you open it."
                )
            }
        }
        .navigationTitle("Storage")
        .task(id: app.libraryVersion) {
            copies = try? LocalCopies.usage(database: app.database, files: app.files)
        }
    }
}

/// Apple Photos: access, what goes which way, and the import of the photos from before.
struct PhotosSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        Form {
            accessSection
            Section {
                Toggle(isOn: app.setting(\.importFromPhotos)) {
                    Explained("Take over new photos", "From Apple's camera and other apps, and back them up.")
                }
                Toggle(isOn: app.setting(\.saveToPhotos)) {
                    Explained("Save Halden's photos there too", "They stay linked and never come back as new.")
                }
                Toggle(isOn: app.setting(\.syncDeletionsWithPhotos)) {
                    Explained(
                        "Delete in both", "Deleted in Apple Photos: into Halden's trash. Deleted in Halden: iOS asks.")
                }
            }
            Section {
                Button(importTitle) { app.importPhotoLibrary() }
                    .disabled(app.photosImport.running || app.photosImport.done)
                    .accessibilityIdentifier("import-photos")
                if app.photosImport.startedOnce {
                    Text(importStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("photos-import-status")
                }
            } footer: {
                Text("The photos from before Halden, in pieces, also in the background. It goes on where it stopped.")
            }
        }
        .navigationTitle("Apple Photos")
        .onAppear { access = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    }

    private var accessSection: some View {
        Section {
            LabeledContent("Access", value: accessText)
            if access == .notDetermined {
                Button("Allow access…") {
                    Task {
                        _ = await SystemPhotoLibrary.ask(everything: true)
                        access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                        app.refresh()
                    }
                }
            } else if access != .authorized {
                Button("Change in Settings…") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } footer: {
            Text(
                access == .limited
                    ? "Halden may see only the photos you chose. New photos from other apps come in only once you add them to that choice."
                    : "Halden needs all photos to take over new ones; to save its own there, adding is enough."
            )
        }
    }

    private var accessText: String {
        switch access {
        case .authorized: "all photos"
        case .limited: "only some photos"
        case .notDetermined: "not asked yet"
        default: "not allowed"
        }
    }

    private var importTitle: String {
        app.photosImport.startedOnce && !app.photosImport.done
            ? "Go on importing the photos from before" : "Import the photos from before"
    }

    private var importStatus: String {
        let count = app.photosImport.imported
        if app.photosImport.done { return "Everything from before is in Halden (\(count) this time)." }
        return app.photosImport.running
            ? "Importing… \(count) so far" : "\(count) imported; it goes on where it stopped."
    }
}
