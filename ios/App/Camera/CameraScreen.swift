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
    @State private var showManual = false
    @State private var showControls = false
    @State private var manualValue: ManualPanel.Value?
    /// The focus is being turned by hand: the picture bigger, to see what is sharp.
    @State private var focusing = false
    @State private var motion = MotionTracker()
    @State private var focalBadge: FocalLength?
    @State private var focalBadgeTicks = 0
    @State private var smudgeDismissed = false
    /// The highlight that glides between the lens buttons.
    @Namespace private var lens

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
        .onAppear {
            camera.appear()
            motion.setEnabled(settings.showLevel)
        }
        .onDisappear {
            motion.stop()
            camera.disappear()
        }
        .onChange(of: settings.showLevel) { _, on in motion.setEnabled(on) }
        .onChange(of: state.lensSmudged) { _, smudged in if !smudged { smudgeDismissed = false } }
        .onChange(of: state.side) { _, _ in smudgeDismissed = false }
        .onChange(of: camera.shots) {
            flash = true
            withAnimation(.easeOut(duration: 0.2)) { flash = false }
        }
        .task(id: focalBadgeTicks) {
            guard focalBadge != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { focalBadge = nil } }
        }
        .task(id: focusPoint) {
            guard focusPoint != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !state.focusLocked { focusPoint = nil }
        }
    }

    /// The picture as it will be taken: 4:3, 1:1 or 16:9 for photos, 16:9 in the middle for
    /// videos (like Apple's camera, the controls lie over it).
    @ViewBuilder private var viewfinder: some View {
        let photo = camera.mode == .photo
        let ratio = photo ? settings.photoAspectRatio.portraitRatio : (9.0 / 16.0)
        let fullFrame = !photo || settings.photoAspectRatio == .sixteenByNine
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
                        if began { pinchStart = camera.zoom }
                        camera.zoom(
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
                            .padding(.top, fullFrame ? Self.topBarHeight + 70 : 10)
                            .allowsHitTesting(false)
                    }
                }
                // While the mode changes: blurred and still, as in Apple's camera.
                .overlay { SwitchBlur(on: camera.switching).allowsHitTesting(false) }
                .scaleEffect(focusing ? 2.5 : 1)
                .clipped()
                .animation(.easeOut(duration: 0.2), value: focusing)
                .accessibilityIdentifier("camera-preview")
            } else {
                Text(state.problem ?? "Starting the camera…")
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("no-camera")
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .overlay {
            if state.ready && settings.showLevel { LevelOverlay(reading: motion.reading) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fullFrame ? .center : .top)
        .padding(.top, fullFrame ? 0 : Self.topBarHeight)
        .ignoresSafeArea(edges: fullFrame ? .all : [])
        // The frame glides into its new shape under the blur.
        .animation(.snappy(duration: 0.28), value: ratio)
    }

    /// Laid out like Apple's camera: the modes start where the 4:3 picture ends, so the lens
    /// buttons lie on its lower edge; what room is left goes below the shutter, always leaving at
    /// least `bottomGap` above the bottom safe area (the floating tab bar).
    private var controls: some View {
        GeometryReader { geometry in
            let below = geometry.size.height - Self.topBarHeight - geometry.size.width * 4 / 3
            let rest = max(below - Self.modeHeight - Self.shutterHeight, Self.bottomGap)
            controlStack.padding(.bottom, rest)
        }
    }

    static var modeHeight: CGFloat { 44 }
    static var shutterHeight: CGFloat { 84 }
    static var bottomGap: CGFloat { 16 }

    private var controlStack: some View {
        VStack(spacing: 0) {
            topBar
            if state.lensSmudged && !smudgeDismissed {
                Button {
                    smudgeDismissed = true
                } label: {
                    Label("Clean Camera Lens", systemImage: "sparkles")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(.black.opacity(0.75), in: .capsule)
                }
                .padding(.top, 8)
                .accessibilityIdentifier("lens-smudge-hint")
            }
            Spacer(minLength: 0)
            if let problem = camera.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .padding(6)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 6))
                    .padding(.bottom, 8)
            }
            if showManual {
                ManualPanel(camera: camera, chosen: $manualValue, focusing: $focusing)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
            if showControls && !camera.recording {
                CameraDrawer(camera: camera, settings: settings, update: update)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                if let focalBadge {
                    Text(focalBadge.label)
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: .capsule)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                        .accessibilityIdentifier("focal-length-badge")
                }
                zoomControl.frame(height: 56)
            }
            modeStrip
                .frame(height: Self.modeHeight)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onEnded { value in
                            guard !camera.recording,
                                abs(value.translation.height) > abs(value.translation.width)
                            else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                if value.translation.height < -24 {
                                    showControls = true
                                    showManual = false
                                } else if value.translation.height > 24 {
                                    showControls = false
                                }
                            }
                        }
                )
            shutterRow.frame(height: Self.shutterHeight)
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    // MARK: Top

    private var visibleTopControls: [TopBarControl] {
        let configured = CameraControls.sanitizedTopBar(settings.topBarControls)
        return camera.mode == .photo ? configured : configured.filter { !$0.photoOnly }
    }

    private var topBar: some View {
        let items = visibleTopControls
        let split = (items.count + 1) / 2
        let left = Array(items.prefix(split))
        let right = Array(items.dropFirst(split))
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(left) { control in topControlView(control) }
            }
            // In the middle, with the room left between the buttons (never on top of them).
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { topMiddle }
            HStack(spacing: 0) {
                ForEach(right) { control in topControlView(control) }
                if camera.mode.records && !camera.recording {
                    drawerToggleButton
                }
            }
        }
        .font(.title3)
        .frame(height: Self.topBarHeight)
        .padding(.horizontal, 12)
        .background(
            camera.mode.records || settings.photoAspectRatio == .sixteenByNine
                ? Color.black.opacity(0.25) : .clear)
    }

    @ViewBuilder private func topControlView(_ control: TopBarControl) -> some View {
        switch control {
        case .flash: lightButton.frame(width: 44, height: 44)
        case .manual: manualButton.frame(width: 44, height: 44)
        case .timer: timerButton.frame(height: 44)
        case .grid: gridButton.frame(width: 44, height: 44)
        case .live: liveButton.frame(width: 44, height: 44)
        case .exposure: exposureTopButton.frame(height: 44)
        case .aspectRatio: aspectTopButton.frame(height: 44)
        case .resolution: resolutionTopButton.frame(height: 44)
        case .raw: rawTopButton.frame(height: 44)
        }
    }

    private var drawerToggleButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                showControls.toggle()
                if showControls { showManual = false }
            }
        } label: {
            Image(systemName: showControls ? "chevron.down" : "chevron.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(showControls ? .yellow : .white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.14), in: .circle)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(showControls ? "Hide camera controls" : "Show camera controls")
        .accessibilityIdentifier("camera-controls-toggle")
    }

    private var exposureTopButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                showControls = true
                showManual = false
            }
        } label: {
            let bias = camera.manual.exposureBias
            Text(bias == 0 ? "±" : ManualText.bias(bias))
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(bias != 0 ? .yellow : .white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Exposure \(ManualText.bias(camera.manual.exposureBias))")
        .accessibilityIdentifier("top-exposure")
    }

    private var aspectTopButton: some View {
        Button {
            let all = PhotoAspectRatio.allCases
            let next = all[((all.firstIndex(of: settings.photoAspectRatio) ?? 0) + 1) % all.count]
            update { $0.photoAspectRatio = next }
        } label: {
            Text(settings.photoAspectRatio.label)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(settings.photoAspectRatio != .fourByThree ? .yellow : .white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Aspect ratio \(settings.photoAspectRatio.label)")
        .accessibilityIdentifier("top-aspect")
    }

    private var resolutionTopButton: some View {
        Button {
            let options = state.availableResolutions
            guard !options.isEmpty else { return }
            let next = options[((options.firstIndex(of: settings.photoResolution) ?? 0) + 1) % options.count]
            update { $0.photoResolution = next }
            camera.settingsChanged()
        } label: {
            Text("\(settings.photoResolution.shortLabel)MP")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(settings.photoResolution == .mp48 ? .yellow : .white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Resolution \(settings.photoResolution.label)")
        .accessibilityIdentifier("top-resolution")
    }

    @ViewBuilder private var rawTopButton: some View {
        if state.canRAW {
            Button {
                update {
                    $0.captureRAW.toggle()
                    if $0.captureRAW { $0.livePhotos = false }
                }
                camera.settingsChanged()
            } label: {
                Text("RAW")
                    .font(.caption2.bold())
                    .foregroundStyle(settings.captureRAW ? .yellow : .white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(settings.captureRAW ? "RAW on" : "RAW off")
            .accessibilityIdentifier("top-raw")
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
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

    /// Shows or hides the manual values; yellow while any is set.
    @ViewBuilder private var manualButton: some View {
        if state.manualLimits != nil {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    showManual.toggle()
                    if showManual { showControls = false }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(camera.manual.isAutomatic ? .white : .yellow)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(showManual ? "Hide manual settings" : "Manual settings")
            .accessibilityValue(camera.manual.isAutomatic ? "automatic" : "set")
            .accessibilityIdentifier("manual")
        } else {
            Color.clear
        }
    }

    private var timerButton: some View {
        Button {
            camera.timer = CameraControls.nextTimer(after: camera.timer)
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
                update {
                    $0.livePhotos.toggle()
                    if $0.livePhotos { $0.captureRAW = false }
                }
                camera.settingsChanged()
            } label: {
                let active = settings.livePhotos && !settings.captureRAW
                Image(systemName: active ? "livephoto" : "livephoto.slash")
                    .foregroundStyle(active ? .yellow : .white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(settings.livePhotos && !settings.captureRAW ? "Live Photo on" : "Live Photo off")
            .accessibilityIdentifier("live")
        } else {
            Color.clear
        }
    }

    /// Recording time while recording, the format menu for videos, or the drawer chevron for photos.
    @ViewBuilder private var topMiddle: some View {
        if let since = camera.recordingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))
                    .font(.body.monospacedDigit())
                    .padding(.horizontal, 6)
                    .background(.red, in: .rect(cornerRadius: 4))
            }
            .accessibilityIdentifier("recording-time")
        } else if camera.mode.records {
            Menu {
                switch camera.mode {
                case .slowMotion:
                    Picker("Frame rate", selection: videoSetting(\.slowMotionRate)) {
                        Text("240 fps").tag(240)
                        Text("120 fps").tag(120)
                    }
                case .timeLapse:
                    Picker("A picture", selection: videoSetting(\.timeLapseInterval)) {
                        Text("Automatic").tag(0.0)
                        ForEach([0.5, 1, 2, 5, 10], id: \.self) { seconds in
                            Text("every \(CameraMode.intervalText(seconds))").tag(seconds)
                        }
                    }
                default:
                    Picker("Size", selection: videoSetting(\.videoResolution)) {
                        Text("4K").tag(AppSettings.VideoResolution.uhd4K)
                        Text("1080p").tag(AppSettings.VideoResolution.hd1080)
                    }
                    Picker("Frame rate", selection: videoSetting(\.videoFrameRate)) {
                        ForEach(CameraControls.videoFrameRates, id: \.self) { rate in
                            Text(CameraControls.frameRateLabel(rate)).tag(rate)
                        }
                    }
                    Toggle("HDR", isOn: videoSetting(\.videoHDR))
                    Toggle("Auto low-light FPS", isOn: videoSetting(\.autoLowLightFPS))
                }
            } label: {
                Text(state.videoFormat ?? "Video")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: .capsule)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("video-format")
        } else {
            drawerToggleButton
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
        let zoom = camera.zoom
        let active = Zoom.activePreset(for: zoom, presets: state.presets)
        return ZStack {
            if dialShown {
                ZoomDial(zoom: zoom, range: state.zoomRange, presets: state.presets)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            } else {
                HStack(spacing: 0) {
                    ForEach(state.presets, id: \.self) { preset in
                        let isActive = active == preset
                        Button {
                            if let badge = camera.tapZoomPreset(preset) {
                                withAnimation(.snappy(duration: 0.2)) { focalBadge = badge }
                                focalBadgeTicks += 1
                            } else {
                                focalBadge = nil
                            }
                        } label: {
                            ZStack {
                                // One highlight that glides to the chosen lens.
                                if isActive {
                                    Circle().fill(.black.opacity(0.55))
                                        .matchedGeometryEffect(id: "lens", in: lens)
                                        .frame(width: 38, height: 38)
                                } else {
                                    Circle().fill(.black.opacity(0.3)).frame(width: 28, height: 28)
                                }
                                Text(isActive ? Zoom.text(zoom) + "×" : Zoom.text(preset))
                                    .font(.system(size: isActive ? 12 : 10, weight: .bold).monospacedDigit())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .foregroundStyle(isActive ? .yellow : .white)
                                    .frame(width: 36)
                                    .contentTransition(.numericText(value: isActive ? zoom : preset))
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                        }
                        .accessibilityLabel("Zoom \(Zoom.text(preset))")
                        .accessibilityValue(isActive ? Zoom.text(zoom) + "×" : "")
                        .accessibilityIdentifier("zoom-\(Zoom.text(preset))")
                    }
                }
                .padding(.horizontal, 2)
                .background(.black.opacity(0.25), in: .capsule)
                .animation(.snappy(duration: 0.28), value: active)
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
                    dialStart = camera.zoom
                    dialShown = true
                }
                let zoom = Zoom.dialed(
                    from: dialStart ?? camera.zoom, points: -drag.translation.width, in: state.zoomRange)
                camera.zoom(to: zoom, glide: false)
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
                        .frame(width: width, height: 44)
                        .contentShape(.rect)
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
                camera.flip()
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
                if camera.mode.records {
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
                : camera.recording ? "Stop recording" : camera.mode.shutterLabel
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
    static let strip: [CameraMode] = [.timeLapse, .slowMotion, .video, .photo]

    var title: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        case .slowMotion: "Slo-mo"
        case .timeLapse: "Time-lapse"
        }
    }

    var shutterLabel: String {
        switch self {
        case .photo: "Take a photo"
        case .video: "Record a video"
        case .slowMotion: "Record slow motion"
        case .timeLapse: "Record a time-lapse"
        }
    }

    /// "0.5 s", "2 s".
    static func intervalText(_ seconds: Double) -> String {
        (seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)) + " s"
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
        coordinator.host = host
        var recognizers: [UIGestureRecognizer] = [
            UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:))),
            UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:))),
        ]
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        press.minimumPressDuration = 0.6
        recognizers.append(press)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            recognizers.append(swipe)
        }
        for recognizer in recognizers {
            recognizer.delegate = coordinator
            host.addGestureRecognizer(recognizer)
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
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CameraPreviewHost
        weak var host: UIView?

        /// Only touches on the picture itself: a drag on a slider or the zoom buttons lying over
        /// the picture is theirs, not a swipe to the next mode.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let host, let view = touch.view else { return true }
            return view === host || view.isDescendant(of: host)
        }

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

/// The blur over the picture while the camera changes mode, as in Apple's camera: fades in
/// quickly, out a little slower.
struct SwitchBlur: UIViewRepresentable {
    let on: Bool

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        // Only to look at: touches go on to the picture and the controls.
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        let blurred = view.effect != nil
        guard blurred != on else { return }
        let effect: UIVisualEffect? = on ? UIBlurEffect(style: .systemUltraThinMaterialDark) : nil
        UIView.animate(withDuration: on ? 0.12 : 0.3, delay: 0, options: [.beginFromCurrentState]) {
            view.effect = effect
        }
    }
}
