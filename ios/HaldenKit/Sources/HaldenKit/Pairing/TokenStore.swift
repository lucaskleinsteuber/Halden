import Foundation
import Security

/// Where the device token lives. On the phone: the Keychain, only on this device.
public protocol TokenStore: Sendable {
    func token(for serverId: String) -> String?
    func save(_ token: String, for serverId: String) throws
    func remove(for serverId: String)
}

public struct KeychainTokenStore: TokenStore {
    let service: String

    public init(service: String = "com.lucas.halden.token") {
        self.service = service
    }

    private func query(_ serverId: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId,
        ]
        #if os(iOS)
            query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func token(for serverId: String) -> String? {
        var query = query(serverId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String, for serverId: String) throws {
        remove(for: serverId)
        var item = query(serverId)
        item[kSecValueData as String] = Data(token.utf8)
        // Readable after the first unlock (background uploads), never in backups or on other devices.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw APIError.unexpected("the Keychain refused the token (\(status))")
        }
    }

    public func remove(for serverId: String) {
        SecItemDelete(query(serverId) as CFDictionary)
    }
}

/// For tests and previews.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    public init() {}

    public func token(for serverId: String) -> String? {
        lock.withLock { tokens[serverId] }
    }

    public func save(_ token: String, for serverId: String) throws {
        lock.withLock { tokens[serverId] = token }
    }

    public func remove(for serverId: String) {
        _ = lock.withLock { tokens.removeValue(forKey: serverId) }
    }
}
