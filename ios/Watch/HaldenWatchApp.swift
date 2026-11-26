import SwiftUI

@main
struct HaldenWatchApp: App {
    @State private var session = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchCameraView(model: session)
        }
    }
}
