import Foundation

/// Uploads that go on while Halden is in the background, suspended or even closed. When the app
/// leaves the screen, the rest of every unfinished upload is handed to a background
/// `URLSession`: one request from the current offset to the end, from the original file itself
/// (or, after a break, from a copy of its rest). The system sends it when it can and wakes the
/// app when it is done. The pinned certificate is checked here too.
///
/// The app never waits for these: the foreground uploader leaves uploads the system is sending
/// alone, and when one ends, the database says where it stands.
public final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let identifier = "com.lucas.halden.ios.uploads"

    let database: HaldenDatabase
    let files: FileLocations
    private let lock = NSLock()
    private var answers: [Int: Data] = [:]
    private var eventsDone: (@Sendable () -> Void)?
    private var session: URLSession!
    /// Called on any thread when an upload ended (so the app can show it and go on).
    public var ended: (@Sendable () -> Void)?

    /// `configuration`: a background one in the app; tests use an ordinary one.
    public init(
        database: HaldenDatabase, files: FileLocations, configuration: URLSessionConfiguration? = nil
    ) {
        self.database = database
        self.files = files
        super.init()
        let configuration = configuration ?? Self.backgroundConfiguration()
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func backgroundConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        return configuration
    }

    /// Where copies of the rest of a file wait while they are sent.
    var restFolder: URL {
        files.thumbnails.deletingLastPathComponent().appendingPathComponent("Rest", isDirectory: true)
    }

    /// Uploads the system is sending right now (by `UploadItem.key`).
    public func running() async -> Set<String> {
        Set(
            await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(
                \.taskDescription))
    }

    /// Hands the rest of every upload that may go (by `permit`) to the system. Returns how many.
    /// Hashing, announcing and asking the server where an upload stands happen here, so call it
    /// while the app still has a little time (right after it left the screen).
    @discardableResult
    public func handOver(client: APIClient, permit: UploadPermit, settings: AppSettings) async -> Int {
        guard permit.any else { return 0 }
        let busy = await running()
        let uploader = Uploader(database: database, files: files, client: client)
        guard let items = try? database.pendingUploads() else { return 0 }
        var handed = 0
        for item in items
        where item.state != "failed" && item.state != "thumbnails" && permit.allows(mimeType: item.mimeType)
            && !busy.contains(item.key)
        {
            guard let ready = try? await uploader.ready(item), let id = ready.uploadId else { continue }
            guard let file = try? restFile(for: ready) else { continue }
            var request = client.restRequest(upload: id, offset: ready.sent)
            // The rules hold while the system sends: should the phone leave the Wi-Fi, a video
            // waits instead of going over cellular.
            let video = ready.mimeType.hasPrefix("video/")
            let metered =
                settings.uploadOverCellular && !settings.onlyOnHomeNetwork && !(video && settings.videosOnlyOnWiFi)
            request.allowsCellularAccess = metered
            request.allowsExpensiveNetworkAccess = metered
            request.allowsConstrainedNetworkAccess = !(video && settings.videosOnlyOnWiFi)
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = ready.key
            task.countOfBytesClientExpectsToSend = ready.size - ready.sent
            task.countOfBytesClientExpectsToReceive = 4096
            task.resume()
            handed += 1
        }
        return handed
    }

    /// The original when the whole file goes, else a copy of the part the server doesn't have.
    func restFile(for item: UploadItem) throws -> URL {
        let original = files.original(item.file)
        guard item.sent > 0 else { return original }
        try FileManager.default.createDirectory(at: restFolder, withIntermediateDirectories: true)
        let rest = restFolder.appendingPathComponent("\(item.assetId)-\(item.role)-\(item.sent).part")
        if FileManager.default.fileExists(atPath: rest.path) { return rest }
        let partial = rest.appendingPathExtension("writing")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let input = try FileHandle(forReadingFrom: original)
        let output = try FileHandle(forWritingTo: partial)
        defer {
            try? input.close()
            try? output.close()
        }
        try input.seek(toOffset: UInt64(item.sent))
        while let piece = try input.read(upToCount: 4 << 20), !piece.isEmpty {
            try output.write(contentsOf: piece)
        }
        try FileManager.default.moveItem(at: partial, to: rest)
        return rest
    }

    /// Stops everything the system is sending (signing out).
    public func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    /// Releases the underlying `URLSession` and its strong delegate reference (used by tests).
    public func invalidate() {
        session.finishTasksAndInvalidate()
    }

    /// From the app delegate: the system woke the app for this session's events.
    public func handleEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { eventsDone = completion }
    }

    // MARK: URLSession

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let presented = Fingerprint.of(trust: trust),
            let pinned = try? database.server()?.connection.fingerprint,
            pinned.lowercased() == presented
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { answers[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { answers.removeValue(forKey: task.taskIdentifier) }
        guard let key = task.taskDescription?.split(separator: "|").map(String.init), key.count == 2,
            let item = try? database.upload(key[0], role: key[1])
        else { return }
        let assetId = item.assetId
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let state = body.flatMap { try? JSONDecoder().decode(UploadState.self, from: $0) }
        if error == nil, (200..<300).contains(status), let state {
            if state.state == "completed" {
                _ = try? Uploader.onServer(item, seq: state.asset?.seq, database: database)
            } else if state.state == "duplicate" {
                try? Uploader.duplicate(item, existing: state.existingAssetId, database: database)
            }
        } else {
            // Broken off: the foreground (or the next hand-over) asks the server where it stands.
            var waiting = item
            if waiting.state == "sending" { waiting.state = "waiting" }
            if let error { waiting.lastError = error.localizedDescription }
            try? database.writer.write { db in try waiting.update(db) }
        }
        if let rest = try? FileManager.default.contentsOfDirectory(at: restFolder, includingPropertiesForKeys: nil) {
            for file in rest where file.lastPathComponent.hasPrefix("\(assetId)-\(item.role)-") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        ended?()
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = lock.withLock {
            defer { eventsDone = nil }
            return eventsDone
        }
        done?()
    }
}
