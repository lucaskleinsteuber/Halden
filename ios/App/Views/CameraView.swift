import HaldenKit
import SwiftUI

/// The app's camera tab. Instead of the system tab bar (which took 83 points of the screen) it
/// has its own slim one, icons only, that fades away while recording. The last photo left of
/// the shutter opens full screen with "All Photos" to the library.
struct CameraView: View {
    @Environment(AppModel.self) private var app
    @State private var watchBridge = WatchCameraBridge()

    var body: some View {
        CameraScreen(camera: app.camera, settings: app.settings) { change in
            app.update(change)
        } gallery: {
            LastPhotoButton(camera: app.camera)
        }
        // Room for the slim tab bar beyond the home indicator's own space.
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: CameraTabBar.extraHeight) }
        .overlay(alignment: .bottom) {
            CameraTabBar(capturing: capturing) {
                app.showPhotos()
            } settings: {
                app.showSettings()
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear { watchBridge.attach(to: app.camera) }
        .onDisappear { watchBridge.detach() }
        .onChange(of: app.camera.lastShot) { _, image in
            if let image { watchBridge.sendLastPhoto(image) }
        }
        .onChange(of: app.camera.mode) { _, _ in watchBridge.sendState() }
        .onChange(of: app.camera.recording) { _, _ in watchBridge.sendState() }
        .onChange(of: app.camera.countdown) { _, _ in watchBridge.sendState() }
        .onChange(of: app.camera.dualSwapped) { _, _ in watchBridge.sendState() }
        .onChange(of: app.camera.backend.state.side) { _, _ in watchBridge.sendState() }
        .onChange(of: app.camera.backend.state.zoomRange) { _, _ in watchBridge.sendState() }
    }
}

extension CameraView {
    /// While something is being recorded, the tab bar steps aside.
    private var capturing: Bool {
        let camera = app.camera
        return camera.recording || camera.countdown != nil || camera.isPanoramaCapturing || camera.burstCount > 0
            || camera.isNightCapturing
    }
}

/// The camera's own tab bar: three symbols, no labels, 44 points high just above the home
/// indicator. The camera tab is the one shown.
struct CameraTabBar: View {
    /// Points the bar needs beyond the bottom safe area.
    static let extraHeight: CGFloat = 18
    let capturing: Bool
    let photos: () -> Void
    let settings: () -> Void

    var body: some View {
        ZStack {
            // Gone while recording (not only invisible), so nothing can tap or read it.
            if !capturing {
                HStack(spacing: 0) {
                    item("camera.fill", label: "Camera", selected: true, id: "camera-tab-camera") {}
                    item(
                        "photo.on.rectangle", label: "Photos", selected: false, id: "camera-tab-photos",
                        action: photos)
                    item("gear", label: "Settings", selected: false, id: "camera-tab-settings", action: settings)
                }
                .padding(.horizontal, 6)
                .frame(height: 44)
                .background(.white.opacity(0.1), in: .capsule)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("camera-tab-bar")
            }
        }
        .frame(height: 44)
        .padding(.bottom, 6)
        .animation(.easeOut(duration: 0.2), value: capturing)
        .ignoresSafeArea(edges: .bottom)
    }

    private func item(
        _ symbol: String, label: String, selected: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? .yellow : .white.opacity(0.85))
                .frame(width: 64, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
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
                    // The same photo as the one shown already: swapped without a second animation.
                    picture = image
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
