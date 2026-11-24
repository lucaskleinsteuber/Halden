import HaldenKit
import SwiftUI
import UIKit

/// The camera screen, in the app and on the Lock Screen. No design yet, but laid out like Apple's
/// camera: flash and options on top, the picture as it will be taken (4:3 for photos, 16:9 for
/// videos), the zoom buttons over its lower edge, the modes, and the shutter between the last
/// photo and the button that turns the camera around. Nothing moves when the mode changes.
struct CameraScreen<Gallery: View>: View {
    let camera: CameraModel
    let settings: AppSettings
    /// Changes a setting (flash, grid, video format) and keeps it.
    let update: ((inout AppSettings) -> Void) -> Void
    /// Left of the shutter: the last photo in the app, "Open Halden" on the Lock Screen.
    @ViewBuilder let gallery: () -> Gallery

    @State private var focusPoint: CGPoint?
    @State private var flash = false
    @State private var pinchStart = 1.0
    /// While the zoom dial is dragged: the zoom it started at.
    @State private var dialStart: Double?
    @State private var dialShown = false
    @State private var dialTouches = 0

    private var state: CameraState { camera.backend.state }
    static var topBarHeight: CGFloat { 44 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            viewfinder
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

    /// The picture as it will be taken: 4:3 under the top bar for photos, 16:9 in the middle for
    /// videos (like Apple's camera, the controls lie over it).
    @ViewBuilder private var viewfinder: some View {
        let photo = camera.mode == .photo
        Group {
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
                        camera.backend.zoom(
                            to: Zoom.pinched(from: pinchStart, scale: scale, in: state.zoomRange), glide: false)
                    },
                    swipe: { towardsLeft in camera.switchMode(by: towardsLeft ? 1 : -1) }
                )
                // In the same place as the picture, so a tap and its square line up.
                .overlay {
                    if settings.showGrid { ThirdsGrid().allowsHitTesting(false) }
                    if let focusPoint {
                        Rectangle()
                            .strokeBorder(.yellow, lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                            .position(focusPoint)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if state.focusLocked {
                        Text("AE/AF LOCK")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .background(.yellow, in: .rect(cornerRadius: 4))
                            .foregroundStyle(.black)
                            .padding(.top, photo ? 10 : Self.topBarHeight + 70)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("camera-preview")
            } else {
                Text(state.problem ?? "Starting the camera…")
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("no-camera")
            }
        }
        .aspectRatio(photo ? 3.0 / 4.0 : 9.0 / 16.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: photo ? .top : .center)
        .padding(.top, photo ? Self.topBarHeight : 0)
        .ignoresSafeArea(edges: photo ? [] : .all)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if let problem = camera.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .padding(6)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
                    .padding(.bottom, 8)
            }
            zoomControl.frame(height: 64)
            modeStrip.frame(height: 34)
            shutterRow.frame(height: 92)
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 0) {
            lightButton.frame(width: 44, height: 44)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                timerButton.frame(height: 44)
                gridButton.frame(width: 44, height: 44)
                liveButton.frame(width: 44, height: 44)
            }
        }
        .overlay { topMiddle }
        .font(.title3)
        .frame(height: Self.topBarHeight)
        .padding(.horizontal, 12)
        .background(camera.mode == .video ? Color.black.opacity(0.25) : .clear)
    }

    /// Flash for photos, the light for videos.
    @ViewBuilder private var lightButton: some View {
        if camera.mode == .photo {
            Button {
                let next: AppSettings.Flash =
                    switch settings.flash {
                    case .auto: .on
                    case .on: .off
                    case .off: .auto
                    }
                update { $0.flash = next }
            } label: {
                Image(systemName: flashSymbol)
                    .foregroundStyle(settings.flash == .on ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
            .disabled(!state.hasFlash)
            .accessibilityLabel("Flash \(settings.flash.rawValue)")
            .accessibilityIdentifier("flash")
        } else {
            Button {
                camera.setTorch(!camera.torch)
            } label: {
                Image(systemName: camera.torch ? "flashlight.on.fill" : "flashlight.off.fill")
                    .foregroundStyle(camera.torch ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
            .disabled(!state.hasTorch)
            .accessibilityLabel(camera.torch ? "Light on" : "Light off")
            .accessibilityIdentifier("torch")
        }
    }

    private var timerButton: some View {
        Button {
            camera.timer = camera.timer == 0 ? 3 : camera.timer == 3 ? 10 : 0
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                if camera.timer > 0 { Text("\(camera.timer)s").font(.footnote.bold().monospacedDigit()) }
            }
            .foregroundStyle(camera.timer > 0 ? .yellow : .white)
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(camera.timer == 0 ? "Self-timer off" : "Self-timer \(camera.timer) seconds")
        .accessibilityIdentifier("timer")
    }

    private var gridButton: some View {
        Button {
            update { $0.showGrid.toggle() }
        } label: {
            Image(systemName: "grid")
                .foregroundStyle(settings.showGrid ? .yellow : .white)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(settings.showGrid ? "Hide grid" : "Show grid")
        .accessibilityIdentifier("grid")
    }

    /// Live Photos on or off; in its place for videos, so nothing moves.
    @ViewBuilder private var liveButton: some View {
        if camera.mode == .photo && state.canLive {
            Button {
                update { $0.livePhotos.toggle() }
                camera.settingsChanged()
            } label: {
                Image(systemName: settings.livePhotos ? "livephoto" : "livephoto.slash")
                    .foregroundStyle(settings.livePhotos ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(settings.livePhotos ? "Live Photo on" : "Live Photo off")
            .accessibilityIdentifier("live")
        } else {
            Color.clear
        }
    }

    /// The recording time while recording; for videos otherwise the format, to change it here.
    @ViewBuilder private var topMiddle: some View {
        if let since = camera.recordingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))
                    .font(.body.monospacedDigit())
                    .padding(.horizontal, 6)
                    .background(.red, in: .rect(cornerRadius: 4))
            }
            .accessibilityIdentifier("recording-time")
        } else if camera.mode == .video {
            Menu {
                Picker("Size", selection: videoSetting(\.videoResolution)) {
                    Text("4K").tag(AppSettings.VideoResolution.uhd4K)
                    Text("1080p").tag(AppSettings.VideoResolution.hd1080)
                }
                Picker("Frame rate", selection: videoSetting(\.videoFrameRate)) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                Toggle("HDR", isOn: videoSetting(\.videoHDR))
            } label: {
                Text(state.videoFormat ?? "Video")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.4), in: .capsule)
            }
            .accessibilityIdentifier("video-format")
        }
    }

    /// A video setting changed right here; the camera takes it at once.
    private func videoSetting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                update { $0[keyPath: keyPath] = value }
                camera.settingsChanged()
            })
    }

    private var flashSymbol: String {
        switch settings.flash {
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        case .off: "bolt.slash"
        }
    }

    // MARK: Zoom

    /// The lens buttons; dragged sideways they become a dial, like in Apple's camera.
    private var zoomControl: some View {
        let active = Zoom.activePreset(for: state.zoom, presets: state.presets)
        return ZStack {
            if dialShown {
                ZoomDial(zoom: state.zoom, range: state.zoomRange, presets: state.presets)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            } else {
                HStack(spacing: 6) {
                    ForEach(state.presets, id: \.self) { preset in
                        let isActive = active == preset
                        Button {
                            camera.backend.zoom(to: preset, glide: true)
                        } label: {
                            Text(isActive ? Zoom.text(state.zoom) + "×" : Zoom.text(preset))
                                .font(.system(size: 12, weight: .bold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .foregroundStyle(isActive ? .yellow : .white)
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.5), in: .circle)
                                .scaleEffect(isActive ? 1 : 0.78)
                        }
                        .accessibilityLabel("Zoom \(Zoom.text(preset))")
                        .accessibilityValue(isActive ? Zoom.text(state.zoom) + "×" : "")
                        .accessibilityIdentifier("zoom-\(Zoom.text(preset))")
                    }
                }
                .padding(4)
                .background(.black.opacity(0.25), in: .capsule)
                .animation(.snappy(duration: 0.25), value: active)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .highPriorityGesture(dialDrag)
        .sensoryFeedback(.selection, trigger: active)
        .animation(.easeOut(duration: 0.2), value: dialShown)
        .task(id: dialTouches) {
            // The dial goes away a moment after the finger left it.
            guard dialShown, dialStart == nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled, dialStart == nil { dialShown = false }
        }
    }

    private var dialDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { drag in
                if dialStart == nil {
                    dialStart = state.zoom
                    dialShown = true
                }
                let zoom = Zoom.dialed(
                    from: dialStart ?? state.zoom, points: -drag.translation.width, in: state.zoomRange)
                camera.backend.zoom(to: zoom, glide: false)
            }
            .onEnded { _ in
                dialStart = nil
                dialTouches += 1
            }
    }

    // MARK: Bottom

    /// The modes, the chosen one in the middle; also changed by swiping over the picture.
    private var modeStrip: some View {
        let modes = CameraMode.strip
        let chosen = Double(modes.firstIndex(of: camera.mode) ?? 0)
        let middle = Double(modes.count - 1) / 2
        let width = 86.0
        return HStack(spacing: 0) {
            ForEach(modes, id: \.self) { mode in
                Button {
                    camera.switchTo(mode)
                } label: {
                    Text(mode.title.uppercased())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(mode == camera.mode ? .yellow : .white)
                        .frame(width: width, height: 34)
                }
                .disabled(camera.recording)
                .accessibilityAddTraits(mode == camera.mode ? .isSelected : [])
                .accessibilityIdentifier("mode-\(mode.rawValue)")
            }
        }
        .offset(x: (middle - chosen) * width)
        .animation(.snappy(duration: 0.3), value: camera.mode)
        .frame(maxWidth: .infinity)
        .opacity(camera.recording ? 0 : 1)
    }

    private var shutterRow: some View {
        HStack {
            gallery()
                .frame(width: 52, height: 52)
                .opacity(camera.recording ? 0 : 1)
            Spacer()
            shutterButton
            Spacer()
            Button {
                camera.backend.flip()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3.weight(.semibold))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.15), in: .circle)
            }
            .disabled(!state.canFlip || camera.recording)
            .opacity(camera.recording ? 0 : 1)
            .accessibilityLabel("Switch camera")
            .accessibilityIdentifier("flip-camera")
        }
        .padding(.horizontal, 28)
    }

    private var shutterButton: some View {
        Button {
            camera.shutter()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                if camera.mode == .video {
                    RoundedRectangle(cornerRadius: camera.recording ? 6 : 30)
                        .fill(.red)
                        .frame(width: camera.recording ? 30 : 62, height: camera.recording ? 30 : 62)
                } else {
                    Circle().fill(.white).frame(width: 64, height: 64)
                }
            }
            .animation(.snappy(duration: 0.25), value: camera.recording)
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

extension CameraScreen where Gallery == EmptyView {
    init(camera: CameraModel, settings: AppSettings, update: @escaping ((inout AppSettings) -> Void) -> Void) {
        self.init(camera: camera, settings: settings, update: update) { EmptyView() }
    }
}

extension CameraMode {
    /// The order on the screen, as in Apple's camera.
    static let strip: [CameraMode] = [.video, .photo]

    var title: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }
}

