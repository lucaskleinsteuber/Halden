import Foundation

/// Everything an owner sees about the server (`GET /admin/status`).
public struct ServerStatus: Codable, Sendable, Equatable {
    public struct Disk: Codable, Sendable, Equatable {
        public var path: String
        public var freeBytes: Int64
        public var totalBytes: Int64
    }

    public struct AccountNumbers: Codable, Sendable, Equatable {
        public var userId: String
        public var username: String
        public var photos: Int
        public var videos: Int
        public var trashed: Int
        public var libraryBytes: Int64
    }

    public struct Jobs: Codable, Sendable, Equatable {
        public var waiting: Int
        public var failed: Int
    }

    public struct Tools: Codable, Sendable, Equatable {
        public var ffmpeg: Bool
        public var libheif: Bool
    }

    public var name: String
    public var serverId: String
    public var version: String
    public var startedAt: Int64
    public var restarts: Int?
    public var memoryBytes: Int64?
    public var libraryDisk: Disk?
    public var dataDisk: Disk?
    public var mirrorDisk: Disk?
    public var accounts: [AccountNumbers]
    public var uploadsInProgress: Int
    public var jobs: Jobs
    public var backup: BackupState
    public var tools: Tools
    public var configProblem: String?
    public var inDocker: Bool
}

/// One server setting (`GET /admin/config`).
public struct ServerSetting: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// `text`, `number`, `bool`, `path`, `optionalPath`, `ip`, `networks`.
    public var kind: String
    /// `owner` (no password), `password` (needs the owner's password), `terminal` (not here).
    public var access: String
    public var about: String?
    public var value: JSONValue?
    public var `default`: JSONValue?

    public var id: String { name }
}

public struct ServerConfig: Codable, Sendable, Equatable {
    public var settings: [ServerSetting]
    public var canChange: Bool
    public var configProblem: String?
    public var restarting: Bool?
}

public struct DatabaseBackup: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var size: Int64
    public var madeAt: Int64
    public var id: String { name }
}

public struct MirrorState: Decodable, Sendable, Equatable {
    public var path: String?
    public var backup: BackupState?

    enum CodingKeys: String, CodingKey { case path }

    public init(from decoder: Decoder) throws {
        path = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .path)
        backup = try? BackupState(from: decoder)
    }
}

public struct ServerJob: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var kind: String
    public var assetId: String?
    public var state: String
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Int64?
}

public struct DoctorReport: Codable, Sendable, Equatable {
    public struct Check: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// `ok`, `warning`, `problem`.
        public var level: String
        public var title: String
        public var detail: String
        public var fix: String?
    }

    public var level: String
    public var checks: [Check]
}

public struct UpdateStatus: Codable, Sendable, Equatable {
    public var running: String
    /// `unknown`, `upToDate`, `available`, `installing`, `installed`, `failed`, `rolledBack`.
    public var state: String
    public var latest: String?
    public var prerelease: Bool?
    public var notesUrl: String?
    public var checkedAt: Int64?
    public var message: String?
    /// With test versions off: a newer test version they would offer.
    public var testVersion: String?
    public var inDocker: Bool
    /// Test versions (pre-releases) are offered too (`update.beta`). Older servers don't say.
    public var beta: Bool?
    public var canInstall: Bool
    public var installHint: String?
}

/// An account as owners see it.
public struct AccountSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var username: String
    public var displayName: String
    public var role: String
    public var disabled: Bool
    public var hasPassword: Bool
    public var devices: Int?
}

extension APIClient {
    public func serverStatus() async throws -> ServerStatus {
        try await get("admin/status")
    }

    public func serverConfig() async throws -> ServerConfig {
        try await get("admin/config")
    }

    /// Changes settings (`null` = back to the default). The server restarts with them.
    public func changeServerConfig(_ changes: [String: JSONValue], currentPassword: String?) async throws
        -> ServerConfig
    {
        struct Body: Encodable {
            var changes: [String: JSONValue]
            var currentPassword: String?
        }
        return try await call("PATCH", "admin/config", json: Body(changes: changes, currentPassword: currentPassword))
    }

