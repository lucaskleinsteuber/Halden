import HaldenKit
import Photos
import SwiftUI

/// The settings, in pages: at the top what matters most (is the server there, is everything
/// on it), then one page per topic, every setting with a line saying what it does.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

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
                    LabeledContent(
                        "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
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

/// How photos and videos are taken.
struct CameraSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Photos") {
                Picker(selection: app.setting(\.photoFormat)) {
                    Text("HEIC").tag(AppSettings.PhotoFormat.heic)
                    Text("JPEG").tag(AppSettings.PhotoFormat.jpeg)
                } label: {
                    Explained("Format", "HEIC is half the size at the same quality; JPEG opens everywhere.")
                }
                Toggle(isOn: app.setting(\.livePhotos)) {
                    Explained(
                        "Live Photos", "With 1.5 seconds of video and sound before and after; also on the camera.")
                }
                Toggle(isOn: app.setting(\.showGrid)) {
                    Explained("Grid", "Lines in thirds over the picture, to line it up.")
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
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                } label: {
                    Explained("Frame rate", "60 frames a second are smoother in motion.")
                }
                Toggle(isOn: app.setting(\.videoHDR)) {
                    Explained("HDR", "Brighter highlights on HDR screens; looks different elsewhere.")
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
            } header: {
                Text("Videos")
            } footer: {
                Text("Also on the camera screen: tap the format at the top in video mode.")
            }
        }
        .navigationTitle("Camera")
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
            } footer: {
                Text(
                    "Every photo keeps how precisely its place was known, its height and which way the camera looked. A place older than a minute is never used."
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
