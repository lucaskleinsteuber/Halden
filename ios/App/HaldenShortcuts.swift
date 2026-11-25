import AppIntents
import Foundation

/// Siri and Shortcuts intent: open Halden's camera and take a photo after a 3-second countdown.
struct TakePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Photo"
    static let description = IntentDescription("Opens Halden in photo mode and takes a photo after 3 seconds.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .haldenCameraAction, object: nil,
            userInfo: ["mode": "photo", "front": false, "delay": 3])
        return .result()
    }
}

/// Siri and Shortcuts intent: open Halden's camera and start recording video after 3 seconds.
struct RecordVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Video"
    static let description = IntentDescription("Opens Halden in video mode and starts recording after 3 seconds.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .haldenCameraAction, object: nil,
            userInfo: ["mode": "video", "front": false, "delay": 3])
        return .result()
    }
}

/// Siri and Shortcuts intent: open Halden's front camera and take a selfie after 3 seconds.
struct TakeSelfieIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Selfie"
    static let description = IntentDescription("Opens Halden on the front camera and takes a selfie after 3 seconds.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .haldenCameraAction, object: nil,
            userInfo: ["mode": "photo", "front": true, "delay": 3])
        return .result()
    }
}

/// Exposes voice phrases for Siri and the Shortcuts app.
struct HaldenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TakePhotoIntent(),
            phrases: [
                "Take a photo with \(.applicationName)",
                "Take a picture with \(.applicationName)",
            ],
            shortTitle: "Take a Photo",
            systemImageName: "camera"
        )
        AppShortcut(
            intent: RecordVideoIntent(),
            phrases: [
                "Record a video with \(.applicationName)",
                "Start recording with \(.applicationName)",
            ],
            shortTitle: "Record a Video",
            systemImageName: "video"
        )
        AppShortcut(
            intent: TakeSelfieIntent(),
            phrases: [
                "Take a selfie with \(.applicationName)"
            ],
            shortTitle: "Take a Selfie",
            systemImageName: "camera.rotate"
        )
    }
}

extension Notification.Name {
    /// Opens Halden's camera in a specific mode / side and starts a short countdown.
    static let haldenCameraAction = Notification.Name("halden.camera-action")
}
