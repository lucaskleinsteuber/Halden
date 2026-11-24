import HaldenKit
import Network

/// Tells which network the phone is on, and every time that changes.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private(set) var situation = NetworkSituation(kind: .wifi)
    var changed: ((NetworkSituation) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let situation = Self.situation(of: path)
            Task { @MainActor in
                guard let self, self.situation != situation else { return }
                self.situation = situation
                self.changed?(situation)
            }
        }
        monitor.start(queue: DispatchQueue(label: "halden.network"))
    }

    nonisolated static func situation(of path: NWPath) -> NetworkSituation {
        guard path.status == .satisfied else { return .offline }
        let kind: NetworkSituation.Kind =
            if path.usesInterfaceType(.wifi) {
                .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                .wired
            } else if path.usesInterfaceType(.cellular) {
                .cellular
            } else {
                .other
            }
        return NetworkSituation(kind: kind, expensive: path.isExpensive, constrained: path.isConstrained)
    }
}
