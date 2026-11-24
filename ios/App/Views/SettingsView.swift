import HaldenKit
import Photos
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false
    @State private var copies: (count: Int, bytes: Int64)?

    /// A binding to one setting; changing it saves it.
    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { value in app.update { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let connection = app.connection {
                    Section("Server") {
                        LabeledContent("Name", value: connection.name)
                        LabeledContent("Address", value: connection.addresses.joined(separator: ", "))
                        LabeledContent("Account", value: connection.username)
                        LabeledContent("Connected", value: app.reachable ? "yes" : "not right now")
                        LabeledContent("Fingerprint") {
                            Text(Fingerprint.display(connection.fingerprint))
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
                Section("Account") {
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
                    NavigationLink("Formats") { FormatsView() }
                }
                if app.isOwner {
                    Section {
                        NavigationLink("Look after the server") { AdminView() }.accessibilityIdentifier("admin")
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
                    NavigationLink {
                        UploadsView()
                    } label: {
                        LabeledContent("Waiting", value: String(app.uploads.count))
                    }
                    .accessibilityIdentifier("uploads")
                    Toggle("Upload over cellular", isOn: setting(\.uploadOverCellular))
                    Toggle("Videos only on Wi-Fi", isOn: setting(\.videosOnlyOnWiFi))
                        .disabled(!app.settings.uploadOverCellular)
                    Toggle("Only on the home Wi-Fi", isOn: setting(\.onlyOnHomeNetwork))
                    Button("Upload and sync now") { app.refresh() }
                } header: {
                    Text("Uploads")
                } footer: {
                    Text(
                        "Home Wi-Fi: the server answers at its address at home, not over Tailscale. Videos also wait for Wi-Fi in Low Data Mode."
                    )
                }
                Section {
                    Toggle("Keep copies on this iPhone", isOn: setting(\.keepLocalCopies))
                        .accessibilityIdentifier("keep-copies")
                    if let copies {
                        LabeledContent(
                            "On this iPhone",
                            value:
                                "\(copies.count) · \(ByteCountFormatter.string(fromByteCount: copies.bytes, countStyle: .file))"
                        )
                    }
                } header: {
                    Text("Copies")
                } footer: {
                    Text(
                        "When off, a photo or video taken with Halden leaves this iPhone once the server has it, checked by its hash, and its thumbnail and preview are here. It is fetched from the server when you open it."
                    )
                }
                PhotosSettings(setting: setting)
                Section("Camera") {
                    Picker("Photo format", selection: setting(\.photoFormat)) {
                        Text("HEIC").tag(AppSettings.PhotoFormat.heic)
                        Text("JPEG").tag(AppSettings.PhotoFormat.jpeg)
                    }
                    Picker("Video", selection: setting(\.videoResolution)) {
                        Text("4K").tag(AppSettings.VideoResolution.uhd4K)
                        Text("1080p").tag(AppSettings.VideoResolution.hd1080)
                    }
                    Picker("Frame rate", selection: setting(\.videoFrameRate)) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Toggle("HDR video", isOn: setting(\.videoHDR))
                    Toggle("Grid", isOn: setting(\.showGrid))
                }
                Section {
                    Picker("Precise means within", selection: setting(\.locationAccuracyLimit)) {
                        ForEach([10.0, 20, 50, 100, 500], id: \.self) { metres in
                            Text("\(Int(metres)) m").tag(metres)
                        }
                    }
                    Picker("Less precise places", selection: setting(\.inaccurateLocation)) {
                        Text("Keep and mark").tag(AppSettings.InaccurateLocation.mark)
                        Text("Leave out").tag(AppSettings.InaccurateLocation.omit)
                    }
                } header: {
                    Text("Place")
                } footer: {
                    Text(
                        "Every photo keeps how precisely its place was known. A place older than a minute is never used."
                    )
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .accessibilityIdentifier("sign-out")
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
            .task(id: app.libraryVersion) {
                copies = try? LocalCopies.usage(database: app.database, files: app.files)
            }
            .confirmationDialog(
                "Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) { Task { await app.signOut() } }
            } message: {
                Text("Photos on this iPhone stay. Photos only on the server are no longer shown here.")
            }
        }
    }
}

/// Apple Photos: access, what goes which way, and the import of the photos from before.
private struct PhotosSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let setting: (WritableKeyPath<AppSettings, Bool>) -> Binding<Bool>
    @State private var access = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
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
            Toggle("Take over new photos", isOn: setting(\.importFromPhotos))
            Toggle("Save Halden's photos there", isOn: setting(\.saveToPhotos))
            Toggle("Delete in both", isOn: setting(\.syncDeletionsWithPhotos))
            Button(importTitle) { app.importPhotoLibrary() }
                .disabled(app.photosImport.running || app.photosImport.done)
                .accessibilityIdentifier("import-photos")
            if app.photosImport.startedOnce {
                Text(importStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("photos-import-status")
            }
        } header: {
            Text("Apple Photos")
        } footer: {
            Text(
                access == .limited
                    ? "Halden may see only the photos you chose. New photos from other apps come in only once you add them to that choice."
                    : "New photos and videos from Apple's camera and other apps come into Halden and are backed up. Deleted in Apple Photos, they go to Halden's trash, where you can restore them."
            )
        }
        .onAppear { access = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
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
