import HaldenKit
import SwiftUI

/// The app's camera tab: the whole screen, without the tab bar, like Apple's camera. The way to
/// the library is the last photo left of the shutter.
struct CameraView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        CameraScreen(camera: app.camera, settings: app.settings) { change in
            app.update(change)
        } gallery: {
            LastPhotoButton(camera: app.camera)
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Left of the shutter: the newest photo or video. A tap shows it full screen, from where "All
/// Photos" leads to the library; with no photos yet it leads there at once.
private struct LastPhotoButton: View {
    @Environment(AppModel.self) private var app
    let camera: CameraModel
    @State private var picture: CGImage?
    @State private var shown: Shown?

    private struct Shown: Identifiable {
        let id: String
    }

    /// How often a missing picture is looked for again (the thumbnail may still be on its way).
    private static let attempts = 6

    var body: some View {
        let newest = app.library.first
        Button {
            if let newest {
                shown = Shown(id: newest.id)
            } else {
                app.showPhotos()
            }
        } label: {
            ZStack {
                Color.white.opacity(0.12)
                if let image = camera.lastShot ?? picture {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else if newest == nil {
                    Image(systemName: "photo.on.rectangle").font(.title3).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.5), lineWidth: 1))
        }
        .accessibilityLabel(newest == nil ? "Photos" : "Last photo")
        .accessibilityValue(camera.lastShot ?? picture == nil ? "" : "shown")
        .accessibilityIdentifier("last-photo")
        .task(id: newest.map { "\($0.id) \($0.thumbnailSha256 ?? "") \(app.libraryVersion)" }) {
            guard let newest else {
                picture = nil
                return
            }
            // Its thumbnail, else its own file on this iPhone; tried again for a while, since a
            // new photo's thumbnail may still be in the making.
            for attempt in 0..<Self.attempts {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                if Task.isCancelled { return }
                if let image = await picture(of: newest) {
                    withAnimation(.easeOut(duration: 0.2)) { picture = image }
                    camera.forgetLastShot()
                    return
                }
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
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("All Photos") {
                                self.shown = nil
                                app.showPhotos()
                            }
                            .accessibilityIdentifier("all-photos")
                        }
                    }
            }
            // The camera's white controls must not color the photo screen.
            .tint(Color.accentColor)
            .foregroundStyle(Color.primary)
        }
    }

    private func picture(of asset: LocalAsset) async -> CGImage? {
        if let image = await app.pipeline.image(for: asset, pixels: 160) { return image.cgImage }
        guard let local = app.media.localOriginal(of: asset), !asset.isVideo else { return nil }
        let edit = asset.edit
        return await Task.detached(priority: .userInitiated) {
            ImagePipeline.decode(local, pixels: 160, edit: edit)?.cgImage
        }.value
    }
}
