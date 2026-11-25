import HaldenKit
import LockedCameraCapture
import SwiftUI

/// Before pairing: connect to a server. After: camera, photos, settings.
struct RootView: View {
    enum Screen: Hashable {
        case camera, photos, settings
    }

    @Environment(AppModel.self) private var model
    @State private var screen = Screen.camera

    var body: some View {
        Group {
            if model.connection == nil {
                OnboardingView()
            } else {
                TabView(selection: $screen) {
                    Tab("Camera", systemImage: "camera", value: .camera) { CameraView() }
                    Tab("Photos", systemImage: "photo.on.rectangle", value: .photos) { PhotosView() }
                    Tab("Settings", systemImage: "gear", value: .settings) { SettingsView() }
                }
            }
        }
        .onChange(of: model.cameraRequests) { screen = .camera }
        .onChange(of: model.photosRequests) { screen = .photos }
        // The camera control, or "Open Halden" in the lock-screen camera.
        .onReceive(NotificationCenter.default.publisher(for: .haldenOpenCamera)) { _ in model.showCamera() }
        .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { _ in model.showCamera() }
    }
}
