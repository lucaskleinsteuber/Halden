import Foundation
import Testing

@testable import HaldenKit

@Suite(.enabled(if: RealServer.available, "build the server first: cd server && cargo build"))
struct AdminTests {
    func signedIn(_ server: RealServer) async throws -> APIClient {
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "admin", platform: "ios", installationId: "install-e2e-admin"))
        return APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
    }

    /// The own account: devices, a pairing code to show as QR code, the security log, the
    /// preferred formats and the password.
    @Test func theOwnAccount() async throws {
        let server = try RealServer()
        let client = try await signedIn(server)
        let devices = try await client.devices()
        #expect(devices.contains { $0.name == "admin" && $0.current == true })
        let code = try await client.pairingCode()
        let link = try #require(PairingLink(code.url))
        #expect(link.code == code.code.replacingOccurrences(of: "-", with: ""))
        let log = try await client.securityLog(limit: 10)
        #expect(log.entries.contains { $0.event == "login_succeeded" })
        #expect(try await client.accountSettings().photoFormat == "original")
        let changed = try await client.setAccountSettings(AccountSettings(photoFormat: "jpeg", videoFormat: "original"))
        #expect(changed.photoFormat == "jpeg")
        #expect(
            try await client.changePassword(
                current: RealServer.password, new: "a new long password", signOutOtherDevices: true) == 0)
        await #expect(throws: APIError.self) {
            _ = try await client.changePassword(
                current: "wrong one", new: "another long password", signOutOtherDevices: false)
        }
    }

    /// The owner's view of the server: status, settings (changed with the password, the server
    /// restarts), doctor, backups, jobs, updates and accounts.
    @Test func lookingAfterTheServer() async throws {
        let server = try RealServer()
        let client = try await signedIn(server)
        let status = try await client.serverStatus()
        #expect(status.name == "e2e" && status.accounts.contains { $0.username == "lucas" })
        #expect(status.inDocker == false)

        let config = try await client.serverConfig()
        let trashDays = try #require(config.settings.first { $0.name == "library.trash_days" })
        #expect(trashDays.value == .number(30) && trashDays.access == "password")
        await #expect(throws: APIError.self) {
            _ = try await client.changeServerConfig(["library.trash_days": .number(31)], currentPassword: nil)
        }
        let saved = try await client.changeServerConfig(
            ["library.trash_days": .number(31)], currentPassword: RealServer.password)
        #expect(saved.restarting == true)
        // The old server answers until the new one, with the new settings, has taken over.
        var after: JSONValue?
        for _ in 0..<100 {
            after = try? await client.serverConfig().settings.first { $0.name == "library.trash_days" }?.value
            if after == .number(31) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(after == .number(31))

        let doctor = try await client.doctor()
        #expect(!doctor.checks.isEmpty && ["ok", "warning", "problem"].contains(doctor.level))
        let made = try await client.makeDatabaseBackup()
        #expect(try await client.databaseBackups().contains { $0.name == made.name })
        #expect(try await client.jobs().isEmpty)
        #expect(try await client.mirror().path == nil)
        #expect(try await client.updateStatus().running.isEmpty == false)

        let anna = try await client.createAccount(
            username: "anna", displayName: "Anna", owner: false, password: "annas long password",
            currentPassword: RealServer.password)
        #expect(try await client.accounts().contains { $0.username == "anna" })
        let renamed = try await client.changeAccount(anna.id, displayName: "Anna K")
        #expect(renamed.displayName == "Anna K")
        let annasCode = try await client.pairingCode(for: anna.id, currentPassword: RealServer.password)
        #expect(annasCode.userId == anna.id)
        try await client.deleteAccount(anna.id, currentPassword: RealServer.password)
        #expect(try await client.accounts().contains { $0.username == "anna" } == false)
    }

    @Test func jsonValuesGoBothWays() throws {
        let values: [JSONValue] = [
            .number(30), .number(1.5), .bool(true), .string("x"), .array([.string("10.0.0.0/8")]), .null,
        ]
        let data = try JSONEncoder().encode(values)
        #expect(String(decoding: data, as: UTF8.self) == #"[30,1.5,true,"x",["10.0.0.0\/8"],null]"#)
        #expect(try JSONDecoder().decode([JSONValue].self, from: data) == values)
        #expect(JSONValue.number(30).text == "30" && JSONValue.array([.string("a"), .string("b")]).text == "a, b")
    }
}

@Suite struct ServerFinderTests {
    /// What a server announces becomes something to connect to; an announcement without a valid
    /// fingerprint is ignored.
    @Test func announcementsBecomeServers() {
        let fingerprint = String(repeating: "ab", count: 32)
        let found = FoundServer.from(
            text: ["id": "s1", "fp": fingerprint.uppercased(), "name": "aurelia", "api": "1"],
            address: "192.168.178.87", port: 47130)
        #expect(
            found
                == FoundServer(
                    id: "s1", name: "aurelia", fingerprint: fingerprint, address: "192.168.178.87", port: 47130))
        #expect(FoundServer.from(text: ["id": "s1", "fp": "short"], address: "10.0.0.2", port: 1) == nil)
        #expect(FoundServer.from(text: ["fp": fingerprint], address: "10.0.0.2", port: 1) == nil)
    }
}
