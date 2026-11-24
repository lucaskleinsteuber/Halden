import HaldenKit
import SwiftUI

/// The app's camera tab.
struct CameraView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        CameraScreen(camera: app.camera, settings: app.settings) { change in
            app.update(change)
        } gallery: {
            LastPhotoButton()
        }
    }
}

/// Left of the shutter: the newest photo or video; a tap shows it full screen.
private struct LastPhotoButton: View {
    @Environment(AppModel.self) private var app
    @State private var picture: CGImage?
    @State private var shown: Shown?

    private struct Shown: Identifiable {
        let id: String
    }

    var body: some View {
        let newest = app.library.first
        Button {
            shown = newest.map { Shown(id: $0.id) }
        } label: {
            ZStack {
                Color.white.opacity(0.12)
                if let picture {
                    Image(decorative: picture, scale: 1).resizable().scaledToFill()
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.5), lineWidth: 1))
        }
        .disabled(newest == nil)
        .accessibilityLabel("Last photo")
        .accessibilityIdentifier("last-photo")
        .task(id: newest.map { "\($0.id) \($0.thumbnailSha256 ?? "") \(app.libraryVersion)" }) {
            guard let newest else {
                picture = nil
                return
            }
            if let image = await app.pipeline.image(for: newest, pixels: 160) {
                withAnimation(.easeOut(duration: 0.2)) { picture = image.cgImage }
            }
        }
        .fullScreenCover(item: $shown) { shown in
            NavigationStack {
                PhotoView(start: shown.id, assets: app.library)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { self.shown = nil }
                                .accessibilityIdentifier("close-photo")
                        }
                    }
            }
        }
    }
}
