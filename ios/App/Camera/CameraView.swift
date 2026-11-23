import AVFoundation
import HaldenKit
import SwiftUI

struct CameraView: View {
    @Environment(AppModel.self) private var app
    @State private var camera = CameraModel()
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.available {
                CameraPreview(session: camera.session).ignoresSafeArea()
            } else {
                Text(camera.lastProblem ?? "There is no camera here.")
                    .foregroundStyle(.white)
                    .padding()
                    .accessibilityIdentifier("no-camera")
            }
            VStack {
                Spacer()
                Button {
                    camera.capture()
                    flash = true
                    withAnimation(.easeOut(duration: 0.2)) { flash = false }
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(.white.opacity(0.9)).padding(6))
                        .frame(width: 74, height: 74)
                }
                .accessibilityLabel("Take a photo")
                .accessibilityIdentifier("shutter")
                .disabled(!camera.available)
                .padding(.bottom, 24)
            }
            Color.black.opacity(flash ? 0.6 : 0).ignoresSafeArea().allowsHitTesting(false)
        }
        .onAppear {
            camera.keep = { data, heic, metadata in
                app.keep(
                    photo: data, fileExtension: heic ? "heic" : "jpg",
                    mimeType: heic ? "image/heic" : "image/jpeg", metadata: metadata)
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
}

/// The camera's picture, full screen.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
