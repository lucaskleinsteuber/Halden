import HaldenKit
import SwiftUI

/// The app's camera tab.
struct CameraView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        CameraScreen(camera: app.camera, settings: app.settings) { change in app.update(change) }
    }
}
