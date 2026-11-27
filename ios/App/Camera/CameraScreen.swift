import AVKit
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
    @State private var focusSunStartBias: Double?
    @State private var focusTouches = 0
    @State private var flash = false
    @State private var pinchStart = 1.0
    @State private var showManual = false
    @State private var showControls = false
    @State private var drawerPanel: CameraDrawer.Panel?
    @State private var manualValue: ManualPanel.Value?
    /// The focus is being turned by hand: the picture bigger, to see what is sharp.
    @State private var focusing = false
    @State private var motion = MotionTracker()
    @State private var focalBadge: FocalLength?
    @State private var focalBadgeTicks = 0
    @State private var smudgeDismissed = false
    @State private var activeQRSheet: ScannedQRCode?
    @State private var activeTextSheet: String?
    @Environment(\.openURL) private var openURL
    @State private var shutterHoldTask: Task<Void, Never>?
    @State private var shutterPressed = false
    @State private var shutterStartZoom = 1.0
    @State private var shutterConsumedGesture = false
    @State private var hardwareBurstTask: Task<Void, Never>?
    @State private var cameraVisible = false

    private var state: CameraState { camera.backend.state }
    static var topBarHeight: CGFloat { 44 }
    static var exposesTestValues: Bool { CameraTesting.exposesValues }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            viewfinder
            if !camera.mode.isStill || settings.photoAspectRatio == .sixteenByNine {
                // Where the picture runs behind the modes and the shutter: a shade, so they stay readable.
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 300)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
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
        .onAppear {
            cameraVisible = true
            camera.appear()
            if let deviceCamera = camera.backend as? DeviceCamera {
                deviceCamera.onControlStyleChanged = { style in
                    update { $0.photographicStyle = style }
                    camera.settingsChanged()
                }
            }
            motion.showLevel = settings.showLevel
            motion.start()
            camera.isOnTripod = motion.isOnTripod
        }
        .onDisappear {
            cameraVisible = false
            shutterHoldTask?.cancel()
            shutterHoldTask = nil
            hardwareBurstTask?.cancel()
            hardwareBurstTask = nil
            motion.stop()
            camera.disappear()
        }
        .onChange(of: settings.showLevel) { _, on in motion.showLevel = on }
        .onChange(of: motion.isOnTripod) { _, tripod in camera.isOnTripod = tripod }
        .onChange(of: camera.isNightCapturing) { _, active in
            if active { motion.anchorHoldStill() } else { motion.clearHoldStill() }
        }
        .onChange(of: camera.isPanoramaCapturing) { _, active in
            if active {
                motion.startPanorama(direction: camera.panoramaDirection)
            } else {
                motion.stopPanorama()
            }
        }
        .onChange(of: motion.panoramaCompleted) { _, done in
            if done && camera.isPanoramaCapturing { camera.stopPanorama() }
        }
        .sheet(
            isPresented: Binding(
                get: { activeQRSheet != nil },
                set: { if !$0 { activeQRSheet = nil } })
        ) {
            if let qr = activeQRSheet { ScannedQRSheet(code: qr) }
        }
        .sheet(
            isPresented: Binding(
                get: { activeTextSheet != nil },
                set: { if !$0 { activeTextSheet = nil } })
        ) {
            if let text = activeTextSheet { DetectedTextSheet(text: text) }
        }
        .onChange(of: showControls && drawerPanel == .filter) { _, open in camera.backend.sampleLooks(open) }
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
        .task(id: "\(focusPoint?.x ?? -1),\(focusPoint?.y ?? -1),\(focusTouches)") {
            guard focusPoint != nil else { return }
            try? await Task.sleep(for: .seconds(2.0))
            if !Task.isCancelled, !state.focusLocked { focusPoint = nil }
        }
    }

    /// The picture as it will be taken: 4:3, 1:1 or 16:9 for photos, 16:9 in the middle for
    /// videos (like Apple's camera, the controls lie over it).
    @ViewBuilder private var viewfinder: some View {
        let still = camera.mode.isStill
        let ratio = still ? settings.photoAspectRatio.portraitRatio : (9.0 / 16.0)
        let fullFrame = !still || settings.photoAspectRatio == .sixteenByNine
        Group {
            if state.ready {
                CameraPreviewHost(
                    preview: camera.backend.previewView,
                    hasFocusPoint: focusPoint != nil,
                    hardwareEnabled: cameraVisible && state.ready,
                    tap: { point in
                        focusPoint = point
                        focusTouches += 1
                        camera.backend.focus(at: point, lock: false)
                    },
                    hold: { point in
                        focusPoint = point
                        focusTouches += 1
                        camera.backend.focus(at: point, lock: true)
                    },
                    pinch: { scale, began in
                        if began { pinchStart = camera.zoom }
                        camera.zoom(
                            to: Zoom.pinched(from: pinchStart, scale: scale, in: state.zoomRange), glide: false)
                    },
                    swipe: { towardsLeft in camera.switchMode(by: towardsLeft ? 1 : -1) },
                    verticalDrag: { dy, began in
                        if began { focusSunStartBias = camera.manual.exposureBias }
                        let start = focusSunStartBias ?? camera.manual.exposureBias
                        let bias = ShutterGestures.sunExposureBias(from: start, dy: dy)
                        camera.setManual { $0.exposureBias = bias }
                        focusTouches += 1
                    },
                    hardwarePrimary: { phase in handleHardwarePrimary(phase) },
                    hardwareSecondary: { phase in handleHardwareSecondary(phase) }
                )
                // In the same place as the picture, so a tap and its square line up.
                .overlay {
                    if settings.showGrid { ThirdsGrid().allowsHitTesting(false) }
                }
                // While the mode changes: blurred and still, as in Apple's camera.
                .overlay {
                    SwitchBlur(on: camera.switching).allowsHitTesting(false)
                    if camera.switching {
                        Color.clear.allowsHitTesting(false).accessibilityIdentifier("camera-switching")
                    }
                }
                .scaleEffect(focusing ? 2.5 : 1)
                .clipped()
                .animation(.easeOut(duration: 0.2), value: focusing)
                .accessibilityIdentifier("camera-preview")
                // For the UI tests: how often the camera was rebuilt (a filter must not do it).
                .accessibilityValue(Self.exposesTestValues ? "\(camera.backend.reconfigurations)" : "")
            } else {
                Text(state.problem ?? "Starting the camera…")
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("no-camera")
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if state.ready, settings.showHistogram || settings.showWaveform {
                ScopesLayer(backend: camera.backend, settings: settings)
                    .padding(.top, fullFrame ? Self.topBarHeight + 56 : 12)
                    .padding(.trailing, 12)
            }
        }
        .overlay {
            if state.ready {
                if camera.mode == .dual {
                    DualPreviewOverlay(
                        corner: Binding(get: { camera.dualCorner }, set: { camera.dualCorner = $0 }),
                        kind: Binding(get: { camera.dualKind }, set: { camera.dualKind = $0 }),
                        swapped: camera.dualSwapped,
                        recording: camera.recording,
                        backend: camera.backend,
                        onSwap: { camera.swapDualCameras() }
                    )
                } else if camera.mode == .panorama {
                    PanoramaLayer(camera: camera, motion: motion)
                } else if camera.isNightCapturing {
                    NightHoldLayer(camera: camera, motion: motion)
                } else if settings.showLevel {
                    LevelLayer(motion: motion)
                }
                if settings.viewOutsideTheFrame && camera.mode == .photo {
                    OutsideFrameLayer(camera: camera)
                }
                if let focusPoint {
                    GeometryReader { geo in
                        let sunOnRight = focusPoint.x < geo.size.width - 72
                        let sunOffset = -camera.manual.exposureBias / 2.0 * 32.0
                        ZStack {
                            Rectangle()
                                .strokeBorder(.yellow, lineWidth: 1.5)
                                .frame(width: 72, height: 72)
                            ZStack {
                                Rectangle()
                                    .fill(.yellow.opacity(0.65))
                                    .frame(width: 1.5, height: 72)
                                Image(systemName: "sun.max.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.yellow)
                                    .padding(3)
                                    .background(.black.opacity(0.45), in: .circle)
                                    .offset(y: sunOffset)
                            }
                            .offset(x: sunOnRight ? 52 : -52)
                            .accessibilityElement()
                            .accessibilityLabel("Exposure \(ManualText.bias(camera.manual.exposureBias))")
                            .accessibilityIdentifier("focus-exposure-sun")
                        }
                        .position(focusPoint)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fullFrame ? .center : .top)
        .padding(.top, fullFrame ? 0 : Self.topBarHeight)
        .ignoresSafeArea(edges: fullFrame ? .all : [])
        // No glide between 4:3 and 16:9: the picture and everything on it change shape together,
        // at once, under the short blur, so nothing moves out of step.
    }

    /// Laid out like Apple's camera: the modes start where the 4:3 picture ends, so the lens
    /// buttons lie on its lower edge; the room left is shared out between the modes and the
    /// shutter and below the shutter, always at least `bottomGap` above the tab bar.
    private var controls: some View {
        GeometryReader { geometry in
            let below = geometry.size.height - Self.topBarHeight - geometry.size.width * 4 / 3
            let free = max(below - Self.modeHeight - Self.shutterHeight, Self.bottomGap)
            let gap = min(max((free - Self.bottomGap) * 0.4, 0), 20)
            controlStack(gap: gap).frame(width: geometry.size.width).padding(.bottom, free - gap)
        }
    }

    static var modeHeight: CGFloat { 44 }
    static var shutterHeight: CGFloat { 84 }
    static var bottomGap: CGFloat { 10 }

    private func controlStack(gap: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar
            CameraHints(
                camera: camera, settings: settings, smudgeDismissed: $smudgeDismissed,
                openNight: {
                    withAnimation(.snappy(duration: 0.2)) {
                        showManual = false
                        showControls = true
                        drawerPanel = .night
                    }
                }
            )
            .padding(.top, 6)
            if camera.mode.records && !camera.recording && camera.mode != .spatial {
                videoFormatMenu.padding(.top, 2)
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
            if showControls && !camera.recording && drawerPanel != nil {
                // The details of a control lie over the picture, above the lens buttons.
                CameraDrawer(
                    camera: camera, settings: settings, update: update, expanded: $drawerPanel, part: .detail
                )
                .padding(.bottom, 6)
                .transition(.opacity)
            }
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
            } else if camera.mode == .photo && !camera.recording && camera.burstCount == 0 && !showControls
                && (state.detectedQR != nil || state.detectedText != nil)
            {
                ViewfinderScannerBar(
                    qr: settings.scanQRCodes ? state.detectedQR : nil,
                    detectedText: settings.showLiveText ? state.detectedText : nil,
                    onTapQR: { code in
                        if case .url(let url) = code.kind {
                            openURL(url)
                        } else {
                            activeQRSheet = code
                        }
                    },
                    onTapText: { text in activeTextSheet = text }
                )
                .padding(.bottom, 6)
            }
            ZoomButtons(camera: camera, focalBadge: $focalBadge, focalBadgeTicks: $focalBadgeTicks)
                .frame(height: 56)
                .overlay(alignment: .leading) {
                    if state.capabilities.canMacroControl && settings.macroControl
                        && (camera.mode == .photo || camera.mode == .video)
                        && (state.macroActive || settings.macroMode != .auto)
                    {
                        let macroOn = settings.macroMode != .off
                        Button {
                            update { $0.macroMode = macroOn ? .off : .on }
                            camera.settingsChanged()
                        } label: {
                            Image(systemName: "camera.macro")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(macroOn ? .black : .white)
                                .frame(width: 44, height: 44)
                                .background(macroOn ? Color.yellow : Color.black.opacity(0.55), in: .circle)
                        }
                        .padding(.leading, 16)
                        .accessibilityLabel(macroOn ? "Macro on" : "Macro off")
                        .accessibilityIdentifier("macro-toggle")
                    }
                }
            if camera.recording || camera.burstCount > 0 || camera.isPanoramaCapturing {
                Color.clear.frame(height: Self.modeHeight)
            } else if showControls {
                // Like Apple's camera: the controls take the place of the modes while open.
                CameraDrawer(
                    camera: camera, settings: settings, update: update, expanded: $drawerPanel, part: .chips
                )
                .frame(height: Self.modeHeight)
                .transition(.opacity)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onEnded { value in
                            guard abs(value.translation.height) > abs(value.translation.width),
                                value.translation.height > 24
                            else { return }
                            withAnimation(.snappy(duration: 0.2)) { showControls = false }
                        }
                )
            } else {
                modeStrip
                    .frame(height: Self.modeHeight)
                    .transition(.opacity)
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
            }
            Color.clear.frame(height: gap)
            shutterRow.frame(height: Self.shutterHeight)
        }
        .opacity(state.controlsFullscreen ? 0.15 : 1)
        .animation(.easeInOut(duration: 0.2), value: state.controlsFullscreen)
        .foregroundStyle(.white)
        .tint(.white)
    }

    // MARK: Top

    private var visibleTopControls: [TopBarControl] {
        let configured = CameraControls.sanitizedTopBar(settings.topBarControls)
        return camera.mode.isStill ? configured : configured.filter { !$0.photoOnly }
    }

    private var topBar: some View {
        let items = visibleTopControls
        let split = (items.count + 1) / 2
        let left = Array(items.prefix(split))
        let right = Array(items.dropFirst(split))
        // The middle is the middle of the screen, however many buttons each side has.
        return ZStack {
            HStack(spacing: 0) {
                ForEach(left) { control in topControlView(control) }
                Spacer(minLength: 0)
                ForEach(right) { control in topControlView(control) }
            }
            topMiddle.frame(maxWidth: 180)
        }
        .font(.title3)
        .frame(height: Self.topBarHeight)
        .padding(.horizontal, 12)
        // Where the picture goes up to the top (videos, 16:9), a band behind the buttons keeps
        // them readable and the picture's edge from cutting through them.
        .background {
            if !camera.mode.isStill || settings.photoAspectRatio == .sixteenByNine {
                LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .padding(.bottom, -28)
                    .ignoresSafeArea(edges: .top)
                    // Only a shade: touches go through to what lies under it.
                    .allowsHitTesting(false)
            }
        }
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
                drawerPanel = .exposure
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

    /// Flash for photos and portraits, the light for videos.
    @ViewBuilder private var lightButton: some View {
        if camera.mode.isStill {
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

    /// Recording time while recording, burst counter while bursting, the format menu for videos,
    /// or the drawer chevron for photos.
    @ViewBuilder private var topMiddle: some View {
        if let since = camera.recordingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                let elapsed = ShutterGestures.recordingElapsed(
                    started: since, pausedAt: camera.recordingPausedAt, totalPaused: camera.recordingPausedTotal,
                    now: context.date)
                HStack(spacing: 4) {
                    if camera.isRecordingPaused {
                        Image(systemName: "pause.fill").font(.caption2)
                    }
                    Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                }
                .font(.body.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(camera.isRecordingPaused ? Color.gray : Color.red, in: .rect(cornerRadius: 4))
            }
            .accessibilityLabel(camera.isRecordingPaused ? "Recording paused" : "Recording time")
            .accessibilityIdentifier("recording-time")
        } else if camera.burstCount > 0 {
            Text("\(camera.burstCount)")
                .font(.body.bold().monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(.yellow, in: .capsule)
                .accessibilityLabel("Burst \(camera.burstCount) photos")
                .accessibilityIdentifier("burst-counter")
        } else if camera.mode == .panorama || camera.mode == .dual {
            Color.clear
        } else {
            drawerToggleButton
        }
    }

    /// The video format, under the top bar: tap for size, frame rate, HDR and more.
    private var videoFormatMenu: some View {
        Menu {
            switch camera.mode {
            case .cinematic:
                Picker("Depth of field", selection: videoSetting(\.cinematicAperture)) {
                    ForEach([2.0, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0], id: \.self) { f in
                        Text(CinematicRules.formatAperture(f)).tag(f)
                    }
                }
                Picker("Audio", selection: videoSetting(\.audioChannelMode)) {
                    ForEach(availableAudioChannels) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
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
                if state.capabilities.hasProVideo {
                    Picker("Pro video", selection: videoSetting(\.proVideoFormat)) {
                        ForEach(ProVideoFormat.available(for: state.capabilities)) { format in
                            Text(format.title).tag(format)
                        }
                    }
                }
                Toggle("Auto low-light FPS", isOn: videoSetting(\.autoLowLightFPS))
            }
        } label: {
            Text(state.videoFormat ?? "Video")
                .font(.caption2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.5), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("video-format")
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

    private var availableAudioChannels: [AudioChannelMode] {
        state.capabilities.canSpatialAudio ? [.spatial, .stereo, .mono] : [.stereo, .mono]
    }

    private var flashSymbol: String {
        switch settings.flash {
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        case .off: "bolt.slash"
        }
    }

    // MARK: Bottom

    /// The modes this iPhone can do, the chosen one in the middle; also changed by swiping over
    /// the picture.
    private var visibleModes: [CameraMode] {
        CameraMode.strip.filter { CameraMode.available($0, state: state) }
    }

    private var modeStrip: some View {
        let modes = visibleModes
        let widths = modes.map { CameraMode.labelWidth($0.title, scale: textScale) }
        let chosen = modes.firstIndex(of: camera.mode) ?? 0
        // Each label as wide as its text; the chosen one's centre in the middle of the screen.
        let before = widths.prefix(chosen).reduce(0, +)
        let total = widths.reduce(0, +)
        let shift = total / 2 - (before + widths[min(chosen, widths.count - 1)] / 2)
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                HStack(spacing: 0) {
                    ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                        Button {
                            camera.switchTo(mode)
                        } label: {
                            Text(mode.title.uppercased())
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(mode == camera.mode ? .yellow : .white)
                                .frame(width: widths[index], height: 44)
                                .contentShape(.rect)
                        }
                        .disabled(camera.recording)
                        .accessibilityAddTraits(mode == camera.mode ? .isSelected : [])
                        .accessibilityIdentifier("mode-\(mode.rawValue)")
                    }
                }
                .fixedSize()
                .offset(x: shift)
                .animation(.snappy(duration: 0.25), value: camera.mode)
            }
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
            )
            .opacity(camera.recording || camera.burstCount > 0 ? 0 : 1)
            .accessibilityHidden(camera.recording || camera.burstCount > 0)
    }

    @ScaledMetric(relativeTo: .footnote) private var textScale = 1.0

    private var shutterRow: some View {
        HStack {
            if camera.canPauseAndSnapStill {
                Button {
                    camera.togglePauseRecording()
                } label: {
                    Image(systemName: camera.isRecordingPaused ? "play.fill" : "pause.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(camera.isRecordingPaused ? .yellow : .white)
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.18), in: .circle)
                }
                .accessibilityLabel(camera.isRecordingPaused ? "Resume recording" : "Pause recording")
                .accessibilityIdentifier("pause-recording")
            } else if camera.recording || camera.burstCount > 0 {
                Color.clear.frame(width: 52, height: 52)
            } else {
                gallery()
                    .frame(width: 52, height: 52)
            }
            Spacer()
            shutterButton
            Spacer()
            if camera.canPauseAndSnapStill {
                Button {
                    camera.takeStillWhileRecording()
                } label: {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.65), lineWidth: 2).frame(width: 52, height: 52)
                        Circle().fill(.white).frame(width: 40, height: 40)
                    }
                    .frame(width: 52, height: 52)
                }
                .accessibilityLabel("Take photo while recording")
                .accessibilityIdentifier("capture-still")
            } else if camera.isQuickTake && !camera.isQuickTakeLocked {
                Image(systemName: "lock.open")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.22), in: .circle)
                    .accessibilityIdentifier("quicktake-lock-target")
            } else if camera.recording || camera.burstCount > 0 {
                Color.clear.frame(width: 52, height: 52)
            } else {
                Button {
                    camera.flip()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.15), in: .circle)
                }
                .disabled(!state.canFlip)
                .accessibilityLabel("Switch camera")
                .accessibilityIdentifier("flip-camera")
            }
        }
        .padding(.horizontal, 28)
    }

    private var shutterButton: some View {
        Button {
            if shutterConsumedGesture {
                shutterConsumedGesture = false
                return
            }
            camera.shutter()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                if let progress = camera.nightCaptureProgress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 72, height: 72)
                        .accessibilityIdentifier("night-progress")
                    Circle().fill(.yellow.opacity(0.22)).frame(width: 60, height: 60)
                    Image(systemName: "moon.stars.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.yellow)
                } else if camera.panoramaStitching {
                    Circle().fill(.white.opacity(0.22)).frame(width: 64, height: 64)
                    ProgressView().tint(.yellow)
                } else if camera.isPanoramaCapturing {
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 30, height: 30)
                } else if camera.burstCount > 0 {
                    Circle().fill(.yellow).frame(width: 64, height: 64)
                    Text("\(camera.burstCount)")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(.black)
                } else {
                    // One shape that changes: white circle (photo), red circle (video), red square
                    // (recording), so switching modes or starting a video morphs instead of jumping.
                    let video =
                        camera.recording || camera.mode.records || (camera.mode == .dual && camera.dualKind == .video)
                    RoundedRectangle(cornerRadius: camera.recording ? 6 : 32)
                        .fill(video ? Color.red : Color.white)
                        .frame(width: camera.recording ? 30 : 62, height: camera.recording ? 30 : 62)
                }
            }
            .animation(.snappy(duration: 0.22), value: camera.recording)
            .animation(.easeInOut(duration: 0.2), value: camera.mode.records)
        }
        .disabled(!state.ready)
        .simultaneousGesture(shutterGesture)
        .accessibilityLabel(
            camera.countdown != nil
                ? "Stop the self-timer"
                : camera.isPanoramaCapturing
                    ? "Stop panorama"
                    : camera.recording
                        ? "Stop recording"
                        : camera.mode == .dual
                            ? (camera.dualKind == .video ? "Record dual video" : "Take dual photo")
                            : camera.mode.shutterLabel
        )
        .accessibilityIdentifier("shutter")
    }

    /// Hold in photo mode for QuickTake video (drag right to lock, drag up to zoom); drag left
    /// from the shutter for a photo burst.
    private var shutterGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard state.ready else { return }
                if !shutterPressed && camera.mode == .photo && !camera.recording && camera.countdown == nil {
                    shutterPressed = true
                    shutterConsumedGesture = false
                    shutterStartZoom = camera.zoom
                    shutterHoldTask?.cancel()
                    shutterHoldTask = Task {
                        try? await Task.sleep(for: .seconds(ShutterGestures.quickTakeHoldSeconds))
                        guard !Task.isCancelled, shutterPressed, camera.burstCount == 0,
                            camera.mode == .photo, !camera.recording
                        else { return }
                        shutterConsumedGesture = true
                        camera.startQuickTake()
                    }
                }
                guard shutterPressed else { return }
                let action = ShutterGestures.evaluateDrag(
                    dx: drag.translation.width, dy: drag.translation.height,
                    quickTaking: camera.isQuickTake, locked: camera.isQuickTakeLocked,
                    startZoom: shutterStartZoom, zoomRange: state.zoomRange)
                switch action {
                case .none: break
                case .burst:
                    shutterHoldTask?.cancel()
                    shutterHoldTask = nil
                    shutterConsumedGesture = true
                    camera.startBurst()
                case .lockQuickTake:
                    shutterConsumedGesture = true
                    camera.lockQuickTake()
                case .quickTakeZoom(let zoom):
                    shutterConsumedGesture = true
                    camera.zoom(to: zoom, glide: false)
                }
            }
            .onEnded { _ in
                shutterPressed = false
                shutterHoldTask?.cancel()
                shutterHoldTask = nil
                if camera.burstCount > 0 {
                    shutterConsumedGesture = true
                    camera.stopBurst()
                } else if camera.isQuickTake && !camera.isQuickTakeLocked {
                    shutterConsumedGesture = true
                    camera.finishQuickTake()
                }
            }
    }

    /// Volume Up: tap captures / toggles recording; hold in photo mode shoots a burst when enabled.
    private func handleHardwarePrimary(_ phase: AVCaptureEventPhase) {
        switch phase {
        case .began:
            guard camera.mode == .photo, !camera.recording, settings.volumeUpForBurst else { return }
            hardwareBurstTask?.cancel()
            hardwareBurstTask = Task {
                try? await Task.sleep(for: .seconds(ShutterGestures.quickTakeHoldSeconds))
                guard !Task.isCancelled, camera.mode == .photo, !camera.recording else { return }
                camera.startBurst()
            }
        case .ended:
            hardwareBurstTask?.cancel()
            hardwareBurstTask = nil
            if camera.burstCount > 0 {
                camera.stopBurst()
            } else {
                camera.shutter()
            }
        case .cancelled:
            hardwareBurstTask?.cancel()
            hardwareBurstTask = nil
            if camera.burstCount > 0 { camera.stopBurst() }
        @unknown default:
            break
        }
    }

    /// Volume Down / AirPods stem: tap captures or starts/stops recording.
    private func handleHardwareSecondary(_ phase: AVCaptureEventPhase) {
        if phase == .ended { camera.shutter() }
    }
}

