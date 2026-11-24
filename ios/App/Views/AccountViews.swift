import CoreImage.CIFilterBuiltins
import HaldenKit
import SwiftUI

/// Loads something from the server for a screen, with a message instead when it can't.
struct Loaded<Value: Sendable, Content: View>: View {
    @Environment(AppModel.self) private var app
    let load: @MainActor (APIClient) async throws -> Value
    @ViewBuilder let content: (Value, @escaping () -> Void) -> Content
    @State private var value: Value?
    @State private var problem: String?
    @State private var round = 0

    var body: some View {
        Group {
            if let value {
                content(value) { round += 1 }
            } else if let problem {
                ContentUnavailableView("Not available", systemImage: "wifi.exclamationmark", description: Text(problem))
            } else {
                ProgressView()
            }
        }
        .task(id: round) {
            do {
                value = try await load(try app.api())
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
        .refreshable { round += 1 }
    }
}

/// Asks for the account's password again before a change that needs it.
struct PasswordQuestion: ViewModifier {
    @Binding var asking: Bool
    let reason: String
    let then: (String) -> Void
    @State private var password = ""

    func body(content: Content) -> some View {
        content.alert("Your password", isPresented: $asking) {
            SecureField("Password", text: $password).accessibilityIdentifier("confirm-password")
            Button("Cancel", role: .cancel) { password = "" }
            Button("Continue") {
                then(password)
                password = ""
            }
            .accessibilityIdentifier("confirm-password-continue")
        } message: {
            Text(reason)
        }
    }
}

extension View {
    func askingForPassword(_ asking: Binding<Bool>, because reason: String, then: @escaping (String) -> Void)
        -> some View
    {
        modifier(PasswordQuestion(asking: asking, reason: reason, then: then))
    }
}

/// The devices signed in to the account (owners: to every account): confirm new ones, block or
/// sign out.
struct DevicesView: View {
    @Environment(AppModel.self) private var app
    @State private var problem: String?

    var body: some View {
        Loaded(load: { try await $0.devices() }) { devices, reload in
            List {
                if let problem { Text(problem).foregroundStyle(.red) }
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(device.name).font(.headline)
                            if device.current == true { Text("this iPhone").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text([device.username, device.platform].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !device.confirmed {
                            Label("New: was this you?", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                            HStack {
                                Button("That was me") {
                                    change {
                                        try await $0.confirmDevice(device.id)
                                    } then: {
                                        reload()
                                    }
                                }
                                .buttonStyle(.bordered)
                                Button("Block", role: .destructive) {
                                    change {
                                        try await $0.blockDevice(device.id)
                                    } then: {
                                        reload()
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .swipeActions {
                        if device.current != true {
                            Button("Sign out", role: .destructive) {
                                change {
                                    try await $0.removeDevice(device.id)
                                } then: {
                                    reload()
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("device-\(device.name)")
                }
            }
        }
        .navigationTitle("Devices")
    }

    private func change(_ action: @escaping @MainActor (APIClient) async throws -> Void, then: @escaping () -> Void) {
        Task {
            do {
                try await action(try app.api())
                problem = nil
                then()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Who signed in where, and what changed: newest first.
struct SecurityLogView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [SecurityEntry] = []
    @State private var next: Int64?
    @State private var problem: String?

    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.red) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.event.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                    Text(TakenAt.text(entry.at, offset: nil)).font(.caption)
                    Text([entry.username, entry.deviceName, entry.ip].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let detail = entry.detail { Text(detail).font(.caption) }
                }
            }
            if next != nil {
                Button("More") { Task { await load() } }
            }
        }
        .navigationTitle("Security log")
        .task { if entries.isEmpty { await load() } }
    }

    private func load() async {
        do {
            let page = try await app.api().securityLog(before: next, limit: 50)
            entries += page.entries
            next = page.entries.isEmpty ? nil : page.nextBefore
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct PasswordView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var again = ""
    @State private var signOutOthers = false
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                SecureField("Current password", text: $current)
                SecureField("New password (at least 8 characters)", text: $new)
                SecureField("New password again", text: $again)
                Toggle("Sign out all other devices", isOn: $signOutOthers)
            }
            if let problem { Section { Text(problem).foregroundStyle(.red) } }
            Section {
                Button("Change password") {
                    working = true
                    Task {
                        defer { working = false }
                        do {
                            _ = try await app.api().changePassword(
                                current: current.isEmpty ? nil : current, new: new, signOutOtherDevices: signOutOthers)
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .disabled(new.count < 8 || new != again || working)
            }
        }
        .navigationTitle("Password")
    }
}

/// A code and QR code for adding another device to this account.
struct PairDeviceView: View {
    var body: some View {
        Loaded(load: { try await $0.pairingCode() }) { code, reload in
            VStack(spacing: 20) {
                if let image = QRCode.image(code.url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .accessibilityLabel("QR code for pairing")
                        .accessibilityIdentifier("pairing-qr")
                }
                Text(code.code)
                    .font(.system(.title, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pairing-code")
                Text(
                    "Scan it with Halden on the other device. Valid until \(TakenAt.text(code.expiresAt, offset: nil))."
                )
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                Button("New code", action: reload)
            }
            .padding()
        }
        .navigationTitle("Add a device")
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// An extra copy of every photo or video in a format of choice, made by the server.
struct FormatsView: View {
    @Environment(AppModel.self) private var app
    @State private var settings: AccountSettings?
    @State private var note: String?

    var body: some View {
        Form {
            if let settings {
                Section {
                    Picker("Photos", selection: binding(\.photoFormat, settings)) {
                        Text("Only the original").tag("original")
                        Text("JPEG").tag("jpeg")
                        Text("HEIC").tag("heic")
                        Text("PNG").tag("png")
                        Text("TIFF").tag("tiff")
                    }
                    Picker("Videos", selection: binding(\.videoFormat, settings)) {
                        Text("Only the original").tag("original")
                        Text("MP4").tag("mp4")
                        Text("MOV").tag("mov")
                        Text("MKV").tag("mkv")
                    }
                } footer: {
                    Text(
                        "The server keeps a copy in this format next to every original, in the library folder. Videos only change their container; nothing of their quality is lost."
                    )
                }
                if let note { Section { Text(note).font(.footnote) } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Formats")
        .task { settings = try? await app.api().accountSettings() }
    }

    private func binding(_ keyPath: WritableKeyPath<AccountSettings, String>, _ current: AccountSettings) -> Binding<
        String
    > {
        Binding(
            get: { settings?[keyPath: keyPath] ?? current[keyPath: keyPath] },
            set: { value in
                var changed = settings ?? current
                changed[keyPath: keyPath] = value
                settings = changed
                Task {
                    do {
                        let saved = try await app.api().setAccountSettings(
                            AccountSettings(photoFormat: changed.photoFormat, videoFormat: changed.videoFormat))
                        note =
                            (saved.queuedConversions ?? 0) > 0
                            ? "\(saved.queuedConversions ?? 0) copies are being made in the background." : nil
                    } catch {
                        note = error.localizedDescription
                    }
                }
            })
    }
}
