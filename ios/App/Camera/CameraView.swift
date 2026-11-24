import HaldenKit
import SwiftUI
import UIKit

/// The camera screen. No design yet: the system's controls, everything there and working.
struct CameraView: View {
    @Environment(AppModel.self) private var app
    @State private var focusPoint: CGPoint?
    @State private var flash = false

    private var camera: CameraModel { app.camera }
    private var state: CameraState { camera.backend.state }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if state.ready {
                CameraPreviewHost(
                    preview: camera.backend.previewView,
                    tap: { point in
                        focusPoint = point
                        camera.backend.focus(at: point, lock: false)
                    },
                    hold: { point in
                        focusPoint = point
                        camera.backend.focus(at: point, lock: true)
                    },
                    pinch: { scale, began in
                        if began { pinchStart = state.zoom }
                        camera.backend.zoom(to: pinchStart * scale, smoothly: false)
                    }
                )
                .ignoresSafeArea()
                // In the same place as the picture, so a tap and its square line up.
                .overlay {
                    if app.settings.showGrid { ThirdsGrid().allowsHitTesting(false) }
                    if let focusPoint {
                        Rectangle()
                            .strokeBorder(.yellow, lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                            .position(focusPoint)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("camera-preview")
            } else {
                Text(state.problem ?? "Starting the camera…")
                    .foregroundStyle(.white)
                    .padding()
                    .accessibilityIdentifier("no-camera")
            }
            controls
            if let left = camera.countdown {
                Text("\(left)")
                    .font(.system(size: 120, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("countdown")
            }
            Color.black.opacity(flash ? 0.6 : 0).ignoresSafeArea().allowsHitTesting(false)
        }
        .onAppear { camera.appear() }
        .onDisappear { camera.disappear() }
        .onChange(of: camera.shots) {
            flash = true
            withAnimation(.easeOut(duration: 0.2)) { flash = false }
        }
        .task(id: focusPoint) {
            guard focusPoint != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !state.focusLocked { focusPoint = nil }
        }
    }

    @State private var pinchStart = 1.0

    private var controls: some View {
        VStack(spacing: 14) {
            topBar
            Spacer()
            if let problem = camera.problem {
                Text(problem).font(.footnote).foregroundStyle(.yellow)
            }
            zoomButtons
            Picker("Mode", selection: Binding(get: { camera.mode }, set: { camera.switchTo($0) })) {
                Text("Photo").tag(CameraMode.photo)
                Text("Video").tag(CameraMode.video)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(camera.recording)
            .accessibilityIdentifier("camera-mode")
            HStack {
                Color.clear.frame(width: 50, height: 50)
                Spacer()
                shutterButton
                Spacer()
                Button {
                    camera.backend.flip()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .frame(width: 50, height: 50)
                }
                .disabled(!state.canFlip || camera.recording)
                .accessibilityLabel("Switch camera")
                .accessibilityIdentifier("flip-camera")
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var topBar: some View {
        HStack(spacing: 20) {
            if camera.mode == .photo {
                Button {
                    let next: AppSettings.Flash =
                        switch app.settings.flash {
                        case .auto: .on
                        case .on: .off
                        case .off: .auto
                        }
                    app.update { $0.flash = next }
                } label: {
                    Image(systemName: flashSymbol)
                }
                .disabled(!state.hasFlash)
                .accessibilityLabel("Flash \(app.settings.flash.rawValue)")
                .accessibilityIdentifier("flash")
            } else {
                Button {
                    camera.setTorch(!camera.torch)
                } label: {
                    Image(systemName: camera.torch ? "flashlight.on.fill" : "flashlight.off.fill")
                }
                .disabled(!state.hasTorch)
                .accessibilityLabel(camera.torch ? "Light on" : "Light off")
                .accessibilityIdentifier("torch")
            }
            Button {
                camera.timer = camera.timer == 0 ? 3 : camera.timer == 3 ? 10 : 0
            } label: {
                Label(camera.timer == 0 ? "Off" : "\(camera.timer) s", systemImage: "timer")
            }
            .accessibilityLabel(camera.timer == 0 ? "Self-timer off" : "Self-timer \(camera.timer) seconds")
            .accessibilityIdentifier("timer")
            Button {
                app.update { $0.showGrid.toggle() }
            } label: {
                Image(systemName: app.settings.showGrid ? "grid.circle.fill" : "grid.circle")
            }
            .accessibilityLabel(app.settings.showGrid ? "Hide grid" : "Show grid")
            .accessibilityIdentifier("grid")
            Spacer()
            if state.focusLocked {
                Text("AE/AF LOCK")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .background(.yellow, in: .rect(cornerRadius: 4))
                    .foregroundStyle(.black)
            }
            if let since = camera.recordingSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(
                        Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond))
                    )
                    .font(.body.monospacedDigit())
                    .padding(.horizontal, 6)
                    .background(.red, in: .rect(cornerRadius: 4))
                }
                .accessibilityIdentifier("recording-time")
            } else if camera.mode == .video, let format = state.videoFormat {
                Text(format).font(.caption)
            }
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var flashSymbol: String {
        switch app.settings.flash {
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        case .off: "bolt.slash"
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 10) {
            ForEach(state.presets, id: \.self) { preset in
                let next = state.presets.first { $0 > preset + 0.01 } ?? .infinity
                let active = state.zoom >= preset - 0.01 && state.zoom < next - 0.01
                Button {
                    camera.backend.zoom(to: preset, smoothly: true)
                } label: {
                    Text(active ? Self.zoomText(state.zoom) + "×" : Self.zoomText(preset))
                        .font(.footnote.bold().monospacedDigit())
                        .foregroundStyle(active ? .yellow : .white)
                        .frame(width: active ? 44 : 34, height: active ? 44 : 34)
                        .background(.black.opacity(0.45), in: .circle)
                }
                .accessibilityLabel("Zoom \(Self.zoomText(preset))")
                .accessibilityIdentifier("zoom-\(Self.zoomText(preset))")
            }
        }
    }

    static func zoomText(_ factor: Double) -> String {
        let rounded = (factor * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    private var shutterButton: some View {
        Button {
            camera.shutter()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 74, height: 74)
                if camera.mode == .video {
                    RoundedRectangle(cornerRadius: camera.recording ? 6 : 30)
                        .fill(.red)
                        .frame(width: camera.recording ? 30 : 60, height: camera.recording ? 30 : 60)
                } else {
                    Circle().fill(.white.opacity(0.9)).frame(width: 62, height: 62)
                }
            }
        }
        .disabled(!state.ready)
        .accessibilityLabel(
            camera.countdown != nil
                ? "Stop the self-timer"
                : camera.mode == .photo ? "Take a photo" : camera.recording ? "Stop recording" : "Record a video"
        )
        .accessibilityIdentifier("shutter")
    }
}

/// Lines in thirds, to line up a picture.
struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for third in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geometry.size.width * third, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * third, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * third))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * third))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

/// Puts the camera's picture on screen and turns touches into focus and zoom: tap to focus,
/// hold to lock focus and exposure, pinch to zoom.
struct CameraPreviewHost: UIViewRepresentable {
    let preview: UIView
    let tap: (CGPoint) -> Void
    let hold: (CGPoint) -> Void
    /// The scale since the pinch began, and whether it just began.
    let pinch: (Double, Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        preview.frame = host.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(preview)
        let coordinator = context.coordinator
        host.addGestureRecognizer(
            UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:))))
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        press.minimumPressDuration = 0.6
        host.addGestureRecognizer(press)
        host.addGestureRecognizer(
            UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:))))
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        context.coordinator.parent = self
        if preview.superview !== host {
            preview.frame = host.bounds
            host.addSubview(preview)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CameraPreviewHost

        init(parent: CameraPreviewHost) {
            self.parent = parent
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            parent.tap(gesture.location(in: gesture.view))
        }

        @objc func held(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { parent.hold(gesture.location(in: gesture.view)) }
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: parent.pinch(Double(gesture.scale), true)
            case .changed: parent.pinch(Double(gesture.scale), false)
            default: break
            }
        }
    }
}
