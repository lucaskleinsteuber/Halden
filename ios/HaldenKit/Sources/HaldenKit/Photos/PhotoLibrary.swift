import Foundation

/// One item in Apple Photos, as much as Halden needs of it.
public struct PhotoItem: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case photo, video
    }

    public var localIdentifier: String
    public var kind: Kind
    /// A Live Photo: a photo with a short video.
    public var isLivePhoto: Bool
    /// Captured as a screenshot (no GPS of its own).
    public var isScreenshot: Bool
    /// Captured as a screen recording (no GPS of its own).
    public var isScreenRecording: Bool
    public var creationDate: Date?
    public var location: ClientLocation?
    public var width: Int
    public var height: Int
    public var durationMs: Int64?

    public init(
        localIdentifier: String, kind: Kind, isLivePhoto: Bool = false, isScreenshot: Bool = false,
        isScreenRecording: Bool = false, creationDate: Date?, location: ClientLocation? = nil, width: Int,
        height: Int, durationMs: Int64? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.kind = kind
        self.isLivePhoto = isLivePhoto
        self.isScreenshot = isScreenshot
        self.isScreenRecording = isScreenRecording
        self.creationDate = creationDate
        self.location = location
        self.width = width
        self.height = height
        self.durationMs = durationMs
    }
}

/// What changed in Apple Photos since the last time.
public struct PhotoChanges: Sendable {
    public var added: [PhotoItem]
    public var deleted: [String]
    /// Where to continue next time.
    public var token: Data?

    public init(added: [PhotoItem], deleted: [String], token: Data?) {
        self.added = added
        self.deleted = deleted
        self.token = token
    }
}

/// A file of an Apple Photos item, written out for Halden.
public struct ExportedFile: Sendable, Equatable {
    public var url: URL
    public var mimeType: String
    /// The file's name in Apple Photos (`IMG_0001.HEIC`).
    public var originalFilename: String?

    public init(url: URL, mimeType: String, originalFilename: String?) {
        self.url = url
        self.mimeType = mimeType
        self.originalFilename = originalFilename
    }
}

/// Apple Photos, as Halden uses it: what is new or gone since the last time, every item for the
/// first import, writing items out, saving into it and deleting from it. `SystemPhotoLibrary`
/// is the real one; tests use a stand-in.
public protocol PhotoLibrary: Sendable {
    /// Whether Halden may read the whole library (for importing).
    func mayRead() async -> Bool
    /// Whether Halden may add to it (for saving its own photos there).
    func mayAdd() async -> Bool
    /// What was added and deleted since `token`. With `nil` nothing is reported, only the token to
    /// start from: the first look must not import the whole library unasked.
    func changes(since token: Data?) async throws -> PhotoChanges
    /// Items created after `date` (all with `nil`), oldest first, at most `limit`: the import of
    /// what was there before Halden.
    func items(after date: Date?, limit: Int) async throws -> [PhotoItem]
    /// Looks up specific items by their Apple Photos local identifiers (e.g. to recognise
    /// previously imported screenshots).
    func items(withIdentifiers identifiers: [String]) async -> [PhotoItem]
    /// The item's original file, and for a Live Photo its video too (second).
    func export(_ item: PhotoItem, into folder: URL) async throws -> [ExportedFile]
    /// Adds a photo or video file (a photo with `pairedVideo` as a Live Photo); returns its
    /// identifier there.
    func save(_ file: URL, kind: PhotoItem.Kind, pairedVideo: URL?) async throws -> String
    /// Deletes items (the system asks the person first). Returns whether they were deleted.
    func delete(_ identifiers: [String]) async -> Bool
}
