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
    /// Days photos stay in the trash (older servers don't say).
    public var trashDays: Int?
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

public struct AssetCamera: Codable, Sendable, Equatable {
    public var make: String?
    public var model: String?
    public var lens: String?
}

/// A photo or video as the server knows it.
public struct Asset: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var takenAt: Int64
    public var timeZoneOffsetMinutes: Int?
    /// `client`, `exif`, `upload`, or `manual` once corrected.
    public var takenAtSource: String?
    public var width: Int?
    public var height: Int?
    public var durationMs: Int64?
    /// The effective place: a correction if there is one, else the original.
    public var location: AssetLocation?
    public var camera: AssetCamera?
    public var files: [AssetFile]
    public var seq: Int64
    public var trashedAt: Int64?
    public var deletedAt: Int64?
    public var title: String?
    public var description: String?

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

/// One field of a correction: left as it is, set, or removed (`null` on the wire).
public enum Change<Value: Codable & Sendable & Equatable>: Sendable, Equatable {
    case keep
    case set(Value)
    case clear
}

/// A place given by hand or accepted from a suggestion (`estimated`).
public struct CorrectedLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var estimated: Bool

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, estimated: Bool = false) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.estimated = estimated
    }
}

/// `PATCH /assets/{id}`: corrections. The original values stay on the server; `restore` drops
/// corrections of these fields (`takenAt`, `location`, …) and shows the originals again.
public struct AssetCorrection: Codable, Sendable, Equatable {
    public var takenAt: Change<Int64> = .keep
    public var timeZoneOffsetMinutes: Change<Int> = .keep
    public var location: Change<CorrectedLocation> = .keep
    public var title: Change<String> = .keep
    public var description: Change<String> = .keep
    public var restore: [String] = []

    public init(
        takenAt: Change<Int64> = .keep, timeZoneOffsetMinutes: Change<Int> = .keep,
        location: Change<CorrectedLocation> = .keep, title: Change<String> = .keep,
        description: Change<String> = .keep, restore: [String] = []
    ) {
        self.takenAt = takenAt
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.location = location
        self.title = title
        self.description = description
        self.restore = restore
    }

    enum CodingKeys: String, CodingKey {
        case takenAt, timeZoneOffsetMinutes, location, title, description, restore
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func put<V>(_ change: Change<V>, _ key: CodingKeys) throws {
            switch change {
            case .keep: break
            case .set(let value): try container.encode(value, forKey: key)
            case .clear: try container.encodeNil(forKey: key)
            }
        }
        try put(takenAt, .takenAt)
        try put(timeZoneOffsetMinutes, .timeZoneOffsetMinutes)
        try put(location, .location)
        try put(title, .title)
        try put(description, .description)
        if !restore.isEmpty { try container.encode(restore, forKey: .restore) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func get<V>(_ key: CodingKeys) throws -> Change<V> {
            guard container.contains(key) else { return .keep }
            if try container.decodeNil(forKey: key) { return .clear }
            return .set(try container.decode(V.self, forKey: key))
        }
        takenAt = try get(.takenAt)
        timeZoneOffsetMinutes = try get(.timeZoneOffsetMinutes)
        location = try get(.location)
        title = try get(.title)
        description = try get(.description)
        restore = try container.decodeIfPresent([String].self, forKey: .restore) ?? []
    }
}

/// Everything about one asset (`GET /assets/{id}`): the asset as shown, and next to it what it
/// was originally, its EXIF data, and every correction made.
public struct AssetDetail: Decodable, Sendable {
    public var asset: Asset
    /// The values from the upload or the file, before any correction.
    public var original: OriginalValues?
    /// Camera settings read from the file, as text.
    public var exif: [String: String]
    public var edits: [AssetEdit]

    public struct OriginalValues: Codable, Sendable, Equatable {
        public var takenAt: Int64?
        public var timeZoneOffsetMinutes: Int?
        public var takenAtSource: String?
        public var location: AssetLocation?
    }

    public struct AssetEdit: Decodable, Sendable, Equatable {
        public var at: Int64
        public var field: String
        public var deviceId: String?
    }

    enum CodingKeys: String, CodingKey {
        case original, exif, edits
    }

    public init(from decoder: Decoder) throws {
        asset = try Asset(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        original = try container.decodeIfPresent(OriginalValues.self, forKey: .original)
        let raw = (try? container.decodeIfPresent([String: LooseText].self, forKey: .exif)) ?? nil
        exif = (raw ?? [:]).mapValues(\.text)
        edits = (try? container.decodeIfPresent([AssetEdit].self, forKey: .edits)) ?? []
    }
}

/// Any JSON value as text (EXIF values come as strings, numbers or lists).
struct LooseText: Decodable {
    var text: String

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            text = string
        } else if let number = try? value.decode(Int64.self) {
            text = String(number)
        } else if let number = try? value.decode(Double.self) {
            text = String(number)
        } else if let flag = try? value.decode(Bool.self) {
            text = flag ? "yes" : "no"
        } else if let list = try? value.decode([LooseText].self) {
            text = list.map(\.text).joined(separator: ", ")
        } else {
            text = "…"
        }
    }
}

/// A photo without a place, with the place of the nearest photo in time.
public struct PlaceSuggestion: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var fromAssetId: String?
    public var minutesApart: Int?
}

public struct AssetWithoutPlace: Decodable, Sendable {
    public var asset: Asset
    public var suggestion: PlaceSuggestion?

    enum CodingKeys: String, CodingKey { case suggestion }

    public init(from decoder: Decoder) throws {
        asset = try Asset(from: decoder)
        suggestion = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(
            PlaceSuggestion.self, forKey: .suggestion)
    }
}
