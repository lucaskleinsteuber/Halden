import HaldenKit
import SwiftUI

// Parts of the camera screen that show values changing many times a second (the zoom, the
// camera's readings, the level, scopes). Each reads them in its own body, so only it is drawn
// again, never the whole camera screen.

/// The lens buttons; dragged sideways they become a dial, like in Apple's camera.
struct ZoomButtons: View {
    let camera: CameraModel
    @Binding var focalBadge: FocalLength?
    @Binding var focalBadgeTicks: Int
    /// While the zoom dial is dragged: the zoom it started at.
    @State private var dialStart: Double?
    @State private var dialShown = false
    @State private var dialTouches = 0
    /// The highlight that glides between the lens buttons.
    @Namespace private var lens

    private var state: CameraState { camera.backend.state }

    var body: some View {
        let zoom = camera.zoom
        let active = Zoom.activePreset(for: zoom, presets: state.presets)
        ZStack {
            if dialShown {
                ZoomDial(zoom: zoom, range: state.zoomRange, presets: state.presets)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
            } else {
                HStack(spacing: 0) {
                    ForEach(state.presets, id: \.self) { preset in
                        button(preset, active: active == preset, zoom: zoom)
                    }
                }
                .padding(.horizontal, 2)
                .background(.black.opacity(0.25), in: .capsule)
                .animation(.snappy(duration: 0.22), value: active)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .highPriorityGesture(dialDrag)
        .sensoryFeedback(.selection, trigger: active)
        .animation(.easeOut(duration: 0.16), value: dialShown)
        .task(id: dialTouches) {
            // The dial goes away a moment after the finger left it.
            guard dialShown, dialStart == nil else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled, dialStart == nil { dialShown = false }
        }
    }

    private func button(_ preset: Double, active isActive: Bool, zoom: Double) -> some View {
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
                // The number follows the zoom directly (no counting animation, which lagged
                // behind a pinch).
                Text(isActive ? Zoom.text(zoom) + "×" : Zoom.text(preset))
                    .font(.system(size: isActive ? 12 : 10, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isActive ? .yellow : .white)
                    .frame(width: 36)
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
        }
        .accessibilityLabel("Zoom \(Zoom.text(preset))")
        .accessibilityValue(isActive ? Zoom.text(zoom) + "×" : "")
        .accessibilityIdentifier("zoom-\(Zoom.text(preset))")
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
}

/// One line of hints under the top bar, one at a time and without flicker: a hint shows after
/// it was wanted for a moment and stays a moment after (so a reading near a threshold doesn't
/// make it blink).
struct CameraHints: View {
    enum Hint: Hashable {
        case smudge, focusLock, actionLight
        case portrait(String)
        case depth, night, spatial
        case externalStorage(String)

        /// Shown at once (the person just did something), not after a moment.
        var immediate: Bool {
            switch self {
            case .smudge, .focusLock: true
            default: false
            }
        }
    }

    let camera: CameraModel
    let settings: AppSettings
    @Binding var smudgeDismissed: Bool
    let openNight: () -> Void
    @State private var shown: Hint?

    private var state: CameraState { camera.backend.state }

    private var wanted: Hint? {
        if state.lensSmudged && !smudgeDismissed { return .smudge }
        if state.focusLocked { return .focusLock }
        switch camera.mode {
        case .video:
            if ActionModeRules.needsMoreLight(actionMode: settings.actionMode, iso: camera.backend.readings.iso) {
                return .actionLight
            }
        case .portrait:
            if let hint = state.portraitHint { return .portrait(hint.rawValue) }
        case .photo:
            if camera.isNightCapturing { return nil }
            if camera.nightSuggestedSeconds != nil || settings.nightMode != .auto { return .night }
            if settings.autoDepth && state.subjectDetected && state.canDepth { return .depth }
        case .spatial:
            return .spatial
        default:
            break
        }
        if camera.mode.records && state.capabilities.canExternalStorage, let storage = state.externalStorage,
            ProDeviceRules.shouldRecordToExternalStorage(
                enabled: settings.recordToExternalStorage, storage: storage, format: settings.proVideoFormat)
        {
            return .externalStorage("\(storage.badgeLabel) · \(storage.displayName)")
        }
        return nil
    }

    var body: some View {
        let wanted = wanted
        ZStack {
            if let shown { hint(shown).transition(.opacity) }
        }
        .frame(minHeight: shown == nil ? 0 : 44)
        .animation(.easeOut(duration: 0.18), value: shown)
        .task(id: wanted) {
            guard wanted != shown else { return }
            if let wanted, wanted.immediate {
                shown = wanted
                return
            }
            // On after half a second of being wanted, off after a second of not.
            try? await Task.sleep(for: .milliseconds(wanted == nil ? 1000 : 450))
            if !Task.isCancelled { shown = wanted }
        }
    }

    @ViewBuilder private func hint(_ hint: Hint) -> some View {
        switch hint {
        case .smudge:
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
            .accessibilityIdentifier("lens-smudge-hint")
        case .focusLock:
            Text("AE/AF LOCK")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.yellow, in: .rect(cornerRadius: 4))
                .foregroundStyle(.black)
                .accessibilityIdentifier("focus-lock-badge")
        case .actionLight:
            capsule(Label(ActionModeRules.lowLightHint, systemImage: "figure.run"), id: "action-low-light-hint")
        case .portrait(let text):
            capsule(Text(text), id: "portrait-hint")
        case .depth:
            Label("Depth", systemImage: "f.cursive.circle.fill")
                .font(.caption2.bold())
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: .capsule)
                .accessibilityLabel("Automatic portrait depth active")
                .accessibilityIdentifier("portrait-auto-depth")
        case .night:
            nightBadge
        case .spatial:
            capsule(
                Label("Rotate iPhone to landscape for Spatial Video", systemImage: "view.3d"), id: "spatial-hint")
        case .externalStorage(let text):
            Label(text, systemImage: "externaldrive.connected.to.line.below")
                .font(.caption2.bold())
                .foregroundStyle(.yellow)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: .capsule)
                .accessibilityLabel("Recording to external storage")
                .accessibilityIdentifier("external-storage-badge")
        }
    }

