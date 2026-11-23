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
        process.executableURL = Self.binary
        process.arguments = base + ["serve"]
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
func noiseJPEG(at url: URL) throws {
    let width = 2000
    let height = 1500
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var state: UInt32 = 2_463_534_242
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
        process.waitUntilExit()
    }
}
