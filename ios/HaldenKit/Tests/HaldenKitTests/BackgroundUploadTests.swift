import Foundation
import Testing

@testable import HaldenKit

@Suite(.enabled(if: RealServer.available, "build the server first: cd server && cargo build"))
struct BackgroundUploadTests {
    /// The rest of an upload broken off midway, and a whole one, each go as one request, the way
    /// the system sends them in the background; then the photos are on the server, checked by
    /// their hash, and the copies of the rest are gone.
    @Test func theRestOfEachUploadGoesInOneRequest() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "background", platform: "ios", installationId: "install-e2e-background"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let broken = UUID().uuidString.lowercased()
        let whole = UUID().uuidString.lowercased()
        try noiseJPEG(at: files.original("broken.jpg"), seed: 11)
        try noiseJPEG(at: files.original("whole.jpg"), seed: 12)
        for (id, name) in [(broken, "broken.jpg"), (whole, "whole.jpg")] {
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: name, kind: "photo",
                mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1))
        }
        // The first one got a megabyte far in the foreground.
        let uploader = Uploader(database: database, files: files, client: client)
        let waiting = try #require(try database.upload(broken))
        let started = try #require(try await uploader.ready(waiting))
        let uploadId = try #require(started.uploadId)
        let piece = try Data(contentsOf: files.original("broken.jpg")).prefix(1 << 20)
        _ = try await client.send(upload: uploadId, offset: 0, piece: piece)

        let background = BackgroundUploads(database: database, files: files, configuration: .ephemeral)
        let ended = Counter()
        background.ended = { ended.add() }
        #expect(await background.handOver(client: client, permit: .all, settings: AppSettings()) == 2)
        for _ in 0..<200 where ended.value < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ended.value == 2)
        for id in [broken, whole] {
            let asset = try #require(try database.asset(id))
            #expect(asset.backedUp && asset.originalSha256 != nil, "on the server, checked")
            #expect(try database.upload(id)?.state == "thumbnails", "the thumbnails come from the app")
        }
        let rest = (try? FileManager.default.contentsOfDirectory(atPath: background.restFolder.path)) ?? []
        #expect(rest.isEmpty, "the copy of the rest is removed")

        // Back in the foreground, the thumbnails follow and the uploads are done.
        #expect(await uploader.drain() == 2)
        #expect(try database.pendingUploads().isEmpty)
        let onServer = try await client.sync(since: 0).assets
        #expect(Set(onServer.map { $0.id.lowercased() }) == [broken, whole])
        #expect(onServer.allSatisfy { $0.file("thumbnail") != nil })
    }

    /// A video waiting for Wi-Fi is not handed over on cellular, photos are.
    @Test func videosWaitingForWiFiStayHere() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint, username: "lucas",
            password: RealServer.password,
            device: DeviceDescription(name: "cellular", platform: "ios", installationId: "install-e2e-cellular"))
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        try await SampleMedia.video(at: files.original("v.mov"), seed: 5, seconds: 0.5)
        try Uploader.enqueue(
            database: database, files: files, assetId: UUID().uuidString, fileName: "v.mov", kind: "video",
            mimeType: "video/quicktime", metadata: UploadMetadata(takenAt: 1))
        let background = BackgroundUploads(database: database, files: files, configuration: .ephemeral)
        let cellular = UploadRules.permit(
            on: NetworkSituation(kind: .cellular, expensive: true), atHome: false, settings: AppSettings())
        #expect(await background.handOver(client: client, permit: cellular, settings: AppSettings()) == 0)
        #expect(try database.pendingUploads().first?.uploadId == nil, "not even announced")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
