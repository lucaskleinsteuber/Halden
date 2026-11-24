import AVFoundation
import Foundation
import GRDB
import HaldenKit
import LockedCameraCapture
import Observation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Everything the screens show and do. Lives as long as the app.
@MainActor
@Observable
final class AppModel {
    /// The server this phone belongs to; `nil` before pairing.
    private(set) var connection: ServerConnection?
    /// Newest first, without trash.
    private(set) var library: [LocalAsset] = []
    /// Goes up whenever `library` changes, so views can tell cheaply.
    private(set) var libraryVersion = 0
    private(set) var settings: AppSettings
    /// Uploads not finished yet, by asset id: how much of the file the server has (0…1).
    private(set) var uploads: [String: Double] = [:]
    private(set) var backup: BackupState?
    private(set) var reachable = false
    private(set) var problem: String?
    private(set) var busy = false
    /// The network right now, and why uploads wait (`nil` when everything may go).
    private(set) var network = NetworkSituation(kind: .wifi)
    private(set) var uploadsWaitBecause: String?
    /// "12 of 40" for the current round of uploads.
    private(set) var uploadSummary = UploadSummary()
    /// Days photos stay in the trash before they are deleted for good (the server says).
    private(set) var trashDays = 30
    /// Goes up when something (a control, the lock-screen camera) asks for the camera.
    private(set) var cameraRequests = 0

    let database: HaldenDatabase
    let files: FileLocations
    let tokens: any TokenStore
    let settingsStore: any SettingsStore
    let actions: Actions
    let pipeline: ImagePipeline
    /// Previews and originals for the full-screen view and sharing.
    let media: MediaFiles
    /// Apple Photos: taking over new photos, saving Halden's, deleting in both.
    let photos: PhotosSync
    /// The import of the photos that were in Apple Photos before Halden.
    private(set) var photosImport = PhotosImport()
    private let photosWatcher = PhotosWatcher()

    struct PhotosImport: Equatable {
        var imported = 0
        var running = false
        var done = false
        var startedOnce = false
    }
    /// Made at app start, so the camera is ready the moment its screen opens.
    let camera: CameraModel
    /// Uploads the system goes on with while Halden is in the background.
    let background: BackgroundUploads
    private var client: APIClient?
    private let networkWatcher = NetworkWatcher()
    private let uploadActivity = UploadActivity()
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

    init(
        database: HaldenDatabase, files: FileLocations, tokens: any TokenStore,
        settings: any SettingsStore = DefaultsSettingsStore(), standInCamera: Bool = false,
        backgroundConfiguration: URLSessionConfiguration? = nil
    ) {
        self.database = database
        self.files = files
        self.tokens = tokens
        self.settingsStore = settings
        self.settings = settings.load()
        self.actions = Actions(database: database)
        self.pipeline = ImagePipeline(loader: ThumbnailLoader(files: files, client: nil))
        self.media = MediaFiles(files: files, client: nil)
        self.photos = PhotosSync(library: SystemPhotoLibrary(), database: database, files: files)
        self.camera = CameraModel.make(standIn: standInCamera)
        self.background = BackgroundUploads(database: database, files: files, configuration: backgroundConfiguration)
        camera.settings = { [weak self] in self?.settings ?? AppSettings() }
        camera.keepPhoto = { [weak self] photo, metadata in self?.keep(photo: photo, metadata: metadata) }
        camera.keepVideo = { [weak self] url, metadata in self?.keep(video: url, metadata: metadata) }
        camera.prepare()
        networkWatcher.changed = { [weak self] situation in
            self?.network = situation
            // Back online, or onto Wi-Fi: go on at once instead of at the next round.
            self?.refresh()
        }
        networkWatcher.start()
        background.ended = { [weak self] in
            // A background upload ended: the thumbnails follow when the app is in front.
            Task { @MainActor in self?.backgroundUploadEnded() }
        }
        photosWatcher.changed = { [weak self] in self?.takeOverPhotos() }
        if (try? photosImportStarted()) == true { photosImport.startedOnce = true }
        observe()
        restore()
    }

