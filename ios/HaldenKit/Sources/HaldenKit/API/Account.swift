import Foundation

/// Any JSON value (server settings can be numbers, text, switches or lists).
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let flag = try? value.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let text = try? value.decode(String.self) {
            self = .string(text)
        } else if let list = try? value.decode([JSONValue].self) {
            self = .array(list)
        } else {
            self = .object(try value.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 {
                try value.encode(Int64(number))
            } else {
                try value.encode(number)
            }
        case .bool(let flag): try value.encode(flag)
        case .array(let list): try value.encode(list)
        case .object(let object): try value.encode(object)
        case .null: try value.encodeNil()
        }
    }

    /// As text for a form field.
    public var text: String {
        switch self {
        case .string(let text): text
        case .number(let number): number == number.rounded() ? String(Int64(number)) : String(number)
        case .bool(let flag): flag ? "on" : "off"
        case .array(let list): list.map(\.text).joined(separator: ", ")
        case .object: "…"
        case .null: ""
        }
    }
}

/// A signed-in device, as `GET /devices` lists it.
public struct DeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var userId: String
    public var username: String?
    public var name: String
    public var platform: String
    public var confirmed: Bool
    /// The device asking.
    public var current: Bool?
    public var lastSeenAt: Int64?
    public var createdAt: Int64?
}

public struct SecurityEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var at: Int64
    public var event: String
    public var username: String?
    public var deviceName: String?
    public var ip: String?
    public var detail: String?
}

public struct PairingCode: Codable, Sendable, Equatable {
    public var code: String
    public var url: String
    public var expiresAt: Int64
    public var userId: String?
}

/// The account's preferred formats (`/me/settings`): an extra copy of every photo or video.
public struct AccountSettings: Codable, Sendable, Equatable {
    /// `original` (no copy), `jpeg`, `heic`, `png`, `tiff`.
    public var photoFormat: String
    /// `original`, `mp4`, `mov`, `mkv`.
    public var videoFormat: String
    public var queuedConversions: Int?

    public init(photoFormat: String, videoFormat: String) {
        self.photoFormat = photoFormat
        self.videoFormat = videoFormat
    }
}

extension APIClient {
    /// A call whose answer has no body (`204`).
    func perform(_ method: String, _ path: String) async throws {
        _ = try await send(request(method, path))
    }

    /// A call with a JSON body whose answer has none (`204`).
    func perform(_ method: String, _ path: String, json body: some Encodable) async throws {
        var request = request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request, body: try JSONEncoder().encode(body))
    }

    // MARK: Devices and the security log

    public func devices() async throws -> [DeviceInfo] {
        struct Page: Decodable { var devices: [DeviceInfo] }
        let page: Page = try await get("devices")
        return page.devices
    }

    /// "That was me".
    public func confirmDevice(_ id: String) async throws {
        try await perform("POST", "devices/\(id)/confirm")
    }

    /// Signs the device out and refuses it from now on.
    public func blockDevice(_ id: String) async throws {
        try await perform("POST", "devices/\(id)/block")
    }

    /// Signs the device out; it may sign in again.
    public func removeDevice(_ id: String) async throws {
        try await perform("DELETE", "devices/\(id)")
    }

    public func securityLog(before: Int64? = nil, limit: Int = 50) async throws -> (
        entries: [SecurityEntry], nextBefore: Int64?
    ) {
        struct Page: Decodable {
            var entries: [SecurityEntry]
            var nextBefore: Int64?
        }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        let page: Page = try await get("security-log", query: query)
        return (page.entries, page.nextBefore)
    }

    // MARK: The own account

    /// Returns how many other devices were signed out.
    public func changePassword(current: String?, new: String, signOutOtherDevices: Bool) async throws -> Int {
        struct Body: Encodable {
            var currentPassword: String?
            var newPassword: String
            var signOutOtherDevices: Bool
        }
        struct Answer: Decodable { var signedOutDevices: Int }
        let answer: Answer = try await call(
            "PUT", "me/password",
            json: Body(currentPassword: current, newPassword: new, signOutOtherDevices: signOutOtherDevices))
        return answer.signedOutDevices
    }

    /// A code for adding a device: to the own account, or (owners, with their password) another.
    public func pairingCode(for userId: String? = nil, currentPassword: String? = nil) async throws -> PairingCode {
        struct Body: Encodable {
            var userId: String?
            var currentPassword: String?
        }
        return try await call("POST", "pairing-codes", json: Body(userId: userId, currentPassword: currentPassword))
    }

    public func accountSettings() async throws -> AccountSettings {
        try await get("me/settings")
    }

    public func setAccountSettings(_ settings: AccountSettings) async throws -> AccountSettings {
        try await call("PUT", "me/settings", json: settings)
    }
}
