import Foundation

/// An error the server or the connection reported.
public enum APIError: Error, Sendable, Equatable, LocalizedError {
    /// The server answered with an error (see `docs/PROTOCOL.md` › Errors).
    case server(status: Int, code: String, message: String, offset: Int64?)
    /// No answer: offline, wrong address, or the certificate isn't the pinned one.
    case unreachable(String)
    /// The answer wasn't what the protocol says.
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message, _): message
        case .unreachable(let why): "The server can't be reached (\(why))."
        case .unexpected(let what): "The server's answer was not understood (\(what))."
        }
    }

    public var code: String? {
        if case .server(_, let code, _, _) = self { code } else { nil }
    }

    public var status: Int? {
        if case .server(let status, _, _, _) = self { status } else { nil }
    }

    /// The token stopped working: the device was signed out or blocked.
    public var signedOut: Bool { status == 401 && code == "unauthorized" }
}

/// Talks to one Halden server over HTTPS (HTTP/2, TLS 1.3), trusting only its pinned certificate.
public final class APIClient: Sendable {
    /// `https://<address>:<port>/api/v1`
    public let base: URL
    public let trust: Trust
    let token: String?
    let session: URLSession
    private let delegate: TrustDelegate

    public init(base: URL, trust: Trust, token: String? = nil, timeout: TimeInterval = 30) {
        self.base = base
        self.trust = trust
        self.token = token
        let delegate = TrustDelegate(trust: trust)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout * 4, 300)
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// The same server with a token.
    public func signedIn(with token: String) -> APIClient {
        APIClient(base: base, trust: trust, token: token)
    }

    /// The fingerprint the server presented last (for showing it before a password sign-in).
    public var presentedFingerprint: String? { delegate.lastFingerprint }

