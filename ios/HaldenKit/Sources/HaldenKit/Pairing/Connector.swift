import Foundation

/// A server this device belongs to: how to reach it and how to recognise it.
public struct ServerConnection: Codable, Sendable, Equatable {
    public var serverId: String
    public var name: String
    public var addresses: [String]
    public var port: Int
    public var fingerprint: String
    public var userId: String
    public var username: String
    public var deviceId: String

    public init(
        serverId: String, name: String, addresses: [String], port: Int, fingerprint: String,
        userId: String, username: String, deviceId: String
    ) {
        self.serverId = serverId
        self.name = name
        self.addresses = addresses
        self.port = port
        self.fingerprint = fingerprint
        self.userId = userId
        self.username = username
        self.deviceId = deviceId
    }
}

/// Finds which address of a server answers, and signs this device in.
public enum Connector {
    /// Tries every address at once; the first that answers as the expected server (same ID, same
    /// certificate) wins. `nil` if none does within `timeout`.
    public static func reach(
        addresses: [String], port: Int, fingerprint: String, serverId: String?,
        timeout: TimeInterval = 4
    ) async -> (APIClient, ServerInfo)? {
        await withTaskGroup(of: (APIClient, ServerInfo)?.self) { group in
            for address in addresses {
                guard let base = APIClient.base(address: address, port: port) else { continue }
                group.addTask {
                    let client = APIClient(base: base, trust: .pinned(fingerprint), timeout: timeout)
                    guard let info = try? await client.serverInfo(),
                        info.fingerprint.lowercased() == fingerprint.lowercased(),
                        serverId == nil || info.serverId.lowercased() == serverId?.lowercased()
                    else { return nil }
                    return (client, info)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// Pairs with the code from a QR code. Returns the connection and the device token.
    public static func pair(
        link: PairingLink, device: DeviceDescription
    ) async throws -> (ServerConnection, String) {
        guard
            let (client, info) = await reach(
                addresses: link.addresses, port: link.port, fingerprint: link.fingerprint,
                serverId: link.serverId)
        else {
            throw APIError.unreachable("none of the addresses in the code answered")
        }
        let signed = try await client.pair(code: link.code, device: device)
        return (
            connection(info: info, client: client, addresses: link.addresses, port: link.port, signed: signed),
            signed.token
        )
    }

    /// Looks at a server before signing in with a password: the person compares the fingerprint
    /// with the one `halden status` shows on the server.
    public static func inspect(address: String, port: Int) async throws -> ServerInfo {
        guard let base = APIClient.base(address: address, port: port) else {
            throw APIError.unexpected("not an address: \(address)")
        }
        let client = APIClient(base: base, trust: .inspect, timeout: 6)
        let info = try await client.serverInfo()
        // The certificate presented must be the one the server says it has.
        guard client.presentedFingerprint == info.fingerprint.lowercased() else {
            throw APIError.unexpected("the server's certificate doesn't match its fingerprint")
        }
        return info
    }

    /// Signs in with username and password, trusting only the fingerprint the person confirmed.
    public static func login(
        address: String, port: Int, fingerprint: String, username: String, password: String,
        device: DeviceDescription
    ) async throws -> (ServerConnection, String) {
        guard let base = APIClient.base(address: address, port: port) else {
            throw APIError.unexpected("not an address: \(address)")
        }
        let client = APIClient(base: base, trust: .pinned(fingerprint))
        let info = try await client.serverInfo()
        let signed = try await client.login(username: username, password: password, device: device)
        return (connection(info: info, client: client, addresses: [address], port: port, signed: signed), signed.token)
    }

    private static func connection(
        info: ServerInfo, client: APIClient, addresses: [String], port: Int, signed: SignedIn
    ) -> ServerConnection {
        ServerConnection(
            serverId: info.serverId.lowercased(), name: info.name, addresses: addresses, port: port,
            fingerprint: info.fingerprint.lowercased(), userId: signed.user.id,
            username: signed.user.username, deviceId: signed.device.id)
    }
}
