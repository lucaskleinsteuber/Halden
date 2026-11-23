import HaldenKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false

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
                Section("Uploads") {
                    LabeledContent("Waiting", value: String(app.uploads.count))
                    Button("Upload and sync now") { app.refresh() }
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
