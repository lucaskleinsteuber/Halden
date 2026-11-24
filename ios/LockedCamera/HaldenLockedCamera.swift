import ExtensionKit
import HaldenKit
import LockedCameraCapture
import SwiftUI

@main
struct HaldenLockedCamera: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCameraView(session: session)
        }
    }
}

/// Halden's camera on a locked iPhone, started from the Lock Screen or Control Center. It may
/// only keep what it takes in the folder the system gives it; Halden takes everything over and
/// uploads it the next time it runs.
struct LockedCameraView: View {
    let session: LockedCameraCaptureSession
    @State private var camera = CameraModel.make(standIn: false)
    @State private var settings = AppSettings()
    @State private var taken = 0

    var body: some View {
        CameraScreen(camera: camera, settings: settings) { change in
            change(&settings)
        } gallery: {
            // Where the app shows the last photo: once something was taken, a way into Halden.
            if taken > 0 {
                Button {
                    Task {
                        try? await session.openApplication(
                            for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture))
                    }
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.15), in: .rect(cornerRadius: 8))
                }
                .accessibilityLabel("Open Halden")
            }
        }
        .onAppear {
            let folder = session.sessionContentURL
            camera.settings = { settings }
            camera.keepPhoto = { photo, metadata in
                if (try? LockedCaptures.save(
                    photo: photo.data, heic: photo.heic, liveVideo: photo.liveVideo, metadata: metadata,
                    into: folder))
                    != nil
                {
                    taken += 1
                }
            }
            camera.keepVideo = { url, metadata in
                if (try? LockedCaptures.save(video: url, metadata: metadata, into: folder)) != nil { taken += 1 }
            }
            camera.prepare()
        }
    }
}
