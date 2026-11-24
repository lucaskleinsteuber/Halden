import Foundation

/// The network the phone is on right now.
public struct NetworkSituation: Sendable, Equatable {
    public enum Kind: Sendable {
        case none, wifi, wired, cellular, other
    }

    public var kind: Kind
    /// Cellular, or Wi-Fi from another phone's hotspot: costs data volume.
    public var expensive: Bool
    /// Low Data Mode is on.
    public var constrained: Bool

    public init(kind: Kind, expensive: Bool = false, constrained: Bool = false) {
        self.kind = kind
        self.expensive = expensive
        self.constrained = constrained
    }

    public static let offline = NetworkSituation(kind: .none)
}

/// What may be uploaded now.
public struct UploadPermit: Sendable, Equatable {
    public var photos: Bool
    public var videos: Bool

    public init(photos: Bool, videos: Bool) {
        self.photos = photos
        self.videos = videos
    }

    public static let all = UploadPermit(photos: true, videos: true)
    public static let nothing = UploadPermit(photos: false, videos: false)

    public var any: Bool { photos || videos }

    public func allows(mimeType: String) -> Bool {
        mimeType.hasPrefix("video/") ? videos : photos
    }
}

/// The upload settings applied to the network: over cellular or not, videos only on Wi-Fi, only
/// at home.
public enum UploadRules {
    /// - Parameter atHome: the server answers at its home-network address (not over Tailscale).
    public static func permit(on network: NetworkSituation, atHome: Bool, settings: AppSettings) -> UploadPermit {
        guard network.kind != .none else { return .nothing }
        let local = network.kind == .wifi || network.kind == .wired
        if settings.onlyOnHomeNetwork && !(local && atHome) { return .nothing }
        // A hotspot is Wi-Fi, but its data comes from a phone contract.
        let metered = network.kind == .cellular || network.expensive
        if metered && !settings.uploadOverCellular { return .nothing }
        // Videos are big: not over a metered network or in Low Data Mode when so set.
        let videos = !(settings.videosOnlyOnWiFi && (metered || network.constrained))
        return UploadPermit(photos: true, videos: videos)
    }

    /// Why nothing (or no video) goes up right now, in words for the person; `nil` when all may.
    public static func reason(
        for permit: UploadPermit, on network: NetworkSituation, atHome: Bool, settings: AppSettings
    ) -> String? {
        if permit == .all { return nil }
        if network.kind == .none { return "No network." }
        if !permit.any {
            if settings.onlyOnHomeNetwork { return "Waiting for the home Wi-Fi (set in Settings › Uploads)." }
            return "Waiting for Wi-Fi: uploads over cellular are off."
        }
        return network.constrained && !(network.kind == .cellular || network.expensive)
            ? "Videos wait while Low Data Mode is on." : "Videos wait for Wi-Fi."
    }
}

public enum Addresses {
    /// Tailscale gives out `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.
    public static func isTailscale(_ address: String) -> Bool {
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }
}
