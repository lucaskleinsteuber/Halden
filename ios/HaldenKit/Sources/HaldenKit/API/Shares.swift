import Foundation

/// A shared link: photos or an album as a web page for people without Halden.
public struct SharedLink: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var token: String
    public var title: String?
    public var albumId: String?
    public var assetIds: [String]
    public var expiresAt: Int64?
    public var hasPassword: Bool
    public var allowOriginals: Bool
    public var views: Int
    public var createdAt: Int64
    /// The address to send; `nil` while the server isn't reachable from the internet.
    public var url: String?
}

/// The links still open, and whether they can be opened from the internet.
public struct SharedLinks: Codable, Sendable {
    public var shares: [SharedLink]
    public var reachable: Bool
}

/// What a new link shares and how.
public struct NewLink: Encodable, Sendable {
    public var title: String?
    public var albumId: String?
    public var assetIds: [String]
    /// Unix milliseconds; `nil`: never ends.
    public var expiresAt: Int64?
    public var password: String?
    public var allowOriginals: Bool

    public init(
        title: String? = nil, albumId: String? = nil, assetIds: [String] = [], expiresAt: Int64? = nil,
        password: String? = nil, allowOriginals: Bool = false
    ) {
        self.title = title
        self.albumId = albumId
        self.assetIds = assetIds
        self.expiresAt = expiresAt
        self.password = password
        self.allowOriginals = allowOriginals
    }

    /// A link that ends after `days` (`nil`: never), from `now`.
    public static func ending(afterDays days: Int?, from now: Date = Date()) -> Int64? {
        days.map { Int64((now.timeIntervalSince1970 + Double($0) * 86_400) * 1000) }
    }
}

extension APIClient {
    public func sharedLinks() async throws -> SharedLinks {
        try await get("shares")
    }

    public func share(_ link: NewLink) async throws -> SharedLink {
        try await call("POST", "shares", json: link)
    }

    /// The link ends now.
    public func withdraw(_ id: String) async throws {
        try await perform("DELETE", "shares/\(id)")
    }
}
