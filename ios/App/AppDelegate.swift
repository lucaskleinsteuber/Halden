import BackgroundTasks
import HaldenKit
import UIKit

/// The parts of the app's life SwiftUI doesn't cover: the system waking Halden for finished
/// background uploads, and background time for uploading.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let processingTask = "com.lucas.halden.ios.upload"

    /// Made with the delegate, so it exists also when the system starts Halden in the
    /// background.
    let model = AppModel.make()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let model = model
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTask, using: nil) { task in
            let work = Task { @MainActor in
                await model.backgroundWork()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        return true
    }

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploads.identifier else { return completionHandler() }
        let done = Carry(value: completionHandler)
        model.background.handleEvents { DispatchQueue.main.async { done.value() } }
    }

    /// Asks for background time to upload, when uploads are waiting.
    @MainActor
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTask)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }
}