    /// `https://192.168.1.20:47130/api/v1`; IPv6 in brackets, with its zone if it has one.
    public static func base(address: String, port: Int) -> URL? {
        var host = address.trimmingCharacters(in: .whitespaces)
        if host.contains(":") && !host.hasPrefix("[") {
            host = "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
        }
        return URL(string: "https://\(host):\(port)/api/v1")
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Sends a request and returns the body and the response, turning error answers into
    /// [`APIError`].
    func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let error as URLError {
            throw APIError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected("no HTTP answer")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw APIError.server(
                    status: http.statusCode, code: error.error, message: error.message,
                    offset: error.offset)
            }
            throw APIError.server(
                status: http.statusCode, code: "http_\(http.statusCode)",
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode), offset: nil)
        }
        return (data, http)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.unexpected("\(T.self): \(error)")
        }
    }

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await send(request("GET", path, query: query))
        return try decode(T.self, from: data)
    }

    public func call<T: Decodable>(_ method: String, _ path: String, json body: some Encodable) async throws -> T {
        var request = request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request, body: try JSONEncoder().encode(body))
        return try decode(T.self, from: data)
    }

    // MARK: The routes the app uses

    public func serverInfo() async throws -> ServerInfo {
        try await get("server")
    }

    public func login(username: String, password: String, device: DeviceDescription) async throws -> SignedIn {
        struct Body: Encodable {
            var username: String
            var password: String
            var device: DeviceDescription
        }
        return try await call("POST", "auth/login", json: Body(username: username, password: password, device: device))
    }

    public func pair(code: String, device: DeviceDescription) async throws -> SignedIn {
        struct Body: Encodable {
            var code: String
            var device: DeviceDescription
        }
        return try await call("POST", "auth/pair", json: Body(code: code, device: device))
    }

    public func logout() async throws {
        var request = request("POST", "auth/logout")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request, body: Data("{}".utf8))
    }

    public func me() async throws -> Me {
        try await get("me")
    }

    public func sync(since: Int64, limit: Int = 500) async throws -> SyncPage {
        try await get(
            "sync",
            query: [
                URLQueryItem(name: "since", value: String(since)),
                URLQueryItem(name: "limit", value: String(limit)),
            ])
    }

    public func announce(_ upload: UploadRequest) async throws -> UploadState {
        try await call("POST", "uploads", json: upload)
    }

    public func uploadState(_ id: String) async throws -> UploadState {
        try await get("uploads/\(id)")
    }

    /// Sends one piece of an upload, starting at `offset`.
    public func send(upload id: String, offset: Int64, piece: Data) async throws -> UploadState {
        var request = request("PATCH", "uploads/\(id)")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let (data, _) = try await send(request, body: piece)
        return try decode(UploadState.self, from: data)
    }

    /// The request for the rest of an upload from `offset`, for a session that sends it from a
    /// file (in the background).
    func restRequest(upload id: String, offset: Int64) -> URLRequest {
        var request = request("PATCH", "uploads/\(id)")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    public func complete(upload id: String) async throws -> UploadState {
        try await call("POST", "uploads/\(id)/complete", json: Empty())
    }

    /// Sends a thumbnail, preview or rendered `live_effect` file the phone made.
    public func put(
        file data: Data, role: String, asset: String, mimeType: String, sha256: String, width: Int, height: Int
    ) async throws -> Asset {
        var request = request("PUT", "assets/\(asset)/files/\(role)")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "Halden-Sha256")
        request.setValue(String(width), forHTTPHeaderField: "Halden-Width")
        request.setValue(String(height), forHTTPHeaderField: "Halden-Height")
        let (body, _) = try await send(request, body: data)
        return try decode(Asset.self, from: body)
    }

    /// Removes a derived file (currently `live_effect`) from the server.
    @discardableResult
    public func deleteDerived(role: String, asset: String) async throws -> Asset {
        let (body, _) = try await send(request("DELETE", "assets/\(asset)/files/\(role)"))
        return try decode(Asset.self, from: body)
    }

    /// Up to 500 thumbnails (or previews) in one answer, by asset id.
    public func thumbnails(of ids: [String], role: String = "thumbnail") async throws -> [String: Data] {
        struct Body: Encodable {
            var ids: [String]
            var role: String
        }
        var request = request("POST", "thumbnails")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request, body: try JSONEncoder().encode(Body(ids: ids, role: role)))
        return try BulkFiles.parse(data)
    }

    public func trash(_ ids: [String]) async throws -> Int {
        try await changed("assets/trash", ids)
    }

    public func restore(_ ids: [String]) async throws -> Int {
        try await changed("assets/restore", ids)
    }

    /// Deletes for good, only assets that are in the trash.
    public func deleteForGood(_ ids: [String]) async throws -> Int {
        try await changed("assets/delete", ids)
    }

    /// Everything about one asset: original values, EXIF, corrections.
    public func detail(_ id: String) async throws -> AssetDetail {
        try await get("assets/\(id)")
    }

    /// Photos and videos without a place, newest first, each with a suggestion.
    public func withoutPlace(before: Int64? = nil, limit: Int = 200) async throws -> [AssetWithoutPlace] {
        struct Page: Decodable { var assets: [AssetWithoutPlace] }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        let page: Page = try await get("assets/without-location", query: query)
        return page.assets
    }

    /// Suggested place for one asset (nearest photo in time within the server's window).
    public func locationSuggestion(for id: String) async throws -> PlaceSuggestion? {
        struct Answer: Decodable { var suggestion: PlaceSuggestion? }
        let answer: Answer = try await get("assets/\(id)/location-suggestion")
        return answer.suggestion
    }

    /// A file of an asset (`original`, `preview`, `converted`, …) downloaded to `destination`,
    /// without holding it in memory. Returns its type.
    @discardableResult
    public func download(asset id: String, role: String, to destination: URL) async throws -> String? {
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request("GET", "assets/\(id)/files/\(role)"))
        } catch let error as URLError {
            throw APIError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.server(
                status: status, code: "http_\(status)", message: "The file could not be fetched.", offset: nil)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return http.mimeType
    }

    /// A part of a file: `length` bytes from `offset` (to the end with `nil`). Returns the bytes,
    /// the whole file's size and its type.
    public func range(
        asset id: String, role: String, offset: Int64, length: Int64?
    ) async throws -> (data: Data, total: Int64, mimeType: String) {
        var request = request("GET", "assets/\(id)/files/\(role)")
        let end = length.map { String(offset + $0 - 1) } ?? ""
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await send(request)
        let mimeType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        // "bytes 0-99/1234"
        let total =
            response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
            ?? Int64(data.count)
        return (data, total, mimeType)
    }

    /// One asset as it is now (`GET /assets/{id}`).
    public func asset(_ id: String) async throws -> Asset {
        try await get("assets/\(id)")
    }

    public func correct(_ id: String, _ correction: AssetCorrection) async throws -> Asset {
        try await call("PATCH", "assets/\(id)", json: correction)
    }

    /// One place for many photos.
    public func setLocation(_ ids: [String], _ location: CorrectedLocation) async throws -> Int {
        struct Body: Encodable {
            var ids: [String]
            var location: CorrectedLocation
        }
        struct Answer: Decodable { var changed: Int }
        let answer: Answer = try await call("POST", "assets/location", json: Body(ids: ids, location: location))
        return answer.changed
    }

    private func changed(_ path: String, _ ids: [String]) async throws -> Int {
        struct Body: Encodable { var ids: [String] }
        struct Answer: Decodable { var changed: Int }
        let answer: Answer = try await call("POST", path, json: Body(ids: ids))
        return answer.changed
    }
}

/// An empty JSON object, for requests and answers without content.
public struct Empty: Codable, Sendable {
    public init() {}
}

/// The binary answer of `POST /thumbnails`: per entry 16 bytes asset UUID, 4 bytes big-endian
/// length (0: no such file), then the file.
public enum BulkFiles {
    public static func parse(_ data: Data) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var at = data.startIndex
        while at < data.endIndex {
            guard data.endIndex - at >= 20 else { throw APIError.unexpected("cut-off thumbnail list") }
            let idBytes = data[at..<at + 16]
            let uuid = idBytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            let length = data[at + 16..<at + 20].reduce(0) { ($0 << 8) | Int($1) }
            at += 20
            guard data.endIndex - at >= length else { throw APIError.unexpected("cut-off thumbnail") }
            if length > 0 {
                files[uuid.uuidString.lowercased()] = Data(data[at..<at + length])
            }
            at += length
        }
        return files
    }
}
