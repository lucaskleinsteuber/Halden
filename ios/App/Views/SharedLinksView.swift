import HaldenKit
import SwiftUI

/// Making a link to photos or an album: how long it works, a password if wanted, originals or
/// not. Afterwards the link to send, or why there is none yet.
struct NewLinkView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let assetIds: [String]
    var albumId: String?
    var title: String?
    @State private var days: Int? = 7
    @State private var password = ""
    @State private var originals = false
    @State private var made: SharedLink?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if let made {
                    madeSection(made)
                } else {
                    Section {
                        Picker("Works for", selection: $days) {
                            Text("1 day").tag(Int?.some(1))
                            Text("7 days").tag(Int?.some(7))
                            Text("30 days").tag(Int?.some(30))
                            Text("Always").tag(Int?.none)
                        }
                        .accessibilityIdentifier("link-days")
                        SecureField("Password (optional)", text: $password)
                            .accessibilityIdentifier("link-password")
                        Toggle(isOn: $originals) {
                            Explained("Originals too", "Full size, with where they were taken.")
                        }
                    } footer: {
                        Text(
                            "Anybody with the link sees \(albumId == nil ? "\(assetIds.count == 1 ? "this photo" : "these \(assetIds.count) photos")" : "this album, as it is when opened") as a web page, without the place unless originals are allowed. You can withdraw it any time (Settings › Shared links)."
                        )
                    }
                    if let problem {
                        Section { Text(problem).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(made == nil ? "Share a link" : "Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(made == nil ? "Cancel" : "Done") { dismiss() }
                }
                if made == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Make link") { make() }
                            .disabled(working)
                            .accessibilityIdentifier("make-link")
                    }
                }
            }
        }
    }

    @ViewBuilder private func madeSection(_ link: SharedLink) -> some View {
        if let url = link.url.flatMap(URL.init(string:)) {
            Section {
                Text(url.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("link-url")
                ShareLink(item: url) { Label("Send the link", systemImage: "square.and.arrow.up") }
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
            } footer: {
                Text(link.hasPassword ? "Send the password some other way." : "")
            }
        } else {
            Section {
                Label(
                    "The link is made, but your server can't be reached from the internet yet. Once it can (see SHARING in Halden's documentation: Tailscale Funnel is the easiest way), the link shows up in Settings › Shared links.",
                    systemImage: "network.slash"
                )
                .accessibilityIdentifier("link-not-reachable")
            }
        }
    }

    private func make() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                made = try await app.share(
                    NewLink(
                        title: title, albumId: albumId, assetIds: albumId == nil ? assetIds : [],
                        expiresAt: NewLink.ending(afterDays: days), password: password.isEmpty ? nil : password,
                        allowOriginals: originals))
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The links still open: what they show, until when, how often opened; withdrawn with a swipe.
struct SharedLinksView: View {
    @Environment(AppModel.self) private var app
    @State private var links: SharedLinks?
    @State private var problem: String?

    var body: some View {
        List {
            if let links {
                if !links.reachable {
                    Section {
                        Label(
                            "Your server can't be reached from the internet yet, so nobody can open these links. Set it up with Tailscale Funnel, a Cloudflare Tunnel or Caddy (SHARING in Halden's documentation), then turn on share.enabled and share.public_url.",
                            systemImage: "network.slash"
                        )
                        .font(.footnote)
                    }
                }
                Section {
                    ForEach(links.shares) { link in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(link.title ?? (link.albumId != nil ? "An album" : "\(link.assetIds.count) photos"))
                            Text(describe(link)).font(.caption).foregroundStyle(.secondary)
                            if let url = link.url {
                                Text(url).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        .swipeActions {
                            Button("Withdraw", role: .destructive) { withdraw(link) }
                        }
                        .accessibilityIdentifier("shared-link")
                    }
                } footer: {
                    if links.shares.isEmpty { Text("No open links. Share one from a photo or an album.") }
                }
            } else if let problem {
                Text(problem).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Shared links")
        .task { await load() }
        .refreshable { await load() }
    }

    private func describe(_ link: SharedLink) -> String {
        var parts = [link.views == 1 ? "opened once" : "opened \(link.views) times"]
        if let end = link.expiresAt {
            parts.append(
                "until " + Date(timeIntervalSince1970: Double(end) / 1000).formatted(date: .abbreviated, time: .omitted)
            )
        } else {
            parts.append("no end")
        }
        if link.hasPassword { parts.append("password") }
        if link.allowOriginals { parts.append("originals") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            links = try await app.sharedLinks()
        } catch {
            problem = "The server can't be reached right now."
        }
    }

    private func withdraw(_ link: SharedLink) {
        Task {
            try? await app.withdraw(link.id)
            await load()
        }
    }
}
