import ActivityKit
import Foundation
import HaldenKit

/// "12 of 40 uploaded" on the Lock Screen and in the Dynamic Island while a bigger round of
/// uploads goes (not for a single photo that is up a second later), and whenever uploads are
/// still waiting when Halden leaves the screen.
@MainActor
final class UploadActivity {
    private var activity: Activity<UploadActivityAttributes>?

    init() {
        // One left over from before the app was closed.
        activity = Activity<UploadActivityAttributes>.activities.first
    }

    /// - Parameter leaving: the app is going to the background.
    func show(_ summary: UploadSummary, waiting: String?, server: String, leaving: Bool = false) {
        let state = UploadActivityAttributes.ContentState(
            done: summary.done, total: summary.total, waiting: waiting)
        let content = ActivityContent(state: state, staleDate: nil)
        guard summary.waiting > 0 else {
            if let activity {
                self.activity = nil
                // `Activity` isn't marked `Sendable`; it is only handed on, never shared.
                let ending = Carry(value: activity)
                Task.detached {
                    await ending.value.end(content, dismissalPolicy: .after(Date.now.addingTimeInterval(60)))
                }
            }
            return
        }
        if let activity {
            let updating = Carry(value: activity)
            Task.detached { await updating.value.update(content) }
            return
        }
        let big = summary.waiting >= 5 || summary.bytesTotal - summary.bytesSent >= 50 << 20
        guard big || leaving, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(
            attributes: UploadActivityAttributes(serverName: server), content: content, pushType: nil)
    }
}
