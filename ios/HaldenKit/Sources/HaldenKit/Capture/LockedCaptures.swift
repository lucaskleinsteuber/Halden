import Foundation

/// Photos and videos taken with the lock-screen camera. That camera runs in an extension that
/// may only write into a folder the system gives it, and can't reach the server or the app's
/// database; the app takes everything over from there the next time it runs.
///
/// Each capture is its file and, written after it, a small description (`<id>.json`); a file
/// without its description was not finished and is left alone.
public enum LockedCaptures {
    struct Description: Codable {
        var kind: String
        var mimeType: String
        var file: String
        var metadata: UploadMetadata
        /// A Live Photo's video.
        var pairedFile: String?
    }

    public static func save(
        photo data: Data, heic: Bool, liveVideo: URL? = nil, metadata: UploadMetadata, into folder: URL
    ) throws {
        let id = UUID().uuidString.lowercased()
        let file = "\(id).\(heic ? "heic" : "jpg")"
        try data.write(to: folder.appendingPathComponent(file), options: .atomic)
        var paired: String?
        if let liveVideo {
            let name = "\(id)-live.mov"
            if (try? FileManager.default.moveItem(at: liveVideo, to: folder.appendingPathComponent(name))) != nil {
                paired = name
            }
        }
        try describe(
            id,
            Description(
                kind: "photo", mimeType: heic ? "image/heic" : "image/jpeg", file: file, metadata: metadata,
                pairedFile: paired),
            in: folder)
    }

    public static func save(video url: URL, metadata: UploadMetadata, into folder: URL) throws {
        let id = UUID().uuidString.lowercased()
        let file = "\(id).mov"
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(file))
        try describe(
            id, Description(kind: "video", mimeType: "video/quicktime", file: file, metadata: metadata), in: folder)
    }

    private static func describe(_ id: String, _ description: Description, in folder: URL) throws {
        try JSONEncoder().encode(description).write(to: folder.appendingPathComponent("\(id).json"), options: .atomic)
    }

    /// Takes every finished capture in `folder` into the library and the upload queue. Returns
    /// how many. Safe to repeat: what was taken over before is not taken twice.
    @discardableResult
    public static func takeOver(from folder: URL, database: HaldenDatabase, files: FileLocations) throws -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var taken = 0
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            let descriptionURL = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: descriptionURL),
                let description = try? JSONDecoder().decode(Description.self, from: data)
            else { continue }
            let source = folder.appendingPathComponent(description.file)
            if try database.asset(id) == nil, FileManager.default.fileExists(atPath: source.path) {
                if !FileManager.default.fileExists(atPath: files.original(description.file).path) {
                    try FileManager.default.moveItem(at: source, to: files.original(description.file))
                }
                try Uploader.enqueue(
                    database: database, files: files, assetId: id, fileName: description.file, kind: description.kind,
                    mimeType: description.mimeType, metadata: description.metadata)
                if let paired = description.pairedFile {
                    let pairedSource = folder.appendingPathComponent(paired)
                    if FileManager.default.fileExists(atPath: pairedSource.path) {
                        try FileManager.default.moveItem(at: pairedSource, to: files.original(paired))
                        try Uploader.enqueuePairedVideo(
                            database: database, files: files, assetId: id, fileName: paired,
                            mimeType: "video/quicktime")
                    }
                }
                taken += 1
            }
            if let paired = description.pairedFile {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(paired))
            }
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: descriptionURL)
        }
        return taken
    }
}