/// The zoom as a dial: marks in doublings, a long one with its number at every lens, the zoom
/// now in the middle.
struct ZoomDial: View {
    let zoom: Double
    let range: ClosedRange<Double>
    let presets: [Double]

    var body: some View {
        let marks = Zoom.dialMarks(in: range, presets: presets)
        VStack(spacing: 2) {
            Text(Zoom.text(zoom) + "×")
                .font(.footnote.bold().monospacedDigit())
                .foregroundStyle(.yellow)
            Canvas { context, size in
                let middle = size.width / 2
                for mark in marks {
                    let x = middle + Zoom.dialOffset(of: mark.value, current: zoom)
                    guard x > -20, x < size.width + 20 else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: mark.major ? 2 : 8))
                    line.addLine(to: CGPoint(x: x, y: 18))
                    context.stroke(line, with: .color(.white.opacity(mark.major ? 1 : 0.55)), lineWidth: 1)
                    if mark.major {
                        context.draw(
                            Text(Zoom.text(mark.value)).font(.caption2.bold()).foregroundStyle(.white),
                            at: CGPoint(x: x, y: 30))
                    }
                }
                var pointer = Path()
                pointer.move(to: CGPoint(x: middle, y: 0))
                pointer.addLine(to: CGPoint(x: middle, y: 20))
                context.stroke(pointer, with: .color(.yellow), lineWidth: 2)
            }
            .frame(height: 40)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.8), .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
        }
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 24)
        .accessibilityElement()
        .accessibilityLabel("Zoom \(Zoom.text(zoom))")
        .accessibilityIdentifier("zoom-dial")
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

/// Puts the camera's picture on screen and turns touches into focus, zoom and mode: tap to focus,
/// hold to lock focus and exposure, pinch to zoom, swipe sideways for the next mode.
struct CameraPreviewHost: UIViewRepresentable {
    let preview: UIView
    let tap: (CGPoint) -> Void
    let hold: (CGPoint) -> Void
    /// The scale since the pinch began, and whether it just began.
    let pinch: (Double, Bool) -> Void
    /// A swipe sideways: `true` towards the left.
    let swipe: (Bool) -> Void

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
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            host.addGestureRecognizer(swipe)
        }
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

        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            parent.swipe(gesture.direction == .left)
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
