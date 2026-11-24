import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct HaldenWidgets: WidgetBundle {
    var body: some Widget {
        UploadLiveActivity()
        HaldenCameraControl()
    }
}

/// "12 of 40 uploaded" on the Lock Screen and in the Dynamic Island.
struct UploadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UploadActivityAttributes.self) { context in
            UploadProgressView(state: context.state, server: context.attributes.serverName)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.done) of \(context.state.total)").monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading) {
                        ProgressView(value: Double(context.state.done), total: Double(max(context.state.total, 1)))
                        if let waiting = context.state.waiting {
                            Text(waiting).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.up.circle.fill")
            } compactTrailing: {
                Text("\(context.state.done)/\(context.state.total)").monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.up.circle.fill")
            }
        }
    }
}

struct UploadProgressView: View {
    let state: UploadActivityAttributes.ContentState
    let server: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: state.done == state.total ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                Text(state.done == state.total ? "All uploaded to \(server)" : "Uploading to \(server)")
                    .font(.headline)
                Spacer()
                Text("\(state.done) of \(state.total)").monospacedDigit()
            }
            ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
            if let waiting = state.waiting {
                Text(waiting).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A control for Control Center, the Lock Screen and the Action button that opens Halden's
/// camera, without unlocking.
struct HaldenCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.lucas.halden.ios.camera") {
            ControlWidgetButton(action: HaldenCameraIntent()) {
                Label("Halden", systemImage: "camera.aperture")
            }
        }
        .displayName("Halden Camera")
        .description("Opens Halden's camera, also on a locked iPhone.")
    }
}
