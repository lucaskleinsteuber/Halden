import Foundation
import GRDB
import HaldenKit
import Observation
import UIKit

/// Everything the screens show and do. Lives as long as the app.
@MainActor
@Observable
final class AppModel {
    /// The server this phone belongs to; `nil` before pairing.
    private(set) var connection: ServerConnection?
    /// Newest first, without trash.
    private(set) var library: [LocalAsset] = []
    /// Uploads not finished yet, by asset id: how much of the file the server has (0…1).
    private(set) var uploads: [String: Double] = [:]
    private(set) var backup: BackupState?
    private(set) var reachable = false
    private(set) var problem: String?
    private(set) var busy = false

    let database: HaldenDatabase
    let files: FileLocations
    let tokens: any TokenStore
    private var client: APIClient?
    private var observation: AnyDatabaseCancellable?
    private var uploadObservation: AnyDatabaseCancellable?
    private var working: Task<Void, Never>?

    /// The installation's own id: lets an owner block exactly this app installation.
    static var installationId: String {
        if let id = UserDefaults.standard.string(forKey: "installationId") { return id }
        let id = "ios-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "installationId")
        return id
    }

    var device: DeviceDescription {
        DeviceDescription(name: UIDevice.current.name, platform: "ios", installationId: Self.installationId)
    }

    init(database: HaldenDatabase, files: FileLocations, tokens: any TokenStore) {
        self.database = database
        self.files = files
        self.tokens = tokens
        observe()
        restore()
    }

    /// The app's real database, files and Keychain; for UI tests (`-ui-testing`) an empty
    /// in-memory world, and with `-ui-testing-signed-in` one that looks paired.
    static func make() -> AppModel {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") || arguments.contains("-ui-testing-signed-in") {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = AppModel(
                database: try! HaldenDatabase(),
                files: try! FileLocations(root: temporary, caches: temporary.appendingPathComponent("caches")),
                tokens: MemoryTokenStore())
            if arguments.contains("-ui-testing-signed-in") {
                model.connection = ServerConnection(
                    serverId: "00000000-0000-0000-0000-000000000000", name: "Test server",
                    addresses: ["192.0.2.1"], port: 47130, fingerprint: String(repeating: "0", count: 64),
                    userId: "u", username: "test", deviceId: "d")
            }
            return model
        }
        do {
            let files = try FileLocations.standard()
            let path = files.originals.deletingLastPathComponent().appendingPathComponent("halden.sqlite").path
            return AppModel(database: try HaldenDatabase(path: path), files: files, tokens: KeychainTokenStore())
        } catch {
            fatalError("Halden can't open its own database: \(error)")
        }
    }

    private func observe() {
        observation =
            ValueObservation
            .tracking { db in
                try LocalAsset
                    .filter(sql: "trashedAt IS NULL AND deletedAt IS NULL")
                    .order(sql: "takenAt DESC, id")
                    .fetchAll(db)
            }
            .start(in: database.writer, scheduling: .async(onQueue: .main)) { _ in
            } onChange: { [weak self] assets in
                MainActor.assumeIsolated { self?.library = assets }
            }
        uploadObservation =
            ValueObservation
            .tracking { db in try UploadItem.filter(sql: "state <> 'done'").fetchAll(db) }
            .start(in: database.writer, scheduling: .async(onQueue: .main)) { _ in
            } onChange: { [weak self] items in
                MainActor.assumeIsolated {
                    self?.uploads = Dictionary(
                        uniqueKeysWithValues: items.map {
                            ($0.assetId, $0.size > 0 ? Double($0.sent) / Double($0.size) : 0)
                        })
                }
            }
    }

    /// The server from the last time, with its token from the Keychain.
    private func restore() {
        guard let stored = try? database.server(), let token = tokens.token(for: stored.serverId) else { return }
        connection = stored.connection
        backup = stored.backup
        connect(stored.connection, token: token)
    }

    private func connect(_ connection: ServerConnection, token: String) {
        guard let address = connection.addresses.first,
            let base = APIClient.base(address: address, port: connection.port)
        else { return }
        client = APIClient(base: base, trust: .pinned(connection.fingerprint), token: token)
        work()
        // Home network or Tailscale: whichever address answers right now.
        Task { [weak self] in
            if let (found, _) = await Connector.reach(
                addresses: connection.addresses, port: connection.port,
                fingerprint: connection.fingerprint, serverId: connection.serverId)
            {
                self?.client = found.signedIn(with: token)
                self?.refresh()
            }
        }
    }

    // MARK: Pairing and signing in

    func pair(with link: PairingLink) async {
        await signIn { [device] in try await Connector.pair(link: link, device: device) }
    }

    /// Looks at a server before signing in with a password (the person compares the fingerprint).
    func inspect(address: String, port: Int) async throws -> ServerInfo {
        try await Connector.inspect(address: address, port: port)
    }

    func login(address: String, port: Int, fingerprint: String, username: String, password: String) async {
        await signIn { [device] in
            try await Connector.login(
                address: address, port: port, fingerprint: fingerprint, username: username,
                password: password, device: device)
        }
    }

    private func signIn(_ how: @escaping @Sendable () async throws -> (ServerConnection, String)) async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            let (connection, token) = try await how()
            try tokens.save(token, for: connection.serverId)
            try database.save(
                server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
            self.connection = connection
            connect(connection, token: token)
        } catch {
            problem = error.localizedDescription
        }
    }

    func signOut() async {
        guard let connection else { return }
        try? await client?.logout()
        tokens.remove(for: connection.serverId)
        try? database.forgetServer()
        client = nil
        working?.cancel()
        self.connection = nil
        backup = nil
    }

    // MARK: Taking photos

    /// A photo straight from the camera: written to disk first, then into the library and the
    /// upload queue. The shutter never waits for the network.
    func keep(photo data: Data, fileExtension: String, mimeType: String, metadata: UploadMetadata) {
        let id = UUID().uuidString.lowercased()
        let name = "\(id).\(fileExtension)"
        do {
            try data.write(
                to: files.original(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: name, kind: "photo",
                mimeType: mimeType, metadata: metadata)
            work()
        } catch {
            problem = "The photo could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: Working with the server

    /// Uploads what is waiting, then syncs. Again whenever there is something new, and every
    /// half minute while the app is open.
    func work() {
        guard working == nil, let client else { return }
        working = Task { [database, files, weak self] in
            while !Task.isCancelled {
                let uploader = Uploader(database: database, files: files, client: client)
                await uploader.drain()
                var reachable = true
                do {
                    try await Syncer(database: database, client: client).run()
                    let me = try await client.me()
                    self?.backup = me.backup
                } catch let error as APIError {
                    if case .unreachable = error { reachable = false }
                    if error.signedOut {
                        await self?.signOut()
                        return
                    }
                } catch {}
                self?.reachable = reachable
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Pull to refresh, and when the app comes to the front.
    func refresh() {
        working?.cancel()
        working = nil
        work()
    }

    /// Thumbnails for these photos, from the cache, the local file or the server.
    func thumbnails(for assets: [LocalAsset]) async -> [String: URL] {
        await ThumbnailLoader(files: files, client: client).load(assets)
    }
}