    private func capsule(_ content: some View, id: String) -> some View {
        content
            .font(.caption.bold())
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.yellow, in: .capsule)
            .accessibilityIdentifier(id)
    }

    private var nightBadge: some View {
        let activeSeconds = camera.nightActiveSeconds
        return Button(action: openNight) {
            HStack(spacing: 4) {
                Image(systemName: "moon.stars.fill")
                Text(settings.nightMode.label(suggested: camera.nightSuggestedSeconds, onTripod: camera.isOnTripod))
                    .monospacedDigit()
            }
            .font(.caption.bold())
            .foregroundStyle(activeSeconds > 0 ? .yellow : .white)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(.black.opacity(0.65), in: .capsule)
        }
        .accessibilityLabel(activeSeconds > 0 ? "Night Mode \(activeSeconds) seconds" : "Night Mode off")
        .accessibilityIdentifier("night-mode-badge")
    }
}

/// The live histogram and waveform.
struct ScopesLayer: View {
    let backend: any CaptureBackend
    let settings: AppSettings

    var body: some View {
        if let scopes = backend.liveScopes {
            LiveScopesOverlay(data: scopes, showHistogram: settings.showHistogram, showWaveform: settings.showWaveform)
        }
    }
}

/// The level, following the phone's tilt.
struct LevelLayer: View {
    let motion: MotionTracker

    var body: some View {
        LevelOverlay(reading: motion.reading)
    }
}

/// The panorama guide, following the sweep.
struct PanoramaLayer: View {
    let camera: CameraModel
    let motion: MotionTracker

    var body: some View {
        PanoramaOverlay(
            direction: camera.panoramaDirection,
            capturing: camera.isPanoramaCapturing,
            stitching: camera.panoramaStitching,
            progress: motion.panoramaProgress,
            offAxis: motion.panoramaOffAxis,
            hint: motion.panoramaHint,
            onReverse: { camera.reversePanoramaDirection() },
            onToggleOrientation: { camera.togglePanoramaOrientation() }
        )
    }
}

/// "Hold still" during a Night Mode series.
struct NightHoldLayer: View {
    let camera: CameraModel
    let motion: MotionTracker

    var body: some View {
        NightHoldStillOverlay(offset: motion.holdStillOffset, secondsLeft: camera.nightCaptureSecondsLeft)
    }
}

/// The ultra wide picture around the frame, at 1× and more.
struct OutsideFrameLayer: View {
    let camera: CameraModel

    var body: some View {
        let state = camera.backend.state
        if OutsideFrameMath.isActive(
            enabled: true, isPhotoMode: camera.mode == .photo, zoom: camera.zoom,
            hasUltraWide: state.presets.contains(0.5))
        {
            OutsideFrameOverlay(zoom: camera.zoom)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("outside-frame-overlay")
        }
    }
}

extension CameraMode {
    /// Whether this iPhone's camera can take pictures in `mode` (the others aren't shown).
    @MainActor static func available(_ mode: CameraMode, state: CameraState) -> Bool {
        switch mode {
        case .dual: state.canMultiCam
        case .spatial: state.capabilities.canSpatialVideo
        case .cinematic: state.canCinematic
        case .portrait: state.canDepth || state.capabilities.canDepth
        default: true
        }
    }

    /// How wide a mode's label is in the strip: its text and some room on both sides.
    static func labelWidth(_ title: String, scale: Double) -> CGFloat {
        let text = Double(title.count) * 8.6 * scale
        return CGFloat(max(text + 30, 64))
    }
}
