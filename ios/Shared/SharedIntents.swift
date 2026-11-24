import ActivityKit
import AppIntents
import Foundation

/// The Live Activity while photos and videos go up: "12 of 40" on the Lock Screen and in the
/// Dynamic Island.
struct UploadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var done: Int
        var total: Int
        /// Why uploads wait right now (no network, videos wait for Wi-Fi); `nil` while they go.
        var waiting: String?
    }

    var serverName: String
}

/// Opens Halden's camera: from a control in Control Center, on the Lock Screen or on the Action
/// button. On a locked iPhone the system starts Halden's lock-screen camera instead of the app.
struct HaldenCameraIntent: CameraCaptureIntent {
    typealias AppContext = HaldenCaptureContext

    static let title: LocalizedStringResource = "Halden Camera"
    static let description = IntentDescription("Takes photos and videos with Halden.")

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .haldenOpenCamera, object: nil)
        return .result()
    }
}

struct HaldenCaptureContext: Codable, Sendable {}

extension Notification.Name {
    /// The app shows its camera.
    static let haldenOpenCamera = Notification.Name("halden.open-camera")
}
