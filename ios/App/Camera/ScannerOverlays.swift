import HaldenKit
import NetworkExtension
import SwiftUI
import UIKit

/// Floating yellow QR action pill & Live Text icon shown in the camera viewfinder when detected.
struct ViewfinderScannerBar: View {
    let qr: ScannedQRCode?
    let detectedText: String?
    let onTapQR: (ScannedQRCode) -> Void
    let onTapText: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let qr {
                Button {
                    onTapQR(qr)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: qr.symbol)
                            .font(.caption.weight(.bold))
                        Text(qr.pillTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.yellow, in: .capsule)
                }
                .accessibilityLabel(qr.accessibilityLabel)
                .accessibilityIdentifier("qr-action-pill")
            }
            if let detectedText, !detectedText.isEmpty {
                Button {
                    onTapText(detectedText)
                } label: {
                    Image(systemName: "text.viewfinder")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.65), in: .circle)
                }
                .accessibilityLabel("Show detected text")
                .accessibilityIdentifier("live-text-button")
            }
        }
    }
}

/// Detail sheet for scanned Wi-Fi, contact, or plain-text QR codes.
struct ScannedQRSheet: View {
    let code: ScannedQRCode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            List {
                switch code.kind {
                case .url(let url):
                    Section("Link") {
                        Text(url.absoluteString)
                            .textSelection(.enabled)
                        Button("Open Link", systemImage: "safari") {
                            openURL(url)
                            dismiss()
                        }
                        .accessibilityIdentifier("qr-open-link")
                    }
                case .wifi(let ssid, let password, let security, let hidden):
                    Section("Wi-Fi Network") {
                        LabeledContent("Network", value: ssid)
                        LabeledContent("Security", value: security)
                        if let password {
                            LabeledContent("Password", value: password)
                        }
                        Button("Join Network", systemImage: "wifi") {
                            joinWiFi(ssid: ssid, password: password, security: security, hidden: hidden)
                        }
                        .accessibilityIdentifier("qr-join-wifi")
                        if let password {
                            Button("Copy Password", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = password
                                statusMessage = "Password copied."
                            }
                        }
                    }
                case .contact(let name, let phone, let email, _):
                    Section("Contact") {
                        if !name.isEmpty { LabeledContent("Name", value: name) }
                        if let phone { LabeledContent("Phone", value: phone) }
                        if let email { LabeledContent("Email", value: email) }
                        Button("Copy Contact", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = code.raw
                            statusMessage = "Contact copied."
                        }
                    }
                case .haldenPairing(let link):
                    Section("Halden Server") {
                        Text(link).font(.footnote.monospaced())
                        Button("Copy Pairing Link", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = link
                            statusMessage = "Pairing link copied."
                        }
                    }
                case .text(let text):
                    Section("QR Text") {
                        Text(text).textSelection(.enabled)
                        Button("Copy Text", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = text
                            statusMessage = "Text copied."
                        }
                    }
                }
                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("qr-sheet-done")
                }
            }
        }
    }

    private func joinWiFi(ssid: String, password: String?, security: String, hidden: Bool) {
        let config: NEHotspotConfiguration
        if let password, security != "NOPASS" {
            config = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: security == "WEP")
        } else {
            config = NEHotspotConfiguration(ssid: ssid)
        }
        config.hidden = hidden
        NEHotspotConfigurationManager.shared.apply(config) { error in
            Task { @MainActor in
                if let error {
                    statusMessage = error.localizedDescription
                } else {
                    statusMessage = "Joined \"\(ssid)\"."
                }
            }
        }
    }
}

/// Sheet presenting Live Text recognized in the camera viewfinder for copying or sharing.
struct DetectedTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                        .accessibilityIdentifier("detected-text-content")
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Text", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("copy-detected-text")
                }
                .padding()
            }
            .navigationTitle("Detected Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("detected-text-done")
                }
            }
        }
    }
}
