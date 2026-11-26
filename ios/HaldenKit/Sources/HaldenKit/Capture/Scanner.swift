import Foundation

/// A QR code detected in the camera viewfinder, parsed into an actionable payload.
public struct ScannedQRCode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case url(URL)
        case wifi(ssid: String, password: String?, security: String, hidden: Bool)
        case contact(name: String, phone: String?, email: String?, raw: String)
        case haldenPairing(String)
        case text(String)
    }

    public var raw: String
    public var kind: Kind

    public init(raw: String, kind: Kind) {
        self.raw = raw
        self.kind = kind
    }

    /// Short title displayed on the yellow floating pill in the camera viewfinder.
    public var pillTitle: String {
        switch kind {
        case .url(let url):
            return url.host() ?? url.absoluteString
        case .wifi(let ssid, _, _, _):
            return "Join \"\(ssid)\""
        case .contact(let name, _, _, _):
            return name.isEmpty ? "Contact" : name
        case .haldenPairing:
            return "Halden Server"
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 26 ? String(trimmed.prefix(25)) + "…" : trimmed
        }
    }

    public var symbol: String {
        switch kind {
        case .url: "safari"
        case .wifi: "wifi"
        case .contact: "person.crop.circle"
        case .haldenPairing: "server.rack"
        case .text: "qrcode"
        }
    }

    public var accessibilityLabel: String {
        switch kind {
        case .url(let url): "Open link \(url.host() ?? url.absoluteString)"
        case .wifi(let ssid, _, _, _): "Join Wi-Fi network \(ssid)"
        case .contact(let name, _, _, _): "View contact \(name)"
        case .haldenPairing: "Halden pairing link"
        case .text: "View QR text"
        }
    }
}

/// Parses QR code strings safely (rejecting dangerous URL schemes such as `javascript:` or `file:`).
public enum QRPayloadParser {
    private static let allowedURLSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    public static func parse(_ raw: String) -> ScannedQRCode? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096 else { return nil }

        if trimmed.lowercased().hasPrefix("halden://") {
            return ScannedQRCode(raw: trimmed, kind: .haldenPairing(trimmed))
        }
        if trimmed.uppercased().hasPrefix("WIFI:") {
            if let wifi = parseWiFi(trimmed) {
                return ScannedQRCode(raw: trimmed, kind: wifi)
            }
        }
        if trimmed.uppercased().hasPrefix("BEGIN:VCARD") {
            return ScannedQRCode(raw: trimmed, kind: parseVCard(trimmed))
        }
        if trimmed.uppercased().hasPrefix("MECARD:") {
            return ScannedQRCode(raw: trimmed, kind: parseMeCard(trimmed))
        }
        if let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            allowedURLSchemes.contains(scheme)
        {
            if scheme == "http" || scheme == "https" {
                guard let host = url.host(), !host.isEmpty else {
                    return ScannedQRCode(raw: trimmed, kind: .text(trimmed))
                }
            }
            return ScannedQRCode(raw: trimmed, kind: .url(url))
        }
        return ScannedQRCode(raw: trimmed, kind: .text(trimmed))
    }

    /// Parses `WIFI:T:WPA;S:My\;Net;P:pass\:word;H:false;;`.
    private static func parseWiFi(_ raw: String) -> ScannedQRCode.Kind? {
        let body = String(raw.dropFirst(5))
        var fields: [String: String] = [:]
        var current = ""
        var escaped = false
        var parts: [String] = []
        for ch in body {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == ";" {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        for part in parts where !part.isEmpty {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = String(part[..<colon]).uppercased()
            let value = String(part[part.index(after: colon)...])
            fields[key] = value
        }
        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        let security = (fields["T"] ?? "WPA").uppercased()
        let password = fields["P"].flatMap { $0.isEmpty ? nil : $0 }
        let hidden = fields["H"]?.lowercased() == "true"
        return .wifi(ssid: ssid, password: password, security: security, hidden: hidden)
    }

    private static func parseVCard(_ raw: String) -> ScannedQRCode.Kind {
        var name = ""
        var phone: String?
        var email: String?
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).uppercased()
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "FN" || key.hasPrefix("FN;") {
                name = value
            } else if name.isEmpty && (key == "N" || key.hasPrefix("N;")) {
                let comps = value.split(separator: ";").map(String.init).filter { !$0.isEmpty }
                name = comps.reversed().joined(separator: " ")
            } else if phone == nil && (key == "TEL" || key.hasPrefix("TEL;")) && !value.isEmpty {
                phone = value
            } else if email == nil && (key == "EMAIL" || key.hasPrefix("EMAIL;")) && !value.isEmpty {
                email = value
            }
        }
        return .contact(name: name, phone: phone, email: email, raw: raw)
    }

    private static func parseMeCard(_ raw: String) -> ScannedQRCode.Kind {
        let body = String(raw.dropFirst(7))
        var name = ""
        var phone: String?
        var email: String?
        for part in body.split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = String(part[..<colon]).uppercased()
            let value = String(part[part.index(after: colon)...])
            switch key {
            case "N":
                name = value.split(separator: ",").reversed().joined(separator: " ")
            case "TEL":
                phone = value
            case "EMAIL":
                email = value
            default:
                break
            }
        }
        return .contact(name: name, phone: phone, email: email, raw: raw)
    }
}

/// Stabilizes viewfinder QR/text detection so overlays don't flicker when the hand moves slightly.
public struct ScannerHoldState: Equatable, Sendable {
    public private(set) var code: ScannedQRCode?
    public private(set) var lastSeenAt: TimeInterval = 0
    public let holdSeconds: TimeInterval

    public init(holdSeconds: TimeInterval = 1.5) {
        self.holdSeconds = holdSeconds
    }

    /// Updates state from the latest frame (`raw == nil` means no QR seen in this frame).
    public mutating func update(raw: String?, now: TimeInterval) -> ScannedQRCode? {
        if let raw, let parsed = QRPayloadParser.parse(raw) {
            code = parsed
            lastSeenAt = now
            return parsed
        }
        if code != nil, now - lastSeenAt >= holdSeconds {
            code = nil
        }
        return code
    }

    public mutating func clear() {
        code = nil
        lastSeenAt = 0
    }
}
