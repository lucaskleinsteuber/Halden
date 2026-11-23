import Foundation
import GRDB
import Testing

@testable import HaldenKit

@Suite struct PairingLinkTests {
    let fingerprint = String(repeating: "ab", count: 32)

    @Test func readsTheLinkFromTheQRCode() throws {
        let link = try #require(
            PairingLink(
                "halden://pair?v=1&id=D4C45D53-6A54-417C-83B1-9AA070032CDF&name=Home%20Server&addr=192.168.178.72,100.101.102.103,fe80::1%25en0&port=47130&fp=\(fingerprint.uppercased())&code=7MMV1M2EA2"
            ))
        #expect(link.serverId == "d4c45d53-6a54-417c-83b1-9aa070032cdf")
        #expect(link.serverName == "Home Server")
        #expect(link.addresses == ["192.168.178.72", "100.101.102.103", "fe80::1%en0"])
        #expect(link.port == 47130)
        #expect(link.fingerprint == fingerprint)
        #expect(link.code == "7MMV1M2EA2")
    }

    @Test(arguments: [
        "https://example.com/pair?v=1",
        "halden://pair?v=2&id=d4c45d53-6a54-417c-83b1-9aa070032cdf&addr=1.2.3.4&port=1&fp=00&code=x",
        "halden://pair?v=1&id=not-a-uuid&addr=1.2.3.4&port=47130&fp=\(String(repeating: "ab", count: 32))&code=x",
        "halden://pair?v=1&id=d4c45d53-6a54-417c-83b1-9aa070032cdf&addr=1.2.3.4&port=99999&fp=\(String(repeating: "ab", count: 32))&code=x",
        "halden://pair?v=1&id=d4c45d53-6a54-417c-83b1-9aa070032cdf&addr=1.2.3.4&port=47130&fp=short&code=x",
        "",
    ])
    func refusesAnythingElse(text: String) {
        #expect(PairingLink(text) == nil)
    }

    @Test func addressesBecomeURLs() {
        #expect(
            APIClient.base(address: "192.168.1.5", port: 47130)?.absoluteString == "https://192.168.1.5:47130/api/v1")
        #expect(
            APIClient.base(address: "fe80::1%en0", port: 47130)?.absoluteString
                == "https://[fe80::1%25en0]:47130/api/v1")
        #expect(
            APIClient.base(address: "homeserver.local", port: 1)?.absoluteString == "https://homeserver.local:1/api/v1")
    }

    @Test func fingerprintsShowInGroupsOfFour() {
        #expect(Fingerprint.display("3fa90c1d") == "3FA9 0C1D")
        #expect(Fingerprint.isValid(fingerprint))
        #expect(!Fingerprint.isValid("xyz"))
    }
}

@Suite struct BulkFilesTests {
    @Test func readsEntriesAndSkipsMissingOnes() throws {
        let first = UUID()
        let missing = UUID()
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: first.uuid) { Array($0) })
        data.append(contentsOf: [0, 0, 0, 3])
        data.append(contentsOf: [1, 2, 3])
        data.append(contentsOf: withUnsafeBytes(of: missing.uuid) { Array($0) })
        data.append(contentsOf: [0, 0, 0, 0])
        let files = try BulkFiles.parse(data)
        #expect(files == [first.uuidString.lowercased(): Data([1, 2, 3])])
        #expect(throws: APIError.self) { try BulkFiles.parse(data.prefix(25)) }
    }
}

@Suite struct DatabaseTests {
    func asset(_ id: String, takenAt: Int64, files: [AssetFile] = [], trashed: Bool = false, deleted: Bool = false)
        -> Asset
    {
        Asset(
            id: id, kind: "photo", takenAt: takenAt, timeZoneOffsetMinutes: 60, width: 4032,
            height: 3024, durationMs: nil, location: nil, files: files, seq: takenAt,
            trashedAt: trashed ? 1 : nil, deletedAt: deleted ? 2 : nil, title: nil)
    }

    @Test func syncedAssetsMergeWithPhotosTakenHere() throws {
        let database = try HaldenDatabase()
        // Taken here, not backed up yet.
        try database.writer.write { db in
            try LocalAsset(id: "a", kind: "photo", takenAt: 100, localFile: "a.heic", mimeType: "image/heic").insert(db)
        }
        let original = AssetFile(
            role: "original", sha256: "11", size: 10, mimeType: "image/heic", width: nil, height: nil)
        let thumbnail = AssetFile(
            role: "thumbnail", sha256: "22", size: 1, mimeType: "image/jpeg", width: 512, height: 384)
        try database.writer.write { db in
            try Syncer.merge(asset("A", takenAt: 100, files: [original, thumbnail]), into: db)
            try Syncer.merge(asset("b", takenAt: 300), into: db)
            try Syncer.merge(asset("c", takenAt: 200, trashed: true), into: db)
            try Syncer.merge(asset("d", takenAt: 400, deleted: true), into: db)
        }
        let library = try database.library()
        #expect(library.map(\.id) == ["b", "a"], "newest first, without trash and tombstones")
        let mine = try #require(try database.asset("a"))
        #expect(mine.localFile == "a.heic", "the local file stays")
        #expect(mine.backedUp)
        #expect(mine.thumbnailSha256 == "22")
    }

    @Test func signingOutKeepsWhatIsNotBackedUp() throws {
        let database = try HaldenDatabase()
        let connection = ServerConnection(
            serverId: "s", name: "Home", addresses: ["1.2.3.4"], port: 47130,
            fingerprint: String(repeating: "0", count: 64), userId: "u", username: "lucas", deviceId: "d")
        try database.save(server: StoredServer(serverId: "s", connection: connection, syncSince: 9, backup: nil))
        try database.writer.write { db in
            try LocalAsset(id: "mine", kind: "photo", takenAt: 1, localFile: "mine.heic").insert(db)
            try LocalAsset(id: "synced", kind: "photo", takenAt: 2).insert(db)
        }
        #expect(try database.server()?.syncSince == 9)
        try database.forgetServer()
        #expect(try database.server() == nil)
        #expect(try database.library().map(\.id) == ["mine"])
    }
}
