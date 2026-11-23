import Foundation

// The server's JSON, as described in docs/PROTOCOL.md. Keys are camelCase on both sides; times
// are Unix milliseconds.

/// `GET /server`: who the server is, before signing in.
public struct ServerInfo: Codable, Sendable, Equatable {
    public var name: String
    public var serverId: String
    public var version: String
    public var apiVersion: Int
    /// SHA-256 of the server's certificate, lowercase hex.
    public var fingerprint: String
    public var passwordLogin: Bool
}

/// How this device introduces itself when signing in or pairing.
public struct DeviceDescription: Codable, Sendable, Equatable {
    public var name: String
    public var platform: String
    public var installationId: String

    public init(name: String, platform: String, installationId: String) {
        self.name = name
        self.platform = platform
        self.installationId = installationId
    }
}

public struct User: Codable, Sendable, Equatable {
    public var id: String
    public var username: String
    public var displayName: String
    public var role: String
    public var disabled: Bool
    public var hasPassword: Bool
}

public struct Device: Codable, Sendable, Equatable {
    public var id: String
    public var userId: String
    public var name: String
    public var platform: String
    public var confirmed: Bool
}

/// The answer of `POST /auth/login` and `POST /auth/pair`.
public struct SignedIn: Codable, Sendable {
    public var token: String
    public var user: User
    public var device: Device
}

/// What the server says about its backups (`GET /me`).
public struct BackupState: Codable, Sendable, Equatable {
    /// `none`, `ok`, `behind` or `unreachable`.
    public var mirror: String
    /// True while there is no working second copy: a broken disk would lose the photos.
    public var onlyOneCopy: Bool
    public var filesWaiting: Int
    public var mirrorOnSameDisk: Bool
    public var lastDatabaseBackupAt: Int64?
}

public struct Me: Codable, Sendable {
    public var user: User
    public var device: Device
    public var unconfirmedDevices: Int
    public var backup: BackupState
}

public struct AssetFile: Codable, Sendable, Equatable {
    /// `original`, `thumbnail`, `preview`, `converted`, …
    public var role: String
    public var sha256: String
    public var size: Int64
    public var mimeType: String
    public var width: Int?
    public var height: Int?
}

public struct AssetLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var accuracyMeters: Double?
    public var heading: Double?
    public var source: String?
}

/// A photo or video as the server knows it.
public struct Asset: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var takenAt: Int64
    public var timeZoneOffsetMinutes: Int?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var location: AssetLocation?
    public var files: [AssetFile]
    public var seq: Int64
    public var trashedAt: Int64?
    public var deletedAt: Int64?
    public var title: String?

    public func file(_ role: String) -> AssetFile? {
        files.first { $0.role == role }
    }
}

/// `GET /sync?since=N`.
public struct SyncPage: Codable, Sendable {
    public var assets: [Asset]
    public var nextSince: Int64
    public var hasMore: Bool
    public var resetRequired: Bool?
}

/// Where and how a photo was taken, as the phone knows it best.
public struct UploadMetadata: Codable, Sendable, Equatable {
    public var takenAt: Int64?
    public var timeZoneOffsetMinutes: Int?
    public var timeZone: String?
    public var location: ClientLocation?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    public var originalFilename: String?

    public init(
        takenAt: Int64? = nil, timeZoneOffsetMinutes: Int? = nil, timeZone: String? = nil,
        location: ClientLocation? = nil, width: Int? = nil, height: Int? = nil,
        durationMs: Int64? = nil, originalFilename: String? = nil
    ) {
        self.takenAt = takenAt
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.timeZone = timeZone
        self.location = location
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.originalFilename = originalFilename
    }
}

public struct ClientLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?
    public var heading: Double?
    public var headingAccuracy: Double?

    public init(
        latitude: Double, longitude: Double, altitude: Double? = nil,
        horizontalAccuracy: Double? = nil, verticalAccuracy: Double? = nil,
        heading: Double? = nil, headingAccuracy: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.heading = heading
        self.headingAccuracy = headingAccuracy
    }
}

/// `POST /uploads`.
public struct UploadRequest: Codable, Sendable {
    public var assetId: String
    public var role: String
    public var size: Int64
    public var sha256: String
    public var mimeType: String
    public var metadata: UploadMetadata?
}

/// Where an upload stands (`POST /uploads`, `PATCH`/`GET /uploads/{id}`).
public struct UploadState: Codable, Sendable {
    /// `receiving`, `completed` or `duplicate`.
    public var state: String
    public var uploadId: String?
    public var offset: Int64?
    public var size: Int64?
    public var asset: Asset?
    public var existingAssetId: String?
}

/// Every error the server sends.
public struct ErrorBody: Codable, Sendable {
    public var error: String
    public var message: String
    public var offset: Int64?
}
