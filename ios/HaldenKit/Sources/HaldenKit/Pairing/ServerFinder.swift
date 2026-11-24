import Foundation
import Network

/// A Halden server announcing itself in the home network.
public struct FoundServer: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The certificate fingerprint it announced. Finding is not trusting: signing in still shows
    /// it to compare.
    public var fingerprint: String
    public var address: String
    public var port: Int

    /// From the Bonjour text record (`id`, `fp`, `name`) and where the service answered.
    public static func from(text: [String: String], address: String, port: Int) -> FoundServer? {
        guard let id = text["id"], let fingerprint = text["fp"], Fingerprint.isValid(fingerprint) else { return nil }
        return FoundServer(
            id: id, name: text["name"] ?? "Halden", fingerprint: fingerprint.lowercased(), address: address, port: port)
    }
}

/// Finds Halden servers in the home network (Bonjour, `_halden._tcp`) and where they answer.
public final class ServerFinder: @unchecked Sendable {
    public static let serviceType = "_halden._tcp"
    private let queue = DispatchQueue(label: "halden.finder")
    private var browser: NWBrowser?
    private var found: [String: FoundServer] = [:]
    private var resolving: [NWConnection] = []
    /// Called on the main thread with every server found so far.
    public var changed: (@MainActor @Sendable ([FoundServer]) -> Void)?

    public init() {}

    public func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results { self?.resolve(result) }
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    public func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            for connection in resolving { connection.cancel() }
            resolving = []
        }
    }

    /// Connects once to learn the address and port behind the service name.
    private func resolve(_ result: NWBrowser.Result) {
        guard case .bonjour(let record) = result.metadata else { return }
        let text = record.dictionary
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                    let server = FoundServer.from(text: text, address: Self.text(host), port: Int(port.rawValue))
                {
                    found[server.id] = server
                    let all = found.values.sorted { $0.name < $1.name }
                    let changed = changed
                    DispatchQueue.main.async { MainActor.assumeIsolated { changed?(all) } }
                }
                connection.cancel()
            case .failed, .cancelled:
                resolving.removeAll { $0 === connection }
            default:
                break
            }
        }
        resolving.append(connection)
        connection.start(queue: queue)
    }

    static func text(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }
}
