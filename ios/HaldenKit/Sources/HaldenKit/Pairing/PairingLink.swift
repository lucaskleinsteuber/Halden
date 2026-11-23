import Foundation

/// The link in the pairing QR code that `halden pair` shows:
/// `halden://pair?v=1&id=<serverId>&name=<name>&addr=192.168.178.72,100.101.102.103&port=47130&fp=<fingerprint>&code=<code>`
public struct PairingLink: Sendable, Equatable {
    public var serverId: String
    public var serverName: String
    /// Addresses to try, IPv4 first.
    public var addresses: [String]
    public var port: Int
    /// The certificate fingerprint to pin.
    public var fingerprint: String
    public var code: String

    public init?(_ text: String) {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme == "halden", components.host == "pair"
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value
        }
        guard values["v"] == "1",
            let id = values["id"], UUID(uuidString: id) != nil,
            let addresses = values["addr"]?.split(separator: ",").map(String.init), !addresses.isEmpty,
            let port = values["port"].flatMap(Int.init), (1...65_535).contains(port),
            let fingerprint = values["fp"], Fingerprint.isValid(fingerprint),
            let code = values["code"], !code.isEmpty
        else { return nil }
        self.serverId = id.lowercased()
        self.serverName = values["name"] ?? "Halden"
        self.addresses = Array(addresses.prefix(8))
        self.port = port
        self.fingerprint = fingerprint.lowercased()
        self.code = code
    }
}
