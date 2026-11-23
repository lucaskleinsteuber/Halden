import HaldenKit
import SwiftUI

/// Before pairing: connect to a server. After: camera, photos, settings.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.connection == nil {
            OnboardingView()
        } else {
            TabView {
                Tab("Camera", systemImage: "camera") { CameraView() }
                Tab("Photos", systemImage: "photo.on.rectangle") { PhotosView() }
                Tab("Settings", systemImage: "gear") { SettingsView() }
            }
        }
    }
}