/// Whether the UI tests run (then the screen tells them a few inner values).
enum CameraTesting {
    static let exposesValues = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-ui-testing") }
}

extension CameraScreen where Gallery == EmptyView {
    init(camera: CameraModel, settings: AppSettings, update: @escaping ((inout AppSettings) -> Void) -> Void) {
        self.init(camera: camera, settings: settings, update: update) { EmptyView() }
    }
}

extension CameraMode {
    /// The order on the screen, as in Apple's camera (`video` stays immediately left of `photo`).
    static let strip: [CameraMode] = [
        .timeLapse, .slowMotion, .cinematic, .video, .photo, .portrait, .panorama, .dual, .spatial,
    ]

    var title: String {
        switch self {
        case .photo: "Photo"
        case .portrait: "Portrait"
        case .panorama: "Pano"
        case .dual: "Dual"
        case .video: "Video"
        case .cinematic: "Cinematic"
        case .slowMotion: "Slo-mo"
        case .timeLapse: "Time-lapse"
        case .spatial: "Spatial"
        }
    }

    var shutterLabel: String {
        switch self {
        case .photo: "Take a photo"
        case .portrait: "Take a portrait"
        case .panorama: "Start panorama"
        case .dual: "Take dual photo"
        case .video: "Record a video"
        case .cinematic: "Record cinematic video"
        case .slowMotion: "Record slow motion"
        case .timeLapse: "Record a time-lapse"
        case .spatial: "Record spatial video"
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
    let hasFocusPoint: Bool
    let hardwareEnabled: Bool
    let tap: (CGPoint) -> Void
    let hold: (CGPoint) -> Void
    /// The scale since the pinch began, and whether it just began.
    let pinch: (Double, Bool) -> Void
    /// A swipe sideways: `true` towards the left.
    let swipe: (Bool) -> Void
    /// Vertical drag while the focus box is visible to slide exposure (sun icon).
    let verticalDrag: (Double, Bool) -> Void
    /// Hardware Volume Up / primary capture button events.
    let hardwarePrimary: (AVCaptureEventPhase) -> Void
    /// Hardware Volume Down / AirPods stem secondary capture events.
    let hardwareSecondary: (AVCaptureEventPhase) -> Void

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
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        coordinator.sunPan = pan
        recognizers.append(pan)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            recognizers.append(swipe)
        }
        for recognizer in recognizers {
            recognizer.delegate = coordinator
            host.addGestureRecognizer(recognizer)
        }
        let interaction = AVCaptureEventInteraction(
            primary: { [weak coordinator] event in coordinator?.parent.hardwarePrimary(event.phase) },
            secondary: { [weak coordinator] event in coordinator?.parent.hardwareSecondary(event.phase) })
        interaction.isEnabled = hardwareEnabled
        host.addInteraction(interaction)
        coordinator.captureInteraction = interaction
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.captureInteraction?.isEnabled = hardwareEnabled
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
        weak var sunPan: UIPanGestureRecognizer?
        var captureInteraction: AVCaptureEventInteraction?

        /// Only touches on the picture itself: a drag on a slider or the zoom buttons lying over
        /// the picture is theirs, not a swipe to the next mode.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let host, let view = touch.view else { return true }
            return view === host || view.isDescendant(of: host)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === sunPan, let pan = gestureRecognizer as? UIPanGestureRecognizer {
                guard parent.hasFocusPoint else { return false }
                let velocity = pan.velocity(in: host)
                return abs(velocity.y) > abs(velocity.x)
            }
            return true
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

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            let dy = Double(gesture.translation(in: gesture.view).y)
            switch gesture.state {
            case .began: parent.verticalDrag(0, true)
            case .changed: parent.verticalDrag(dy, false)
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
        UIView.animate(withDuration: on ? 0.08 : 0.18, delay: 0, options: [.beginFromCurrentState]) {
            view.effect = effect
        }
    }
}