    /// What may be uploaded now, by the settings and the network.
    var uploadPermit: UploadPermit {
        UploadRules.permit(on: network, atHome: atHome, settings: settings)
    }

    /// The server answers at its home-network address (not over Tailscale).
    var atHome: Bool {
        guard let host = client?.base.host() else { return false }
        return !Addresses.isTailscale(host)
    }

    /// Changes a setting and keeps it.
    func update(_ change: (inout AppSettings) -> Void) {
        let before = settings
        change(&settings)
        settingsStore.save(settings)
        // Upload rules or copies changed: apply them now.
        if before.uploadOverCellular != settings.uploadOverCellular
            || before.videosOnlyOnWiFi != settings.videosOnlyOnWiFi
            || before.onlyOnHomeNetwork != settings.onlyOnHomeNetwork
            || before.keepLocalCopies != settings.keepLocalCopies
        {
            refresh()
        }
    }

    /// The app's real database, files and Keychain; for UI tests (`-ui-testing`) an empty
    /// in-memory world, and with `-ui-testing-signed-in` one that looks paired.
    static func make() -> AppModel {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing") || arguments.contains("-ui-testing-signed-in") {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let database = try! HaldenDatabase()
            let files = try! FileLocations(root: temporary, caches: temporary.appendingPathComponent("caches"))
            if let index = arguments.firstIndex(of: "-ui-testing-library"), index + 1 < arguments.count,
                let count = Int(arguments[index + 1])
            {
                try! UITestWorld.fill(database, files: files, with: count)
            }
            // The simulator's Apple Photos outlives the tests: the stand-in camera's photos stay out.
            var testSettings = AppSettings()
            testSettings.saveToPhotos = false
            let model = AppModel(
                database: database, files: files, tokens: MemoryTokenStore(),
                settings: MemorySettingsStore(testSettings), standInCamera: true, backgroundConfiguration: .ephemeral)
            // Signed in to the real server the UI tests started (`ios/ui-tests.sh`).
            let environment = ProcessInfo.processInfo.environment
            if arguments.contains("-ui-testing-sign-in"), let server = environment["HALDEN_TEST_SERVER"],
                let password = environment["HALDEN_TEST_PASSWORD"], let colon = server.lastIndex(of: ":"),
                let port = Int(server[server.index(after: colon)...])
            {
                let address = String(server[..<colon])
                Task {
                    guard let info = try? await model.inspect(address: address, port: port) else { return }
                    await model.login(
                        address: address, port: port, fingerprint: info.fingerprint, username: "lucas",
                        password: password)
                }
            }
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
                MainActor.assumeIsolated {
                    self?.library = assets
                    self?.libraryVersion += 1
                }
            }
        uploadObservation =
            ValueObservation
            .tracking { db in try UploadItem.filter(sql: "state <> 'done'").fetchAll(db) }
            .start(in: database.writer, scheduling: .async(onQueue: .main)) { _ in
            } onChange: { [weak self] items in
                MainActor.assumeIsolated {
                    // A Live Photo is two uploads: the grid shows them as one, by their bytes.
                    var progress: [String: (sent: Int64, size: Int64)] = [:]
                    for item in items {
                        let before = progress[item.assetId] ?? (0, 0)
                        progress[item.assetId] = (before.sent + item.sent, before.size + item.size)
                    }
                    self?.uploads = progress.mapValues { $0.size > 0 ? Double($0.sent) / Double($0.size) : 0 }
                    if let summary = try? self?.database.uploadSummary() { self?.uploadSummary = summary }
                    self?.showUploadActivity()
                }
            }
    }

    /// The server from the last time, with its token from the Keychain.
    private func restore() {
        guard let stored = try? database.server(), let token = tokens.token(for: stored.serverId) else { return }
        connection = stored.connection
        backup = stored.backup
        connect(stored.connection, token: token)
        photosWatcher.start()
    }

    private func connect(_ connection: ServerConnection, token: String) {
        guard let address = connection.addresses.first,
            let base = APIClient.base(address: address, port: connection.port)
        else { return }
        let first = APIClient(base: base, trust: .pinned(connection.fingerprint), token: token)
        client = first
        Task {
            await pipeline.use(ThumbnailLoader(files: files, client: first))
            await media.use(first)
        }
        work()
        // Home network or Tailscale: whichever address answers right now.
        Task { [weak self] in
            if let (found, _) = await Connector.reach(
                addresses: connection.addresses, port: connection.port,
                fingerprint: connection.fingerprint, serverId: connection.serverId)
            {
                let client = found.signedIn(with: token)
                self?.client = client
                if let self {
                    await self.pipeline.use(ThumbnailLoader(files: self.files, client: client))
                    await self.media.use(client)
                }
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
            askForPhotosOnce()
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
        await background.cancelAll()
        self.connection = nil
        backup = nil
    }

    // MARK: Taking photos and videos

    /// A photo straight from the camera: written to disk first (away from the main thread), then
    /// into the library and the upload queue. The shutter never waits for the disk or the network.
    func keep(photo: TakenPhoto, metadata: UploadMetadata) {
        let id = UUID().uuidString.lowercased()
        let name = "\(id).\(photo.heic ? "heic" : "jpg")"
        let mimeType = photo.heic ? "image/heic" : "image/jpeg"
        store(what: "photo", assetId: id) { [database, files] in
            try photo.data.write(
                to: files.original(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: name, kind: "photo",
                mimeType: mimeType, metadata: metadata)
        }
    }

    /// A video the camera finished: moved next to the photos, then like a photo.
    func keep(video url: URL, metadata: UploadMetadata) {
        let id = UUID().uuidString.lowercased()
        let name = "\(id).mov"
        store(what: "video", assetId: id) { [database, files] in
            try FileManager.default.moveItem(at: url, to: files.original(name))
            try? (files.original(name) as NSURL).setResourceValue(
                URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
            try Uploader.enqueue(
                database: database, files: files, assetId: id, fileName: name, kind: "video",
                mimeType: "video/quicktime", metadata: metadata)
        }
    }

    private func store(what: String, assetId: String, _ work: @escaping @Sendable () throws -> Void) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try work()
                await self?.work()
                await self?.saveToPhotos(assetId)
            } catch {
                await MainActor.run { self?.problem = "The \(what) could not be saved: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: Working with the server

    /// Uploads what is waiting, then syncs. Again whenever there is something new, and every
    /// half minute while the app is open.
    func work() {
        guard working == nil, let client else { return }
        working = Task { [database, files, actions, weak self] in
            while !Task.isCancelled {
                let uploader = Uploader(database: database, files: files, client: client)
                let permit = self?.uploadPermit ?? .nothing
                self?.uploadsWaitBecause =
                    (try? database.pendingUploads().isEmpty) == false
                    ? UploadRules.reason(
                        for: permit, on: self?.network ?? .offline, atHome: self?.atHome ?? false,
                        settings: self?.settings ?? AppSettings())
                    : nil
                await uploader.drain(permit: permit, skipping: await self?.background.running() ?? [])
                if self?.settings.keepLocalCopies == false {
                    _ = try? LocalCopies.remove(database: database, files: files)
                }
                // Changes made here (trash, corrections, …) before the sync, so it shows them.
                if await actions.send(with: client) == .signedOut {
                    await self?.signOut()
                    return
                }
                var reachable = true
                do {
                    try await Syncer(database: database, client: client).run()
                    let me = try await client.me()
                    self?.backup = me.backup
                    if let days = me.trashDays { self?.trashDays = days }
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

    // MARK: The library

    /// One asset as this iPhone knows it.
    func asset(_ id: String) -> LocalAsset? {
        try? database.asset(id)
    }

    /// A video from the server, played through the pinned connection.
    func stream(_ asset: LocalAsset) -> AVURLAsset? {
        StreamLoader.asset(id: asset.id, client: client)
    }

    /// Everything the server knows about one asset.
    func detail(_ id: String) async throws -> AssetDetail {
        guard let client else { throw APIError.unreachable("not connected") }
        return try await client.detail(id)
    }

    /// Corrects time, place, title or description; shows at once, reaches the server when it can.
    func correct(_ id: String, _ correction: AssetCorrection) {
        do {
            try actions.correct(id, correction)
            refresh()
        } catch {
            problem = "The correction could not be saved: \(error.localizedDescription)"
        }
    }

    /// One place for many photos.
    func setPlace(_ ids: [String], _ place: CorrectedLocation) {
        do {
            try actions.setLocation(ids, place)
            refresh()
        } catch {
            problem = "The place could not be saved: \(error.localizedDescription)"
        }
    }

    /// The server's suggestions for photos without a place (the place of the nearest photo in
    /// time), by asset id.
    func placeSuggestions() async -> [String: PlaceSuggestion] {
        guard let client else { return [:] }
        var found: [String: PlaceSuggestion] = [:]
        var before: Int64?
        for _ in 0..<20 {
            guard let page = try? await client.withoutPlace(before: before, limit: 500), let last = page.last
            else { break }
            for entry in page { found[entry.asset.id.lowercased()] = entry.suggestion }
            before = last.asset.takenAt
            if page.count < 500 { break }
        }
        return found
    }

    // MARK: Deleting

    /// "Delete everywhere": into the server's trash, on every device; restorable for `trashDays`.
    func moveToTrash(_ ids: [String]) {
        perform("moved to the trash") { try $0.trash(ids) }
        // Also in Apple Photos, if they are there; the system asks first.
        let settings = settings
        Task { _ = await photos.deleteInPhotos(assetIds: ids, settings: settings) }
    }

    func restore(_ ids: [String]) {
        perform("restored") { try $0.restore(ids) }
    }

    /// For good, from the trash only.
    func deleteForGood(_ ids: [String]) {
        perform("deleted") { try $0.deleteForGood(ids) }
    }

    /// "Remove from this iPhone": only photos safely on the server; they stay in the library and
    /// come from the server when opened. Returns how many were removed.
    @discardableResult
    func removeFromPhone(_ ids: [String]) -> Int {
        (try? LocalCopies.remove(ids, database: database, files: files)) ?? 0
    }

    /// How many of these could be removed from this iPhone (on the server, and here).
    func removableFromPhone(_ ids: [String]) -> Int {
        ids.compactMap { asset($0) }.filter { $0.backedUp && $0.localFile != nil }.count
    }

    private func perform(_ what: String, _ change: (Actions) throws -> Void) {
        do {
            try change(actions)
            refresh()
        } catch {
            problem = "The photos could not be \(what): \(error.localizedDescription)"
        }
    }

    enum ShareKind {
        /// The file as it was taken.
        case original
        /// With the corrected time, place, title and description written into it.
        case corrected
        /// The copy in the account's preferred format (`/me/settings`).
        case preferred
    }

    /// A file to share; fetched from the server when it isn't on this iPhone.
    func fileToShare(_ asset: LocalAsset, as kind: ShareKind) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch kind {
        case .original:
            return try await media.original(of: asset)
        case .corrected:
            let original = try await media.original(of: asset)
            return try await Export.copy(of: original, asset: asset, withCorrections: true, into: folder)
        case .preferred:
            guard let client else { throw APIError.unreachable("not connected") }
            let download = folder.appendingPathComponent("\(asset.id).download")
            let type = try await client.download(asset: asset.id, role: "converted", to: download)
            let ext = type.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "bin"
            let named = folder.appendingPathComponent("Halden-\(asset.id.prefix(8)).\(ext)")
            try? FileManager.default.removeItem(at: named)
            try FileManager.default.moveItem(at: download, to: named)
            return named
        }
    }

    // MARK: In the background

    /// The app left the screen: what is left of every upload goes to the system, which sends it
    /// also while Halden is suspended; and background time is asked for, for the rest.
    func enterBackground() {
        working?.cancel()
        working = nil
        guard let client, (try? database.pendingUploads().isEmpty) == false else { return }
        showUploadActivity(leaving: true)
        let time = UIApplication.shared.beginBackgroundTask(withName: "Hand over uploads")
        Task {
            await background.handOver(client: client, permit: uploadPermit, settings: settings)
            AppDelegate.scheduleProcessing()
            UIApplication.shared.endBackgroundTask(time)
        }
    }

    /// Background time from the system (`BGProcessingTask`): upload what may go, then hand the
    /// rest over.
    func backgroundWork() async {
        guard let client else { return }
        _ = try? await photos.takeOverChanges(settings: settings)
        let uploader = Uploader(database: database, files: files, client: client)
        await uploader.drain(permit: uploadPermit, skipping: await background.running())
        if !Task.isCancelled {
            _ = await actions.send(with: client)
            _ = try? await Syncer(database: database, client: client).run()
        }
        await background.handOver(client: client, permit: uploadPermit, settings: settings)
        if (try? database.pendingUploads().isEmpty) == false { AppDelegate.scheduleProcessing() }
    }

    private func showUploadActivity(leaving: Bool = false) {
        guard let connection else { return }
        uploadActivity.show(uploadSummary, waiting: uploadsWaitBecause, server: connection.name, leaving: leaving)
    }

    /// Photos and videos the lock-screen camera kept since the app last ran.
    private func takeOverLockedCaptures() {
        let folders = LockedCameraCaptureManager.shared.sessionContentURLs
        guard !folders.isEmpty else { return }
        Task {
            for folder in folders
            where (try? LockedCaptures.takeOver(from: folder, database: database, files: files)) != nil {
                try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: folder)
            }
            work()
        }
    }

    /// Shows the camera tab.
    func showCamera() {
        cameraRequests += 1
    }

    private func backgroundUploadEnded() {
        if UIApplication.shared.applicationState == .active { refresh() }
    }

    /// Pull to refresh, and when the app comes to the front.
    func refresh() {
        takeOverLockedCaptures()
        takeOverPhotos()
        working?.cancel()
        working = nil
        work()
    }

    // MARK: Apple Photos

    /// Asks for Apple Photos once, after connecting: everything, to take over new photos (the
    /// person may allow only some, or only adding).
    func askForPhotosOnce() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined,
            settings.importFromPhotos || settings.saveToPhotos
        else { return }
        Task {
            _ = await SystemPhotoLibrary.ask(everything: true)
            photosWatcher.start()
            takeOverPhotos()
        }
    }

    /// What is new in Apple Photos comes in; what was deleted there goes to the trash here.
    func takeOverPhotos() {
        guard connection != nil else { return }
        let settings = settings
        Task {
            guard let result = try? await photos.takeOverChanges(settings: settings), result.added + result.trashed > 0
            else { return }
            working?.cancel()
            working = nil
            work()
        }
    }

    /// A photo or video taken here goes into Apple Photos too.
    private func saveToPhotos(_ assetId: String) async {
        await photos.save(assetId: assetId, settings: settings)
    }

    /// Imports what was in Apple Photos before Halden, in pieces, going on where it stopped.
    func importPhotoLibrary() {
        guard !photosImport.running else { return }
        photosImport.running = true
        photosImport.startedOnce = true
        Task {
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await SystemPhotoLibrary.ask(everything: true)
            }
            while true {
                guard let (count, done) = try? await photos.importExisting(limit: 50) else { break }
                photosImport.imported += count
                if count > 0 { work() }
                if done {
                    photosImport.done = true
                    break
                }
            }
            photosImport.running = false
            refresh()
        }
    }

    private func photosImportStarted() throws -> Bool {
        try database.meta("photosImportedUpTo") != nil
    }

}
