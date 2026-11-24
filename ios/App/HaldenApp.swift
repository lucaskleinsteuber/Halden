import SwiftUI

@main
struct HaldenApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .onChange(of: phase) { _, now in
                    switch now {
                    case .active: delegate.model.refresh()
                    case .background: delegate.model.enterBackground()
                    default: break
                    }
                }
        }
    }
}