    public func databaseBackups() async throws -> [DatabaseBackup] {
        struct Page: Decodable { var backups: [DatabaseBackup] }
        let page: Page = try await get("admin/backups")
        return page.backups
    }

    public func makeDatabaseBackup() async throws -> DatabaseBackup {
        try await call("POST", "admin/backups", json: Empty())
    }

    public func mirror() async throws -> MirrorState {
        try await get("admin/mirror")
    }

    public func setMirror(path: String, currentPassword: String) async throws {
        struct Body: Encodable {
            var path: String
            var currentPassword: String
        }
        try await perform("PUT", "admin/mirror", json: Body(path: path, currentPassword: currentPassword))
    }

    public func stopMirror(currentPassword: String) async throws {
        struct Body: Encodable { var currentPassword: String }
        try await perform("DELETE", "admin/mirror", json: Body(currentPassword: currentPassword))
    }

    public func jobs(failedOnly: Bool = true) async throws -> [ServerJob] {
        struct Page: Decodable { var jobs: [ServerJob] }
        let page: Page = try await get(
            "admin/jobs", query: [URLQueryItem(name: "state", value: failedOnly ? "failed" : "all")])
        return page.jobs
    }

    /// Tries failed jobs again (all with `nil`). Returns how many.
    public func retryJobs(_ ids: [Int64]? = nil) async throws -> Int {
        struct Body: Encodable { var ids: [Int64]? }
        struct Answer: Decodable { var retried: Int }
        let answer: Answer = try await call("POST", "admin/jobs/retry", json: Body(ids: ids))
        return answer.retried
    }

    public func doctor() async throws -> DoctorReport {
        try await get("admin/doctor")
    }

    public func restartServer() async throws {
        try await perform("POST", "admin/restart", json: Empty())
    }

    public func updateStatus() async throws -> UpdateStatus {
        try await get("admin/update")
    }

    public func checkForUpdate() async throws -> UpdateStatus {
        try await call("POST", "admin/update/check", json: Empty())
    }

    public func installUpdate(currentPassword: String) async throws -> UpdateStatus {
        struct Body: Encodable { var currentPassword: String }
        return try await call("POST", "admin/update/install", json: Body(currentPassword: currentPassword))
    }

    public func accounts() async throws -> [AccountSummary] {
        struct Page: Decodable { var users: [AccountSummary] }
        let page: Page = try await get("admin/users")
        return page.users
    }

    public func createAccount(
        username: String, displayName: String?, owner: Bool, password: String?, currentPassword: String
    ) async throws -> AccountSummary {
        struct Body: Encodable {
            var username: String
            var displayName: String?
            var role: String
            var password: String?
            var currentPassword: String
        }
        return try await call(
            "POST", "admin/users",
            json: Body(
                username: username, displayName: displayName, role: owner ? "owner" : "member", password: password,
                currentPassword: currentPassword))
    }

    /// Changes an account; `nil` leaves a field as it is.
    public func changeAccount(
        _ id: String, displayName: String? = nil, owner: Bool? = nil, disabled: Bool? = nil, password: String? = nil,
        signOutDevices: Bool? = nil, currentPassword: String? = nil
    ) async throws -> AccountSummary {
        struct Body: Encodable {
            var displayName: String?
            var role: String?
            var disabled: Bool?
            var password: String?
            var signOutDevices: Bool?
            var currentPassword: String?
        }
        return try await call(
            "PATCH", "admin/users/\(id)",
            json: Body(
                displayName: displayName, role: owner.map { $0 ? "owner" : "member" }, disabled: disabled,
                password: password, signOutDevices: signOutDevices, currentPassword: currentPassword))
    }

    public func deleteAccount(_ id: String, currentPassword: String) async throws {
        struct Body: Encodable { var currentPassword: String }
        try await perform("DELETE", "admin/users/\(id)", json: Body(currentPassword: currentPassword))
    }
}
