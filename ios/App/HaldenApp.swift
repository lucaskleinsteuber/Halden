import SwiftUI

@main
struct HaldenApp: App {
    @State private var model = AppModel.make()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: phase) { _, now in
                    if now == .active { model.refresh() }
                }
        }
    }
}
