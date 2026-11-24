import HaldenKit
import SwiftUI

/// Connecting to a Halden server: scan the QR code from `halden pair`, or sign in with
/// username and password.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var pastedLink = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Connect this iPhone to your Halden server.")
                    Button("Scan the QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                        .accessibilityIdentifier("scan")
                } footer: {
                    Text("On the server, run: sudo halden pair")
                }
                Section("Or paste the link") {
                    TextField("halden://pair?…", text: $pastedLink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect") {
                        guard let link = PairingLink(pastedLink) else { return }
                        Task { await model.pair(with: link) }
                    }
                    .disabled(PairingLink(pastedLink) == nil || model.busy)
                }
                Section {
                    NavigationLink("Sign in with a password") { LoginView() }
                        .accessibilityIdentifier("password-login")
                }
                if model.busy {
                    Section { ProgressView("Connecting…") }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Halden")
            .sheet(isPresented: $scanning) {
                QRScannerView { text in
                    scanning = false
                    if let link = PairingLink(text) {
                        Task { await model.pair(with: link) }
                    }
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// Address, then the server's fingerprint to compare with `halden status`, then username and
/// password. Nothing secret is sent before the person confirmed the fingerprint.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var port = "47130"
    @State private var server: ServerInfo?
    @State private var confirmed = false
    @State private var username = ""
    @State private var password = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Server") {
                TextField("Address, e.g. 192.168.1.20", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("address")
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("port")
                Button("Look up") {
                    Task {
                        problem = nil
                        do {
                            server = try await model.inspect(address: address, port: Int(port) ?? 47130)
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .disabled(address.isEmpty)
                .accessibilityIdentifier("look-up")
            }
            if let server {
                Section {
                    LabeledContent("Name", value: server.name)
                    Text(Fingerprint.display(server.fingerprint))
                        .font(.system(.footnote, design: .monospaced))
                    Toggle("It is the same as on the server", isOn: $confirmed)
                        .accessibilityIdentifier("fingerprint-confirmed")
                } header: {
                    Text("Fingerprint")
                } footer: {
                    Text("Compare it with what `halden status` shows on the server.")
                }
            }
            if let server, confirmed {
                Section("Account") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("username")
                    SecureField("Password", text: $password)
                        .accessibilityIdentifier("password")
                    Button("Sign in") {
                        Task {
                            await model.login(
                                address: address, port: Int(port) ?? 47130,
                                fingerprint: server.fingerprint, username: username, password: password)
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || model.busy || !server.passwordLogin)
                    .accessibilityIdentifier("sign-in")
                    if !server.passwordLogin {
                        Text("This server only allows pairing with a QR code.")
                    }
                }
            }
            if let problem = problem ?? model.problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Sign in")
    }
}
