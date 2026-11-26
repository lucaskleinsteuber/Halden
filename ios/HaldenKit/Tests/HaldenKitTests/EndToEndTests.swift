import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HaldenKit

/// The real Rust server (built from `server/`), started in a temporary folder, and HaldenKit
/// talking to it the way the app does: sign in and pair, an upload cut off and continued,
/// thumbnails made on the phone, sync to a second device, the trash, signing out.
final class RealServer: @unchecked Sendable {
    static let password = "end to end password"
    let folder: URL
    let config: URL
    let port: Int
    let process: Process

    /// `server/target/debug/halden`, or `HALDEN_SERVER`.
    static var binary: URL {
        if let path = ProcessInfo.processInfo.environment["HALDEN_SERVER"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/target/debug/halden")
    }

    static var available: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    @discardableResult
    static func run(_ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
        }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw APIError.unexpected("halden \(arguments.joined(separator: " ")): \(text)")
        }
        return text
    }

    static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length)
            }
        }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("halden-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        config = folder.appendingPathComponent("config.toml")
        port = Self.freePort()
        let base = ["--config", config.path]
        try Self.run(
            base + [
                "setup", "--name", "e2e", "--data-dir", folder.appendingPathComponent("data").path,
                "--library-dir", folder.appendingPathComponent("library").path,
            ])
        for (key, value) in [
            ("server.bind", "127.0.0.1"), ("server.port", String(port)),
            ("network.bonjour", "false"), ("jobs.thumbnail_delay_minutes", "600"),
        ] {
            try Self.run(base + ["config", "set", key, value])
        }
        try Self.run(base + ["user", "add", "lucas", "--owner"], input: Self.password + "\n")
        process = Process()
        // Through a small shell that stops the server when this test run ends in any way, also
        // when it is killed and `deinit` never runs.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments =
            [
                "-c",
                """
                parent=$1; shift
                child=""
                stop_child() {
                    if [ -n "$child" ]; then
                        kill "$child" 2> /dev/null
                        for _ in 1 2 3 4 5 6 7 8 9 10; do
                            kill -0 "$child" 2> /dev/null || exit 0
                            sleep 0.1
                        done
                        kill -9 "$child" 2> /dev/null
                    fi
                    exit 0
                }
                trap stop_child TERM INT HUP
                "$@" & child=$!
                while kill -0 "$parent" 2> /dev/null && kill -0 "$child" 2> /dev/null; do
                    sleep 0.2 &
                    wait $! 2> /dev/null
                done
                stop_child
                """,
                "halden-e2e", String(ProcessInfo.processInfo.processIdentifier), Self.binary.path,
            ] + base + ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Waits until the server answers; returns what it says about itself.
    func ready() async throws -> ServerInfo {
        for _ in 0..<200 {
            if let info = try? await Connector.inspect(address: "127.0.0.1", port: port) {
                return info
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw APIError.unreachable("the server did not start")
    }

    func halden(_ arguments: [String]) throws -> String {
        try Self.run(["--config", config.path] + arguments)
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A real photo: a 2000 × 1500 picture of noise (so it doesn't compress small) as JPEG.
func noiseJPEG(at url: URL, seed: UInt32 = 2_463_534_242) throws {
    let width = 2000
    let height = 1500
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var state: UInt32 = seed
    for index in pixels.indices {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        pixels[index] = UInt8(truncatingIfNeeded: state)
    }
    let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        return context?.makeImage()
    }
    let destination = try #require(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(
        destination, try #require(image), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

let device = DeviceDescription(name: "Test iPhone", platform: "ios", installationId: "install-e2e-test-1")

@Suite(.serialized, .enabled(if: RealServer.available, "build the server first: cd server && cargo build"))
struct EndToEndTests {
    @Test func theWholeChainAgainstTheRealServer() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        #expect(info.name == "e2e")

        // The person compares the fingerprint, then signs in with it pinned.
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
            username: "lucas", password: RealServer.password, device: device)
        #expect(connection.serverId == info.serverId.lowercased())

        // Another certificate than the pinned one: no connection at all.
        let wrong = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!,
            trust: .pinned(String(repeating: "0", count: 64)), token: token)
        await #expect(throws: APIError.self) { _ = try await wrong.me() }

        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!,
            trust: .pinned(connection.fingerprint), token: token)
        let me = try await client.me()
        #expect(me.user.username == "lucas")
        #expect(me.backup.onlyOneCopy)

        // The phone takes a photo: it is in the library at once, then goes up in pieces.
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let id = UUID().uuidString.lowercased()
        try noiseJPEG(at: files.original("\(id).jpg"))
        let taken = Int64(1_795_443_730_000)
        try Uploader.enqueue(
            database: database, files: files, assetId: id, fileName: "\(id).jpg", kind: "photo",
            mimeType: "image/jpeg",
            metadata: UploadMetadata(
                takenAt: taken, timeZoneOffsetMinutes: 60, timeZone: "Europe/Berlin",
                location: ClientLocation(latitude: 50.5558, longitude: 9.6808, horizontalAccuracy: 4.5, heading: 271)))
        #expect(try database.library().map(\.id) == [id])
        #expect(try database.asset(id)?.backedUp == false)

        // Cut off after the first pieces (the app was closed) …
        let uploader = Uploader(database: database, files: files, client: client, pieceSize: 128 << 10)
        let first = Task { await uploader.drain() }
        for _ in 0..<400 {
            if let item = try database.upload(id), item.sent > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        first.cancel()
        _ = await first.value
        let cut = try #require(try database.upload(id))
        #expect(cut.sent > 0 && cut.sent < cut.size, "cut off in the middle: \(cut.sent) of \(cut.size)")
        #expect(cut.uploadId != nil)

        // … and continued where the server stands, by a new uploader (the app started again).
        try await database.writer.write { db in try db.execute(sql: "UPDATE upload SET retryAt = 0") }
        let again = Uploader(database: database, files: files, client: client, pieceSize: 128 << 10)
        #expect(await again.drain() == 1)
        let done = try #require(try database.upload(id))
        #expect(done.state == "done", "\(done.lastError ?? "")")
        let local = try #require(try database.asset(id))
        #expect(local.backedUp)
        #expect(local.thumbnailSha256 != nil)

        // The server has the original byte for byte, plus the phone's thumbnail and preview.
        let page = try await client.sync(since: 0)
        let asset = try #require(page.assets.first { $0.id.lowercased() == id })
        let original = try Data(contentsOf: files.original("\(id).jpg"))
        #expect(asset.file("original")?.sha256 == Hashing.sha256(of: original))
        #expect(asset.file("thumbnail")?.width == 512)
        #expect(asset.file("preview")?.width == 2000, "smaller than 2048: kept at its size")
        #expect(asset.takenAt == taken)
        #expect(asset.location?.latitude == 50.5558)

        // A second device, paired with a code from `halden pair`, sees it after a sync.
        let pairing = try PairingTerminal(server: server)
        let code = try pairing.code()
        let link = try #require(
            PairingLink(
                "halden://pair?v=1&id=\(info.serverId)&name=e2e&addr=10.255.255.1,127.0.0.1&port=\(server.port)&fp=\(info.fingerprint)&code=\(code)"
            ))
        let (paired, pairedToken) = try await Connector.pair(
            link: link,
            device: DeviceDescription(name: "Test Mac", platform: "macos", installationId: "install-e2e-test-2"))
        pairing.finish()
        let other = try HaldenDatabase()
        try other.save(server: StoredServer(serverId: paired.serverId, connection: paired, syncSince: 0, backup: nil))
        let otherClient = client.signedIn(with: pairedToken)
        #expect(try await Syncer(database: other, client: otherClient).run() == 1)
        let synced = try #require(try other.asset(id))
        #expect(synced.backedUp && synced.localFile == nil)

        // Its thumbnail comes from the server in one bulk request, and is the phone's.
        let otherFiles = try FileLocations(
            root: root.appendingPathComponent("other"), caches: root.appendingPathComponent("other-caches"))
        let ready = await ThumbnailLoader(files: otherFiles, client: otherClient).load([synced])
        let thumbnail = try Data(contentsOf: try #require(ready[id]))
        #expect(Hashing.sha256(of: thumbnail) == synced.thumbnailSha256)

        // The trash, seen by the other device.
        #expect(try await client.trash([id]) == 1)
        try await Syncer(database: other, client: otherClient).run()
        #expect(try other.library().isEmpty)

        // Signed out: the token no longer works.
        try await otherClient.logout()
        do {
            _ = try await otherClient.me()
            Issue.record("a signed-out token still works")
        } catch let error as APIError {
            #expect(error.signedOut)
        }
    }

    @Test func aDuplicateIsStoredOnce() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
            username: "lucas", password: RealServer.password, device: device)
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        try noiseJPEG(at: files.original("one.jpg"))
        try FileManager.default.copyItem(at: files.original("one.jpg"), to: files.original("two.jpg"))
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        try Uploader.enqueue(
            database: database, files: files, assetId: first, fileName: "one.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1))
        try Uploader.enqueue(
            database: database, files: files, assetId: second, fileName: "two.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 2))
        #expect(await Uploader(database: database, files: files, client: client).drain() == 2)
        let library = try database.library()
        #expect(library.map(\.id) == [first], "the copy became the photo that was already there")
        #expect(library.first?.backedUp == true)
        #expect(try await client.sync(since: 0).assets.count == 1)
    }

    /// Changes made without a connection reach the server later, in order; one for a photo still
    /// uploading waits for it; one the server refuses for good is dropped and the server's state
    /// comes back.
    @Test func changesMadeOfflineReachTheServerLater() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
            username: "lucas", password: RealServer.password, device: device)
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let nowhere = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: 1)!, trust: .pinned(connection.fingerprint),
            token: token, timeout: 2)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        var ids: [String] = []
        for n in 0..<4 {
            let id = UUID().uuidString.lowercased()
            try noiseJPEG(at: files.original("\(n).jpg"), seed: UInt32(n + 1) &* 2_654_435_761)
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: "\(n).jpg", kind: "photo",
                mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1_795_443_730_000 + Int64(n)))
            ids.append(id)
        }
        let uploader = Uploader(database: database, files: files, client: client)
        let (a, b, c, later) = (ids[0], ids[1], ids[2], ids[3])
        // The first three go up; the fourth stays waiting for now.
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE upload SET retryAt = ? WHERE assetId = ?", arguments: [Int64.max, later])
        }
        #expect(await uploader.drain() == 3)

        let actions = Actions(database: database)
        try actions.trash([a, b, later])
        try actions.restore([b])
        try actions.correct(
            c,
            AssetCorrection(
                location: .set(CorrectedLocation(latitude: 48.137, longitude: 11.575)), title: .set("Munich")))
        try actions.setLocation([b], CorrectedLocation(latitude: 50.5, longitude: 9.6, estimated: true))
        #expect(await actions.send(with: nowhere) == .later)
        #expect(try actions.pending().count == 4)

        // Back home: everything goes, except what waits for the fourth photo's upload.
        #expect(await actions.send(with: client) == .done)
        #expect(try actions.pending().map(\.kind) == ["trash"], "waits for the photo still uploading")
        #expect(try actions.pending().first?.assetIds == [later], "the others of that change went")
        let onServer = Dictionary(
            uniqueKeysWithValues: try await client.sync(since: 0).assets.map { ($0.id.lowercased(), $0) })
        #expect(onServer[a]?.trashedAt != nil)
        #expect(onServer[b]?.trashedAt == nil)
        #expect(onServer[b]?.location?.source == "estimated")
        #expect(onServer[c]?.title == "Munich")
        #expect(onServer[c]?.location?.source == "manual")

        // The fourth photo goes up; then its change follows.
        try await database.writer.write { db in try db.execute(sql: "UPDATE upload SET retryAt = 0") }
        #expect(await uploader.drain() == 1)
        #expect(await actions.send(with: client) == .done)
        #expect(try actions.pending().isEmpty)
        #expect(try await client.asset(later).trashedAt != nil)
        try await Syncer(database: database, client: client).run()
        #expect(try database.trash().map(\.id).sorted() == [a, later].sorted())

        // Deleting for good.
        try actions.deleteForGood([a])
        #expect(await actions.send(with: client) == .done)
        #expect(try await client.asset(a).deletedAt != nil)

        // A correction the server refuses (a date in the year 5000): dropped, and the server's
        // date comes back here.
        let before = try #require(try database.asset(c)).takenAt
        try actions.correct(c, AssetCorrection(takenAt: .set(95_617_584_000_000)))
        #expect(try database.asset(c)?.takenAt == 95_617_584_000_000)
        #expect(await actions.send(with: client) == .done)
        #expect(try actions.pending().isEmpty)
        #expect(try database.asset(c)?.takenAt == before)
    }

    /// A slow-motion video: the server knows it as one, its slow part goes there as a
    /// correction and comes back with the sync, and "as recorded" brings back the standard.
    @Test func slowMotionKeepsItsSlowPartOnTheServer() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
            username: "lucas", password: RealServer.password, device: device)
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let id = UUID().uuidString.lowercased()
        try await SampleMedia.video(at: files.original("slow.mov"), seed: 8, seconds: 2)
        try Uploader.enqueue(
            database: database, files: files, assetId: id, fileName: "slow.mov", kind: "video",
            mimeType: "video/quicktime",
            metadata: UploadMetadata(takenAt: 1_795_443_730_000, durationMs: 2000, captureMode: "slowmo"))
        #expect(try database.asset(id)?.isSlowMotion == true)
        #expect(await Uploader(database: database, files: files, client: client).drain() == 1)
        #expect(try await client.asset(id).captureMode == "slowmo")

        let slow = SlowMotion(slowFromMs: 400, slowToMs: 1600, rate: 0.25)
        let actions = Actions(database: database)
        try actions.correct(id, AssetCorrection(playback: .set(slow)))
        #expect(try database.asset(id)?.playback == slow, "shows at once")
        #expect(await actions.send(with: client) == .done)
        #expect(try await client.asset(id).playback == slow)

        // Another phone gets it with the sync.
        let other = try HaldenDatabase()
        try other.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        try await Syncer(database: other, client: client).run()
        let synced = try #require(try other.asset(id))
        #expect(synced.isSlowMotion && synced.playback == slow)

        try actions.correct(id, AssetCorrection(playback: .clear))
        #expect(await actions.send(with: client) == .done)
        #expect(try await client.asset(id).playback == nil)
        try await Syncer(database: other, client: client).run()
        #expect(try other.asset(id)?.playback == nil)
    }

    /// A video's small copy, made here, goes up after the original as its `stream`; the sync
    /// tells every phone it is there.
    @Test func aSmallCopyReachesTheServer() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
            username: "lucas", password: RealServer.password, device: device)
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let id = UUID().uuidString.lowercased()
        try await SampleMedia.video(at: files.original("v.mov"), seed: 12, seconds: 2)
        try Uploader.enqueue(
            database: database, files: files, assetId: id, fileName: "v.mov", kind: "video",
            mimeType: "video/quicktime", metadata: UploadMetadata(takenAt: 1_795_443_730_000, durationMs: 2000))
        let uploader = Uploader(database: database, files: files, client: client)
        #expect(await uploader.drain() == 1)
        try await Syncer(database: database, client: client).run()
        #expect(try database.videosWithoutSmallCopy(files: files).map(\.id) == [id])

        try await SmallVideos.make(from: files.original("v.mov"), to: files.original("v-small.mp4"), shorterSide: 180)
        try Uploader.enqueueSmallCopy(database: database, files: files, assetId: id, fileName: "v-small.mp4")
        #expect(await uploader.drain() == 1)
        #expect(try await client.asset(id).file("stream")?.mimeType == "video/mp4")
        try await Syncer(database: database, client: client).run()
        #expect(try database.asset(id)?.streamSha256 != nil)
        #expect(try database.videosWithoutSmallCopy(files: files).isEmpty)
    }

    /// An edit reaches the server as what was set and comes to another phone; back to the
    /// original, it is gone everywhere.
    @Test func editsReachTheServerAndOtherPhones() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
            username: "lucas", password: RealServer.password, device: device)
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let id = UUID().uuidString.lowercased()
        try noiseJPEG(at: files.original("e.jpg"), seed: 99)
        try Uploader.enqueue(
            database: database, files: files, assetId: id, fileName: "e.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1_795_443_730_000))
        #expect(await Uploader(database: database, files: files, client: client).drain() == 1)

        var recipe = EditRecipe()
        recipe.exposure = 0.7
        recipe.quarterTurns = 1
        recipe.crop = .init(x: 0.1, y: 0.1, width: 0.6, height: 0.8)
        let actions = Actions(database: database)
        try actions.correct(id, AssetCorrection(edit: .set(recipe)))
        #expect(try database.asset(id)?.edit == recipe, "shows at once")
        #expect(await actions.send(with: client) == .done)
        #expect(try await client.asset(id).edit == recipe)
        let other = try HaldenDatabase()
        try other.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        try await Syncer(database: other, client: client).run()
        #expect(try other.asset(id)?.edit == recipe)

        try actions.correct(id, AssetCorrection(edit: .clear))
        #expect(await actions.send(with: client) == .done)
        try await Syncer(database: other, client: client).run()
        #expect(try other.asset(id)?.edit == nil)
    }

    /// Albums made here, also without a connection and with a photo still uploading: they reach
    /// the server once it can be reached (the photo once it is there) and every other phone.
    @Test func albumsReachTheServerAndOtherPhones() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        let (connection, token) = try await Connector.login(
            address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
            username: "lucas", password: RealServer.password, device: device)
        let client = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: server.port)!, trust: .pinned(connection.fingerprint),
            token: token)
        let nowhere = APIClient(
            base: APIClient.base(address: "127.0.0.1", port: 1)!, trust: .pinned(connection.fingerprint),
            token: token, timeout: 2)
        let database = try HaldenDatabase()
        try database.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        let root = server.folder.appendingPathComponent("phone")
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        var ids: [String] = []
        for n in 0..<3 {
            let id = UUID().uuidString.lowercased()
            try noiseJPEG(at: files.original("a\(n).jpg"), seed: UInt32(n + 7) &* 2_654_435_761)
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: "a\(n).jpg", kind: "photo",
                mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1_795_443_730_000 + Int64(n)))
            ids.append(id)
        }
        let uploader = Uploader(database: database, files: files, client: client)
        let third = ids[2]
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE upload SET retryAt = ? WHERE assetId = ?", arguments: [Int64.max, third])
        }
        #expect(await uploader.drain() == 2)

        let actions = Actions(database: database)
        let rome = try actions.createAlbum(named: "Rome", with: [ids[0], ids[2]])
        let empty = try actions.createAlbum(named: "Later")
        try actions.renameAlbum(rome, to: "Rome 2026")
        try actions.addToAlbum(rome, [ids[1]])
        try actions.deleteAlbum(empty)
        #expect(try database.albums().map(\.album.name) == ["Rome 2026"], "shows at once")
        #expect(try database.photos(inAlbum: rome).count == 3)
        #expect(await actions.send(with: nowhere) == .later)

        #expect(await actions.send(with: client) == .done)
        let onServer = try #require(try await client.albums().first)
        #expect(onServer.name == "Rome 2026" && Set(onServer.assetIds) == Set([ids[0], ids[1]]))
        #expect(try await client.albums().count == 1, "the empty one was deleted")
        #expect(try actions.pending().count == 1, "the third photo's part waits for its upload")

        try await database.writer.write { db in try db.execute(sql: "UPDATE upload SET retryAt = 0") }
        #expect(await uploader.drain() == 1)
        #expect(await actions.send(with: client) == .done)
        #expect(try actions.pending().isEmpty)
        #expect(try await client.albums().first?.assetIds.count == 3)

        // Another phone gets it with the sync; removing a photo there reaches this one.
        let other = try HaldenDatabase()
        try other.save(
            server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
        try await Syncer(database: other, client: client).run()
        #expect(try other.albums().map(\.album.name) == ["Rome 2026"])
        #expect(try other.albums().first?.count == 3)
        try Actions(database: other).removeFromAlbum(rome, [ids[0]])
        #expect(await Actions(database: other).send(with: client) == .done)
        try await Syncer(database: database, client: client).run()
        #expect(try database.photos(inAlbum: rome).count == 2)
    }

    /// Two phones send the same photo; the second finishes while the first is halfway. When the
    /// first one's last piece arrives, the server says "duplicate", and the first phone's photo
    /// becomes the one that is already there.
    @Test func aPhotoSentFromTwoPhonesAtOnceIsKeptOnce() async throws {
        let server = try RealServer()
        let info = try await server.ready()
        func phone(_ name: String) async throws -> (HaldenDatabase, FileLocations, APIClient) {
            let (connection, token) = try await Connector.login(
                address: "127.0.0.1", port: server.port, fingerprint: info.fingerprint,
                username: "lucas", password: RealServer.password,
                device: DeviceDescription(name: name, platform: "ios", installationId: "install-e2e-\(name)"))
            let database = try HaldenDatabase()
            try database.save(
                server: StoredServer(serverId: connection.serverId, connection: connection, syncSince: 0, backup: nil))
            let root = server.folder.appendingPathComponent(name)
            let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
            let client = APIClient(
                base: APIClient.base(address: "127.0.0.1", port: server.port)!,
                trust: .pinned(connection.fingerprint), token: token)
            return (database, files, client)
        }
        let (databaseA, filesA, clientA) = try await phone("phone-a")
        let (databaseB, filesB, clientB) = try await phone("phone-b")
        try noiseJPEG(at: filesA.original("a.jpg"))
        try FileManager.default.copyItem(at: filesA.original("a.jpg"), to: filesB.original("b.jpg"))
        let a = UUID().uuidString.lowercased()
        let b = UUID().uuidString.lowercased()
        try Uploader.enqueue(
            database: databaseA, files: filesA, assetId: a, fileName: "a.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1))
        try Uploader.enqueue(
            database: databaseB, files: filesB, assetId: b, fileName: "b.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 1))

        // Phone A gets halfway …
        let uploaderA = Uploader(database: databaseA, files: filesA, client: clientA, pieceSize: 128 << 10)
        let first = Task { await uploaderA.drain() }
        for _ in 0..<400 {
            if let item = try databaseA.upload(a), item.sent > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        first.cancel()
        _ = await first.value
        let cut = try #require(try databaseA.upload(a))
        #expect(cut.sent > 0 && cut.sent < cut.size)

        // … phone B sends all of it …
        #expect(await Uploader(database: databaseB, files: filesB, client: clientB).drain() == 1)
        #expect(try databaseB.asset(b)?.backedUp == true)

        // … and phone A finishes: its photo is B's.
        try await databaseA.writer.write { db in try db.execute(sql: "UPDATE upload SET retryAt = 0") }
        let againA = Uploader(database: databaseA, files: filesA, client: clientA, pieceSize: 128 << 10)
        #expect(await againA.drain() == 1)
        #expect(try databaseA.upload(a) == nil)
        let library = try databaseA.library()
        #expect(library.map(\.id) == [b])
        #expect(library.first?.backedUp == true)
        #expect(library.first?.localFile == "a.jpg", "the photo taken here stays on the phone")
        #expect(try await clientA.sync(since: 0).assets.map { $0.id.lowercased() } == [b])
    }
}

/// `halden pair` in the terminal: shows a code and waits until a device uses it.
final class PairingTerminal: @unchecked Sendable {
    let process = Process()
    let output = Pipe()

    init(server: RealServer) throws {
        process.executableURL = RealServer.binary
        process.arguments = ["--config", server.config.path, "pair"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func code() throws -> String {
        var text = ""
        let handle = output.fileHandleForReading
        while !text.contains("Valid until") {
            let piece = handle.availableData
            if piece.isEmpty { break }
            text += String(decoding: piece, as: UTF8.self)
        }
        guard
            let line = text.split(separator: "\n").first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("Code")
            })
        else {
            throw APIError.unexpected("no code in: \(text)")
        }
        return line.replacingOccurrences(of: "Code", with: "").replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    func finish() {
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    deinit {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
