import HaldenWatchProtocol
import SwiftUI

/// Apple Watch camera remote: live viewfinder from iPhone, Digital Crown zoom, shutter,
/// 3-second timer, camera flip, and instant post-capture photo preview.
struct WatchCameraView: View {
    @Bindable var model: WatchSessionModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.state.cameraOpen {
                liveViewfinder
            } else {
                waitingForiPhone
            }
        }
        .sheet(isPresented: $model.showingLastPhoto) {
            lastPhotoSheet
        }
    }

    private var liveViewfinder: some View {
        ZStack {
            if let image = model.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .accessibilityIdentifier("watch-preview")
            } else {
                Color.black.ignoresSafeArea()
                    .overlay {
                        ProgressView().tint(.yellow)
                    }
            }

            if let count = model.state.countdown {
                Text("\(count)")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .accessibilityIdentifier("watch-countdown")
            }

            VStack {
                HStack {
                    Text(WatchCrownZoom.label(for: model.state.zoom))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: .capsule)
                        .accessibilityIdentifier("watch-zoom")
                    Spacer()
                    if let thumb = model.lastPhotoImage {
                        Button {
                            model.showingLastPhoto = true
                        } label: {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(.rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Last photo")
                        .accessibilityIdentifier("watch-last-thumb")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        model.send(.timer3s)
                    } label: {
                        Text("3s")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.65), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("3 second timer")
                    .accessibilityIdentifier("watch-timer-3s")

                    Button {
                        model.send(.shutter)
                    } label: {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 3).frame(width: 52, height: 52)
                            if model.state.isRecording {
                                RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 22, height: 22)
                            } else {
                                Circle().fill(.white).frame(width: 42, height: 42)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.state.isRecording ? "Stop recording" : "Take photo")
                    .accessibilityIdentifier("watch-shutter")

                    Button {
                        model.send(.flipCamera)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption.bold())
                            .foregroundStyle(model.state.isFront ? .yellow : .white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.65), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Flip camera")
                    .accessibilityIdentifier("watch-flip")
                }
                .padding(.bottom, 6)
            }
        }
        .focusable()
        .digitalCrownRotation(
            Binding(
                get: { model.crownZoom },
                set: { newValue in
                    model.crownZoom = newValue
                    model.updateZoomFromCrown(newValue)
                }),
            from: model.state.minZoom,
            through: model.state.maxZoom,
            by: 0.1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
    }

    private var waitingForiPhone: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.title2)
                .foregroundStyle(.yellow)
            Text("Open Halden on your iPhone")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier("watch-waiting")
    }

    private var lastPhotoSheet: some View {
        VStack(spacing: 8) {
            if let image = model.lastPhotoImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityIdentifier("watch-last-photo")
            }
            Button("Done") {
                model.showingLastPhoto = false
            }
            .accessibilityIdentifier("watch-last-done")
        }
        .padding(8)
    }
}
