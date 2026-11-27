import HaldenKit
import SwiftUI

/// The camera's control drawer, as in iOS 26: opened by the top-bar chevron or by swiping up over
/// the modes, its row of controls takes the modes' place; the details of the chosen control
/// (a slider, the styles, the filters) lie over the picture above the lens buttons. Only what
/// this iPhone can do is offered, and nothing that is already in the top bar.
struct CameraDrawer: View {
    enum Part {
        /// The row of controls, where the modes were.
        case chips
        /// The chosen control's details, over the picture.
        case detail
    }

    enum Panel: Hashable {
        case night, aperture, lighting, style, filter, exposure, aspectRatio, timer, resolution, videoFrameRate,
            proVideoFormat, cinematicAperture, scopes, timeLapseInterval
    }

    let camera: CameraModel
    let settings: AppSettings
    let update: ((inout AppSettings) -> Void) -> Void
    @Binding var expanded: Panel?
    var part = Part.chips

    private var state: CameraState { camera.backend.state }
    private var topBar: [TopBarControl] { CameraControls.sanitizedTopBar(settings.topBarControls) }

    var body: some View {
        switch part {
        case .detail:
            if let expanded {
                detailBar(for: expanded)
            }
        case .chips:
            chips
        }
    }

    private var chips: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if camera.mode == .photo {
                        photoButtons
                    } else if camera.mode == .portrait {
                        portraitButtons
                    } else if camera.mode == .cinematic {
                        cinematicButtons
                    } else if camera.mode == .video {
                        videoButtons
                    } else if camera.mode == .spatial {
                        audioAndScopeChips
                    } else if camera.mode == .slowMotion {
                        slowMotionButtons
                    } else {
                        timeLapseButtons
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 44)
            // The row fades out at the edges, so a cut-off control reads as "scroll for more".
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.96), .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
            )
            .accessibilityIdentifier("camera-drawer-chips")
        }
        .animation(.snappy(duration: 0.2), value: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera-drawer")
    }

    // MARK: Photo controls

    @ViewBuilder private var photoButtons: some View {
        // Flash: Auto / On / Off (when it isn't in the top bar already)
        if !topBar.contains(.flash) {
            flashChip
        }

        // Live Photo
        if state.canLive && !topBar.contains(.live) {
            liveChip
        }

        photoLookAndExposureChips
    }

    private var flashChip: some View {
        drawerChip(
            symbol: flashSymbol, text: settings.flash.rawValue.uppercased(), active: settings.flash == .on,
            label: "Flash \(settings.flash.rawValue)", id: "drawer-flash"
        ) {
            let next: AppSettings.Flash =
                switch settings.flash {
                case .auto: .on
                case .on: .off
                case .off: .auto
                }
            update {
                $0.flash = next
                // Flash and Night Mode exclude each other, as in Apple's camera.
                if next == .on && $0.nightMode != .off { $0.nightMode = .off }
            }
        }
        .disabled(!state.hasFlash)
    }

    private var liveChip: some View {
        let liveActive = settings.livePhotos && !settings.captureRAW && !settings.captureProRAW
        return drawerChip(
            symbol: liveActive ? "livephoto" : "livephoto.slash", text: "LIVE",
            active: liveActive,
            label: liveActive ? "Live Photo on" : "Live Photo off", id: "drawer-live"
        ) {
            update {
                $0.livePhotos.toggle()
                if $0.livePhotos {
                    $0.captureRAW = false
                    $0.captureProRAW = false
                }
            }
            camera.settingsChanged()
        }
    }

    @ViewBuilder private var photoLookAndExposureChips: some View {
        // Night Mode
        let nightSuggested = camera.nightSuggestedSeconds
        let nightActive = camera.nightActiveSeconds > 0
        drawerChip(
            symbol: "moon.stars.fill",
            text: settings.nightMode.label(suggested: nightSuggested, onTripod: camera.isOnTripod),
            active: nightActive || expanded == .night,
            label: nightActive ? "Night Mode \(camera.nightActiveSeconds) seconds" : "Night Mode",
            id: "drawer-night"
        ) {
            expanded = expanded == .night ? nil : .night
        }

        // Photographic Style
        let hasStyle = settings.photographicStyle.map { !$0.isDefault } ?? false
        drawerChip(
            symbol: "wand.and.stars",
            text: hasStyle ? (settings.photographicStyle?.preset.title.uppercased() ?? "STYLE") : "STYLE",
            active: hasStyle || expanded == .style,
            label: hasStyle
                ? "Photographic style \(settings.photographicStyle?.preset.title ?? "")" : "Photographic style",
            id: "drawer-style"
        ) {
            expanded = expanded == .style ? nil : .style
        }

        // Photo Filter
        drawerChip(
            symbol: "camera.filters",
            text: settings.photoFilter?.title.uppercased() ?? "FILTER",
            active: settings.photoFilter != nil || expanded == .filter,
            label: settings.photoFilter.map { "Filter \($0.title)" } ?? "Filter off",
            id: "drawer-filter"
        ) {
            expanded = expanded == .filter ? nil : .filter
        }

        // Exposure compensation (EV -2...+2)
        let bias = camera.manual.exposureBias
        drawerChip(
            symbol: "plusminus", text: bias == 0 ? "EV" : ManualText.bias(bias),
            active: bias != 0 || expanded == .exposure,
            label: "Exposure \(ManualText.bias(bias))", id: "drawer-exposure"
        ) {
            expanded = expanded == .exposure ? nil : .exposure
        }

        // Aspect ratio (4:3 / 16:9 / 1:1)
        drawerChip(
            symbol: nil, text: settings.photoAspectRatio.label,
            active: settings.photoAspectRatio != .fourByThree || expanded == .aspectRatio,
            label: "Aspect ratio \(settings.photoAspectRatio.label)", id: "drawer-aspect"
        ) {
            expanded = expanded == .aspectRatio ? nil : .aspectRatio
        }

        // Timer (Off / 3 / 5 / 10 s)
        drawerChip(
            symbol: "timer", text: camera.timer == 0 ? "OFF" : "\(camera.timer)s",
            active: camera.timer > 0 || expanded == .timer,
            label: camera.timer == 0 ? "Timer off" : "Timer \(camera.timer) seconds", id: "drawer-timer"
        ) {
            expanded = expanded == .timer ? nil : .timer
        }

        // Resolution (12 / 24 / 48 MP)
        if state.availableResolutions.count > 1 {
            drawerChip(
                symbol: nil, text: settings.photoResolution.label,
                active: settings.photoResolution == .mp48 || expanded == .resolution,
                label: "Resolution \(settings.photoResolution.label)", id: "drawer-resolution"
            ) {
                expanded = expanded == .resolution ? nil : .resolution
            }
        }

        // Apple ProRAW (only on Pro iPhones that support it)
        if state.capabilities.canProRAW {
            drawerChip(
                symbol: nil, text: "ProRAW", active: settings.captureProRAW,
                label: settings.captureProRAW ? "Apple ProRAW on" : "Apple ProRAW off", id: "drawer-proraw"
            ) {
                update {
                    $0.captureProRAW.toggle()
                    if $0.captureProRAW {
                        $0.livePhotos = false
                        $0.captureRAW = false
                    }
                }
                camera.settingsChanged()
            }
        }

        // Bayer RAW (DNG)
        if state.canRAW && state.capabilities.canBayerRAW && !topBar.contains(.raw) {
            drawerChip(
                symbol: nil, text: settings.captureRAW ? "RAW · 12 MP · 1×" : "RAW", active: settings.captureRAW,
                label: settings.captureRAW ? "RAW on" : "RAW off", id: "drawer-raw"
            ) {
                update {
                    $0.captureRAW.toggle()
                    if $0.captureRAW {
                        $0.livePhotos = false
                        $0.captureProRAW = false
                    }
                }
                camera.settingsChanged()
            }
        }
    }

    // MARK: Portrait controls

    @ViewBuilder private var portraitButtons: some View {
        drawerChip(
            symbol: "f.cursive", text: PortraitMath.formatAperture(settings.portraitAperture),
            active: expanded == .aperture || abs(settings.portraitAperture - PortraitMath.defaultAperture) > 0.05,
            label: "Depth \(PortraitMath.formatAperture(settings.portraitAperture))", id: "drawer-aperture"
        ) {
            expanded = expanded == .aperture ? nil : .aperture
        }

        drawerChip(
            symbol: settings.portraitLighting.symbol, text: settings.portraitLighting.title.uppercased(),
            active: settings.portraitLighting != .natural || expanded == .lighting,
            label: "Lighting \(settings.portraitLighting.title)", id: "drawer-lighting"
        ) {
            expanded = expanded == .lighting ? nil : .lighting
        }

        let hasStyle = settings.photographicStyle.map { !$0.isDefault } ?? false
        drawerChip(
            symbol: "wand.and.stars",
            text: hasStyle ? (settings.photographicStyle?.preset.title.uppercased() ?? "STYLE") : "STYLE",
            active: hasStyle || expanded == .style,
            label: hasStyle
                ? "Photographic style \(settings.photographicStyle?.preset.title ?? "")" : "Photographic style",
            id: "drawer-style"
        ) {
            expanded = expanded == .style ? nil : .style
        }

        drawerChip(
            symbol: "camera.filters",
            text: settings.photoFilter?.title.uppercased() ?? "FILTER",
            active: settings.photoFilter != nil || expanded == .filter,
            label: settings.photoFilter.map { "Filter \($0.title)" } ?? "Filter off",
            id: "drawer-filter"
        ) {
            expanded = expanded == .filter ? nil : .filter
        }

        if !topBar.contains(.flash) {
            flashChip
        }

        drawerChip(
            symbol: "timer", text: camera.timer == 0 ? "OFF" : "\(camera.timer)s",
            active: camera.timer > 0 || expanded == .timer,
            label: camera.timer == 0 ? "Timer off" : "Timer \(camera.timer) seconds", id: "drawer-timer"
        ) {
            expanded = expanded == .timer ? nil : .timer
        }
    }

    // MARK: Video & Cinematic controls

    @ViewBuilder private var cinematicButtons: some View {
        drawerChip(
            symbol: "f.cursive", text: CinematicRules.formatAperture(settings.cinematicAperture),
            active: expanded == .cinematicAperture
                || abs(settings.cinematicAperture - CinematicRules.defaultAperture) > 0.05,
            label: "Cinematic depth \(CinematicRules.formatAperture(settings.cinematicAperture))",
            id: "drawer-cinematic-aperture"
        ) {
            expanded = expanded == .cinematicAperture ? nil : .cinematicAperture
        }
        audioAndScopeChips
    }

    @ViewBuilder private var videoButtons: some View {
        if state.capabilities.canActionMode {
            drawerChip(
                symbol: "figure.run", text: "ACTION", active: settings.actionMode,
                label: settings.actionMode ? "Action Mode on" : "Action Mode off", id: "drawer-action"
            ) {
                update { $0.actionMode.toggle() }
                camera.settingsChanged()
            }
        }

        drawerChip(
            symbol: nil, text: settings.videoResolution == .uhd4K ? "4K" : "HD",
            active: settings.videoResolution == .uhd4K,
            label: "Video resolution \(settings.videoResolution == .uhd4K ? "4K" : "1080p")",
            id: "drawer-video-resolution"
        ) {
            update { $0.videoResolution = $0.videoResolution == .uhd4K ? .hd1080 : .uhd4K }
            camera.settingsChanged()
        }

        drawerChip(
            symbol: nil, text: CameraControls.shortFrameRateLabel(settings.videoFrameRate),
            active: expanded == .videoFrameRate || CameraControls.isPAL(frameRate: settings.videoFrameRate),
            label: "Frame rate \(CameraControls.frameRateLabel(settings.videoFrameRate))", id: "drawer-video-fps"
        ) {
            expanded = expanded == .videoFrameRate ? nil : .videoFrameRate
        }

        drawerChip(
            symbol: nil, text: "HDR", active: settings.videoHDR,
            label: settings.videoHDR ? "HDR on" : "HDR off", id: "drawer-video-hdr"
        ) {
            update { $0.videoHDR.toggle() }
            camera.settingsChanged()
        }

        if state.capabilities.hasProVideo {
            let effective = ProDeviceRules.effectiveVideoFormat(
                wanted: settings.proVideoFormat, capabilities: state.capabilities)
            drawerChip(
                symbol: nil, text: effective.shortLabel,
                active: effective != .standard || expanded == .proVideoFormat,
                label: "Pro video \(effective.title)", id: "drawer-prores"
            ) {
                expanded = expanded == .proVideoFormat ? nil : .proVideoFormat
            }
        }

        drawerChip(
            symbol: "moon.stars", text: "AUTO FPS", active: settings.autoLowLightFPS,
            label: settings.autoLowLightFPS ? "Auto low-light FPS on" : "Auto low-light FPS off",
            id: "drawer-video-autofps"
        ) {
            update { $0.autoLowLightFPS.toggle() }
            camera.settingsChanged()
        }

        audioAndScopeChips
    }

    @ViewBuilder private var audioAndScopeChips: some View {
        let effectiveAudio = ProDeviceRules.effectiveAudioChannel(
            wanted: settings.audioChannelMode, capabilities: state.capabilities)
        drawerChip(
            symbol: "waveform", text: effectiveAudio.shortLabel,
            active: effectiveAudio != .stereo,
            label: "Audio \(effectiveAudio.title)", id: "drawer-audio"
        ) {
            let choices: [AudioChannelMode] =
                state.capabilities.canSpatialAudio ? [.spatial, .stereo, .mono] : [.stereo, .mono]
            let next = choices[((choices.firstIndex(of: effectiveAudio) ?? 0) + 1) % choices.count]
            update { $0.audioChannelMode = next }
            camera.settingsChanged()
        }

        if state.canWindNoiseRemoval || state.capabilities.canWindNoiseRemoval {
            drawerChip(
                symbol: "wind", text: "WIND", active: settings.windNoiseRemoval,
                label: settings.windNoiseRemoval ? "Wind noise removal on" : "Wind noise removal off",
                id: "drawer-wind"
            ) {
                update { $0.windNoiseRemoval.toggle() }
                camera.settingsChanged()
            }
        }

        let scopesOn = settings.showHistogram || settings.showWaveform
        drawerChip(
            symbol: "chart.bar.xaxis", text: "SCOPES", active: scopesOn || expanded == .scopes,
            label: scopesOn ? "Live scopes on" : "Live scopes off", id: "drawer-scopes"
        ) {
            expanded = expanded == .scopes ? nil : .scopes
        }
    }

    @ViewBuilder private var slowMotionButtons: some View {
        ForEach([120, 240], id: \.self) { rate in
            drawerChip(
                symbol: nil, text: "\(rate) fps", active: settings.slowMotionRate == rate,
                label: "Slow motion \(rate) fps", id: "drawer-slowmo-\(rate)"
            ) {
                update { $0.slowMotionRate = rate }
                camera.settingsChanged()
            }
        }
    }

    @ViewBuilder private var timeLapseButtons: some View {
        drawerChip(
            symbol: "timelapse",
            text: settings.timeLapseInterval == 0 ? "AUTO" : CameraMode.intervalText(settings.timeLapseInterval),
            active: expanded == .timeLapseInterval || settings.timeLapseInterval > 0,
            label: "Time-lapse interval", id: "drawer-timelapse-interval"
        ) {
            expanded = expanded == .timeLapseInterval ? nil : .timeLapseInterval
        }
    }

    // MARK: Detail bar above the drawer

    @ViewBuilder private func detailBar(for panel: Panel) -> some View {
        Group {
            switch panel {
            case .night:
                let maxSec = NightMath.maxSeconds(onTripod: camera.isOnTripod)
                let currentSec = Double(camera.nightActiveSeconds)
                HStack(spacing: 8) {
                    optionPill("Off", selected: settings.nightMode.isOff, id: "drawer-night-off") {
                        update { $0.nightMode = .off }
                    }
                    optionPill("Auto", selected: settings.nightMode == .auto, id: "drawer-night-auto") {
                        update { $0.nightMode = .auto }
                    }
                    Slider(
                        value: Binding(
                            get: { currentSec },
                            set: { value in
                                let rounded = Int(value.rounded())
                                update {
                                    $0.nightMode = rounded <= 0 ? .off : .seconds(rounded)
                                    // Night Mode turns the flash off (it would end at 0 s otherwise).
                                    if rounded > 0 && $0.flash == .on { $0.flash = .auto }
                                }
                            }),
                        in: 0...Double(maxSec),
                        step: 1
                    )
                    .tint(.yellow)
                    .accessibilityLabel("Night Mode duration")
                    .accessibilityIdentifier("drawer-night-slider")

                    Text(camera.nightActiveSeconds == 0 ? "Off" : "\(camera.nightActiveSeconds)s")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(camera.nightActiveSeconds > 0 ? .yellow : .white)
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 12)

            case .aperture:
                HStack(spacing: 10) {
                    Text(PortraitMath.formatAperture(settings.portraitAperture))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.yellow)
                        .frame(minWidth: 44, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { settings.portraitAperture },
                            set: { value in
                                update { $0.portraitAperture = PortraitMath.clampedAperture(value) }
                                camera.settingsChanged()
                            }),
                        in: PortraitMath.apertureRange
                    )
                    .tint(.yellow)
                    .accessibilityLabel("Portrait depth f-stop")
                    .accessibilityIdentifier("drawer-aperture-slider")
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .background(.black.opacity(0.65), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 12)

            case .lighting:
                optionRow {
                    ForEach(PortraitLighting.allCases) { light in
                        optionPill(
                            light.title, selected: settings.portraitLighting == light,
                            id: "drawer-light-\(light.rawValue)"
                        ) {
                            update { $0.portraitLighting = light }
                            camera.settingsChanged()
                        }
                    }
                }

            case .style:
                StylePadView(
                    style: Binding(
                        get: { settings.photographicStyle },
                        set: { value in
                            update { $0.photographicStyle = value }
                            camera.settingsChanged()
                        }))
            case .filter:
                VStack(spacing: 6) {
                    FilterStripView(
                        filter: Binding(
                            get: { settings.photoFilter },
                            set: { value in
                                update {
                                    $0.photoFilter = value
                                    // A new filter starts at full strength.
                                    if value != nil { $0.filterIntensity = 1 }
                                }
                                camera.settingsChanged()
                            }),
                        sample: camera.backend.lookSample,
                        style: settings.photographicStyle,
                        pictures: true
                    )
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 14))
                    .padding(.horizontal, 8)
                    if settings.photoFilter != nil {
                        HStack(spacing: 10) {
                            Text("Strength")
                                .font(.caption2.bold())
                                .foregroundStyle(.white.opacity(0.85))
                            Slider(
                                value: Binding(
                                    get: { settings.filterIntensity },
                                    set: { value in
                                        update { $0.filterIntensity = PhotoFilter.clampedIntensity(value) }
                                        camera.settingsChanged()
                                    }),
                                in: 0...1
                            )
                            .tint(.yellow)
                            .accessibilityLabel("Filter strength")
                            .accessibilityIdentifier("filter-intensity-slider")
                            Text("\(Int((settings.filterIntensity * 100).rounded()))%")
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundStyle(.yellow)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(.black.opacity(0.65), in: .rect(cornerRadius: 12))
                        .padding(.horizontal, 12)
                    }
                }
            case .exposure:
                HStack(spacing: 10) {
                    Button {
                        camera.setManual { $0.exposureBias = 0 }
                    } label: {
                        Text("0 EV")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(camera.manual.exposureBias == 0 ? .yellow : .white)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("drawer-ev-reset")

                    Slider(
                        value: Binding(
                            get: { camera.manual.exposureBias },
                            set: { value in
                                camera.setManual { $0.exposureBias = CameraControls.clampedExposureBias(value) }
                            }),
                        in: CameraControls.exposureBiasRange
                    )
                    .tint(.yellow)
                    .accessibilityLabel("Exposure compensation")
                    .accessibilityIdentifier("drawer-ev-slider")

                    Text(ManualText.bias(camera.manual.exposureBias))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.yellow)
                        .frame(minWidth: 38, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .background(.black.opacity(0.65), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 12)

            case .aspectRatio:
                optionRow {
                    ForEach(PhotoAspectRatio.allCases) { ratio in
                        optionPill(
                            ratio.label, selected: settings.photoAspectRatio == ratio,
                            id: "drawer-aspect-\(ratio.rawValue)"
                        ) {
                            update { $0.photoAspectRatio = ratio }
                            expanded = nil
                        }
                    }
                }

            case .timer:
                optionRow {
                    ForEach(CameraControls.timerSteps, id: \.self) { seconds in
                        optionPill(
                            seconds == 0 ? "Off" : "\(seconds)s", selected: camera.timer == seconds,
                            id: "drawer-timer-\(seconds)"
                        ) {
                            camera.timer = seconds
                            expanded = nil
                        }
                    }
                }

            case .resolution:
                optionRow {
                    ForEach(state.availableResolutions) { res in
                        optionPill(
                            res.label, selected: settings.photoResolution == res,
                            id: "drawer-res-\(res.rawValue)"
                        ) {
                            update { $0.photoResolution = res }
                            camera.settingsChanged()
                            expanded = nil
                        }
                    }
                }

            case .videoFrameRate:
                optionRow {
                    ForEach(CameraControls.videoFrameRates, id: \.self) { fps in
                        optionPill(
                            CameraControls.shortFrameRateLabel(fps), selected: settings.videoFrameRate == fps,
                            id: "drawer-fps-\(fps)"
                        ) {
                            update { $0.videoFrameRate = fps }
                            camera.settingsChanged()
                            expanded = nil
                        }
                    }
                }

            case .proVideoFormat:
                optionRow {
                    ForEach(ProVideoFormat.available(for: state.capabilities)) { format in
                        optionPill(
                            format.title, selected: settings.proVideoFormat == format,
                            id: "drawer-provideo-\(format.rawValue)"
                        ) {
                            update { $0.proVideoFormat = format }
                            camera.settingsChanged()
                            expanded = nil
                        }
                    }
                }

            case .cinematicAperture:
                HStack(spacing: 10) {
                    Text(CinematicRules.formatAperture(settings.cinematicAperture))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.yellow)
                        .frame(minWidth: 44, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { settings.cinematicAperture },
                            set: { value in
                                update { $0.cinematicAperture = CinematicRules.clampedAperture(value) }
                                camera.settingsChanged()
                            }),
                        in: CinematicRules.apertureRange
                    )
                    .tint(.yellow)
                    .accessibilityLabel("Cinematic depth f-stop")
                    .accessibilityIdentifier("drawer-cinematic-aperture-slider")
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .background(.black.opacity(0.65), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 12)

            case .scopes:
                optionRow {
                    optionPill("Histogram", selected: settings.showHistogram, id: "drawer-scope-histogram") {
                        update { $0.showHistogram.toggle() }
                        camera.settingsChanged()
                    }
                    optionPill("Waveform", selected: settings.showWaveform, id: "drawer-scope-waveform") {
                        update { $0.showWaveform.toggle() }
                        camera.settingsChanged()
                    }
                    optionPill("AirPods Mic", selected: settings.allowAirPodsMic, id: "drawer-airpods-mic") {
                        update { $0.allowAirPodsMic.toggle() }
                        camera.settingsChanged()
                    }
                }

            case .timeLapseInterval:
                optionRow {
                    ForEach([0.0, 0.5, 1, 2, 5, 10], id: \.self) { seconds in
                        optionPill(
                            seconds == 0 ? "Auto" : CameraMode.intervalText(seconds),
                            selected: settings.timeLapseInterval == seconds,
                            id: "drawer-tl-\(Int(seconds * 10))"
                        ) {
                            update { $0.timeLapseInterval = seconds }
                            camera.settingsChanged()
                            expanded = nil
                        }
                    }
                }
            }
        }
    }

    private func optionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 12)
        }
        .frame(height: 44)
    }

    private func optionPill(_ text: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.bold().monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .background(selected ? Color.yellow : Color.black.opacity(0.65), in: .capsule)
        }
        .accessibilityIdentifier(id)
    }

    private func drawerChip(
        symbol: String?, text: String, active: Bool, label: String, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.caption.bold()) }
                Text(text).font(.caption2.bold().monospacedDigit()).lineLimit(1).fixedSize()
            }
            .foregroundStyle(active ? .yellow : .white)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(.black.opacity(0.65), in: .capsule)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var flashSymbol: String {
        switch settings.flash {
        case .auto: "bolt.badge.automatic"
        case .on: "bolt.fill"
        case .off: "bolt.slash"
        }
    }
}
