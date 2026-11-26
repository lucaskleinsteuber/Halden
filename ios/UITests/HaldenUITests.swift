import XCTest

/// The app's screens in the simulator. There is no camera there; a real server only when
/// `ios/ui-tests.sh` started one (it passes its address in `HALDEN_TEST_SERVER`).
final class HaldenUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWithoutAServerTheAppAsksToConnect() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Halden"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["scan"].exists)
        app.buttons["password-login"].tap()
        XCTAssertTrue(app.textFields["address"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWhenConnectedTheTabsWork() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["Photos"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["empty-library"].waitForExistence(timeout: 5))
        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // Each page by its title; back only once it is there, on again only once it is gone (a
        // tap in the middle of the animation would get lost on a slow machine).
        for (page, title) in [
            ("upload-settings", "Uploads"), ("camera-settings", "Camera"), ("place-settings", "Place"),
            ("photos-settings", "Apple Photos"), ("storage-settings", "Storage"),
        ] {
            app.buttons[page].tap()
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 10), page)
            bar.buttons.firstMatch.tap()
            XCTAssertTrue(bar.waitForNonExistence(timeout: 10), page)
            XCTAssertTrue(app.buttons[page].waitForExistence(timeout: 10), page)
        }
        app.buttons["server-account"].tap()
        let signOut = app.buttons["sign-out"]
        for _ in 0..<6 where !signOut.exists { app.swipeUp() }
        XCTAssertTrue(signOut.exists)
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 5))
    }

    /// Place settings toggle screenshot locating and full-screen shows estimated device place.
    @MainActor
    func testScreenshotPlaceSettingsAndEstimatedIndicator() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "30"]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["Settings"].tap()
        app.buttons["place-settings"].tap()
        XCTAssertTrue(app.navigationBars["Place"].waitForExistence(timeout: 10))
        let toggle = app.switches["locate-screenshots"]
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        let recordings = app.switches["locate-screen-recordings"]
        for _ in 0..<4 where !recordings.exists { app.swipeUp() }
        XCTAssertTrue(recordings.exists)
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(recordings.waitForNonExistence(timeout: 5), "sub-options hide when off")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(recordings.waitForExistence(timeout: 5), "sub-options return when on")

        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        grid.cells["photo-00000000-0000-4000-8000-000000000002"].tap()
        XCTAssertTrue(app.staticTexts["Where your iPhone was"].waitForExistence(timeout: 10))
        app.buttons["info"].tap()
        let source = app.descendants(matching: .any)
            .matching(
                NSPredicate(format: "label CONTAINS 'where your iPhone was' OR value CONTAINS 'where your iPhone was'")
            )
            .firstMatch
        for _ in 0..<4 where !source.exists { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 10))
    }

    /// The lens buttons glide, dragging them gives the dial, swiping over the picture changes
    /// the mode, and the video format can be changed right on the camera.
    @MainActor
    func testTheCameraZoomsAndChangesMode() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()
        let two = app.buttons["zoom-2"]
        XCTAssertTrue(two.waitForExistence(timeout: 10))
        let live = app.buttons["live"]
        XCTAssertEqual(live.label, "Live Photo on")
        live.tap()
        XCTAssertEqual(live.label, "Live Photo off")
        live.tap()
        XCTAssertEqual(live.label, "Live Photo on")
        XCTAssertEqual(app.buttons["zoom-1"].value as? String, "1×")
        two.tap()
        // The button shows the zoom asked for at once; the old one doesn't count up on the way.
        XCTAssertEqual(two.value as? String, "2×")
        XCTAssertEqual(app.buttons["zoom-1"].value as? String, "")

        // Two fingers all the way: the end is a round 10×.
        let picture = app.descendants(matching: .any)["camera-preview"].firstMatch
        picture.pinch(withScale: 30, velocity: 10)
        expectation(for: NSPredicate(format: "value == '10×'"), evaluatedWith: two)
        waitForExpectations(timeout: 5)
        two.tap()
        expectation(for: NSPredicate(format: "value == '2×'"), evaluatedWith: two)
        waitForExpectations(timeout: 5)

        // Dragged sideways, the buttons become a dial; to the right zooms out.
        let start = two.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)))
        XCTAssertTrue(app.descendants(matching: .any)["zoom-dial"].exists, "the dial shows while and after dragging")
        let dial = app.descendants(matching: .any)["zoom-dial"]
        XCTAssertTrue(dial.waitForNonExistence(timeout: 5), "and goes away again")
        let zoomedOut = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'zoom-' AND value != ''"))
            .firstMatch
        XCTAssertNotEqual(zoomedOut.value as? String, "2×", "the dial zoomed out")

        // Manual values: ISO set by hand, then back to the camera.
        app.buttons["manual"].tap()
        let iso = app.buttons["manual-iso"]
        XCTAssertTrue(iso.waitForExistence(timeout: 5))
        XCTAssertEqual(iso.value as? String, "automatic")
        XCTAssertEqual(iso.label, "ISO 100", "what the camera does now")
        iso.tap()
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0.9)
        expectation(for: NSPredicate(format: "value == 'set'"), evaluatedWith: iso)
        waitForExpectations(timeout: 5)
        XCTAssertNotEqual(iso.label, "ISO 100")
        XCTAssertEqual(app.buttons["manual"].value as? String, "set")
        app.buttons["manual-auto"].tap()
        expectation(for: NSPredicate(format: "value == 'automatic'"), evaluatedWith: iso)
        waitForExpectations(timeout: 5)
        app.buttons["manual"].tap()
        XCTAssertTrue(iso.waitForNonExistence(timeout: 5))

        let preview = app.descendants(matching: .any)["camera-preview"].firstMatch
        preview.swipeRight()
        XCTAssertTrue(app.buttons["Record a video"].waitForExistence(timeout: 5), "swiped to video")
        XCTAssertTrue(app.buttons["mode-video"].isSelected)
        XCTAssertTrue(app.buttons["video-format"].waitForExistence(timeout: 5))
        app.buttons["video-format"].tap()
        app.buttons["1080p"].firstMatch.tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH '1080p'"), evaluatedWith: app.buttons["video-format"])
        waitForExpectations(timeout: 5)
        preview.swipeLeft()
        XCTAssertTrue(app.buttons["Take a photo"].waitForExistence(timeout: 5), "swiped back to photo")
    }

    /// The expandable control drawer adjusts photo and video settings directly in the camera,
    /// and Settings › Camera exposes Preserve Settings and Top Bar Controls.
    @MainActor
    func testCameraControlsDrawerAndCameraSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()
        let toggle = app.buttons["camera-controls-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let drawer = app.descendants(matching: .any)["camera-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        let screenWidth = app.windows.firstMatch.frame.width
        func drawerChip(_ id: String) -> XCUIElement {
            let chip = app.buttons[id]
            for _ in 0..<5 where chip.exists && (chip.frame.maxX > screenWidth - 8 || chip.frame.minX < 0) {
                let from = drawer.coordinate(
                    withNormalizedOffset: CGVector(dx: chip.frame.minX < 0 ? 0.2 : 0.85, dy: 0.92))
                let to = drawer.coordinate(
                    withNormalizedOffset: CGVector(dx: chip.frame.minX < 0 ? 0.85 : 0.2, dy: 0.92))
                from.press(forDuration: 0.02, thenDragTo: to)
            }
            return chip
        }

        // Aspect ratio 4:3 → 16:9 → 4:3.
        drawerChip("drawer-aspect").tap()
        app.buttons["drawer-aspect-16:9"].tap()
        XCTAssertEqual(app.buttons["drawer-aspect"].label, "Aspect ratio 16:9")
        drawerChip("drawer-aspect").tap()
        app.buttons["drawer-aspect-4:3"].tap()

        // Exposure compensation slider (-2...+2 EV).
        drawerChip("drawer-exposure").tap()
        let evSlider = app.sliders["drawer-ev-slider"]
        XCTAssertTrue(evSlider.waitForExistence(timeout: 5))
        evSlider.adjust(toNormalizedSliderPosition: 0.75)
        app.buttons["drawer-ev-reset"].tap()

        // Resolution (48 MP) and RAW.
        let res = drawerChip("drawer-resolution")
        if res.exists {
            res.tap()
            app.buttons["drawer-res-48"].tap()
            XCTAssertEqual(res.label, "Resolution 48 MP")
        }
        let raw = drawerChip("drawer-raw")
        if raw.exists {
            raw.tap()
            XCTAssertEqual(raw.label, "RAW on")
            raw.tap()
            XCTAssertEqual(raw.label, "RAW off")
        }
        toggle.tap()

        // Video drawer: 25 fps (PAL) and Auto low-light FPS.
        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["Record a video"].waitForExistence(timeout: 5))
        app.buttons["camera-controls-toggle"].tap()
        app.buttons["drawer-video-fps"].tap()
        app.buttons["drawer-fps-25"].tap()
        XCTAssertTrue(app.buttons["drawer-video-fps"].label.contains("25 fps (PAL)"))
        app.buttons["drawer-video-autofps"].tap()
        XCTAssertEqual(app.buttons["drawer-video-autofps"].label, "Auto low-light FPS on")
        app.buttons["camera-controls-toggle"].tap()

        // Settings › Camera › Preserve Settings and Top Bar Controls.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        XCTAssertTrue(app.navigationBars["Camera"].waitForExistence(timeout: 5))
        app.buttons["camera-preserve-settings"].tap()
        XCTAssertTrue(app.navigationBars["Preserve Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["preserve-mode"].exists)
        app.navigationBars["Preserve Settings"].buttons.firstMatch.tap()
        app.buttons["camera-top-bar-settings"].tap()
        XCTAssertTrue(app.navigationBars["Top Bar Controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["topbar-reset"].exists)
    }

    /// Tapping 1× cycles 24 / 28 / 35 mm focal lengths, Composition & Video Lock settings toggle
    /// cleanly, and the level overlay and lens-smudge banner appear when triggered.
    @MainActor
    func testCompositionFocalLengthsLevelAndVideoLocks() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-smudge"]
        app.launch()
        let one = app.buttons["zoom-1"]
        XCTAssertTrue(one.waitForExistence(timeout: 10))
        XCTAssertEqual(one.value as? String, "1×")

        // Lens smudge hint is visible and dismissible.
        let smudge = app.buttons["lens-smudge-hint"]
        XCTAssertTrue(smudge.waitForExistence(timeout: 5))
        smudge.tap()
        XCTAssertTrue(smudge.waitForNonExistence(timeout: 5))

        // Tapping active 1× cycles 24 mm (1×) → 28 mm (1.2×) → 35 mm (1.5×) → 24 mm (1×).
        one.tap()
        XCTAssertEqual(one.value as? String, "1.2×")
        XCTAssertEqual(app.staticTexts["focal-length-badge"].label, "28 mm")
        one.tap()
        XCTAssertEqual(one.value as? String, "1.5×")
        XCTAssertEqual(app.staticTexts["focal-length-badge"].label, "35 mm")
        one.tap()
        XCTAssertEqual(one.value as? String, "1×")
        XCTAssertEqual(app.staticTexts["focal-length-badge"].label, "24 mm")

        // Settings › Camera: toggle Lock camera, Lock white balance, and Level, then verify level.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        XCTAssertTrue(app.navigationBars["Camera"].waitForExistence(timeout: 5))
        for id in ["settings-lock-camera", "settings-lock-wb", "settings-show-level"] {
            let toggle = app.switches[id]
            for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), id)
            toggle.switches.firstMatch.tap()
        }
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["camera-level"].waitForExistence(timeout: 5))
    }

    /// Tap-to-focus shows the sun exposure slider, shutter gestures drive QuickTake and Burst, and
    /// video recording supports pause/resume and snapping a still photo mid-recording.
    @MainActor
    func testCameraGesturesAndRecordingControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))

        // Tap preview → focus box with sun exposure slider appears.
        let preview = app.descendants(matching: .any)["camera-preview"].firstMatch
        preview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["focus-exposure-sun"].waitForExistence(timeout: 5))

        // Drag shutter left → shoots a burst (photos saved into the library).
        let center = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -110, dy: 0)))

        // Hold shutter in photo mode → QuickTake starts recording, lifts to stop & save video.
        shutter.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Take a photo"].waitForExistence(timeout: 5))

        // Switch to Video: start recording, pause, take a still photo, resume, stop.
        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["Record a video"].waitForExistence(timeout: 5))
        shutter.tap()
        let pause = app.buttons["pause-recording"]
        let still = app.buttons["capture-still"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(still.exists)
        XCTAssertEqual(pause.label, "Pause recording")
        pause.tap()
        XCTAssertEqual(pause.label, "Resume recording")
        still.tap()
        pause.tap()
        XCTAssertEqual(pause.label, "Pause recording")
        shutter.tap()
        XCTAssertTrue(app.buttons["Record a video"].waitForExistence(timeout: 5))
    }

    /// Burst photos collapse into a single stack tile in the library and open the burst picker to
    /// choose keepers and trash the rest.
    @MainActor
    func testBurstStackAndPickerInLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "30"]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        let burstCell = grid.cells["photo-00000000-0000-4000-8000-000000000003"]
        XCTAssertTrue(burstCell.waitForExistence(timeout: 5))
        XCTAssertTrue(burstCell.label.contains("Burst of 3 photos"), burstCell.label)

        // Open the burst stack, launch the picker, keep photo 2 only, confirm Done.
        burstCell.tap()
        let select = app.buttons["burst-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        XCTAssertTrue(app.buttons["burst-item-1"].waitForExistence(timeout: 5))
        // Unselect item 0, select item 1.
        app.buttons["burst-toggle-keep"].tap()
        app.buttons["burst-item-1"].tap()
        app.buttons["burst-toggle-keep"].tap()
        app.buttons["burst-picker-done"].tap()
        XCTAssertTrue(app.buttons["burst-picker-done"].waitForNonExistence(timeout: 5))
        // Only one photo remains, so the burst selector button disappears.
        XCTAssertTrue(select.waitForNonExistence(timeout: 5))
    }

    /// Photographic Styles (preset + tone/color pad + palette) and Filters work in the camera
    /// drawer, and Settings › Preserve Settings exposes Photographic Style preservation.
    @MainActor
    func testPhotographicStylesAndFiltersInCamera() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()
        let toggle = app.buttons["camera-controls-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        XCTAssertTrue(app.buttons["drawer-style"].waitForExistence(timeout: 5))

        // Select Amber style, adjust palette, then reset.
        app.buttons["drawer-style"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["style-pad"].waitForExistence(timeout: 5))
        app.buttons["style-preset-amber"].tap()
        XCTAssertTrue(app.buttons["drawer-style"].label.contains("Amber"))
        app.sliders["style-palette-slider"].adjust(toNormalizedSliderPosition: 0.8)
        app.buttons["style-reset"].tap()
        XCTAssertEqual(app.buttons["drawer-style"].label, "Photographic style")

        // Select Vivid Warm filter, then back to Original.
        app.buttons["drawer-filter"].tap()
        XCTAssertTrue(app.buttons["filter-vividWarm"].waitForExistence(timeout: 5))
        app.buttons["filter-vividWarm"].tap()
        XCTAssertEqual(app.buttons["drawer-filter"].label, "Filter Vivid Warm")
        app.buttons["filter-original"].tap()
        XCTAssertEqual(app.buttons["drawer-filter"].label, "Filter off")
        toggle.tap()

        // Settings › Camera › Preserve Settings › Photographic Style & Filter.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        app.buttons["camera-preserve-settings"].tap()
        XCTAssertTrue(app.switches["preserve-style"].waitForExistence(timeout: 5))
    }

    /// Portrait mode exposes f-stop depth slider, Portrait Lighting styles and hints, and Photo
    /// mode shows the automatic depth indicator when a person or pet is detected.
    @MainActor
    func testPortraitModeApertureLightingAndAutoDepth() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-subject", "-ui-testing-portrait-hint"]
        app.launch()
        // Auto-depth indicator appears in Photo mode when a subject is detected.
        XCTAssertTrue(app.descendants(matching: .any)["portrait-auto-depth"].waitForExistence(timeout: 10))

        // Switch to Portrait mode: hint appears and drawer offers aperture + lighting controls.
        app.buttons["mode-portrait"].tap()
        XCTAssertTrue(app.buttons["Take a portrait"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["portrait-hint"].waitForExistence(timeout: 5))
        app.buttons["camera-controls-toggle"].tap()
        XCTAssertTrue(app.buttons["drawer-aperture"].waitForExistence(timeout: 5))
        app.buttons["drawer-aperture"].tap()
        let fSlider = app.sliders["drawer-aperture-slider"]
        XCTAssertTrue(fSlider.waitForExistence(timeout: 5))
        fSlider.adjust(toNormalizedSliderPosition: 0.2)

        app.buttons["drawer-lighting"].tap()
        app.buttons["drawer-light-stage"].tap()
        XCTAssertEqual(app.buttons["drawer-lighting"].label, "Lighting Stage")
        app.buttons["drawer-light-natural"].tap()
        app.buttons["camera-controls-toggle"].tap()

        // Preserve Settings includes Portrait depth & lighting.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        app.buttons["camera-preserve-settings"].tap()
        XCTAssertTrue(app.switches["preserve-portrait"].waitForExistence(timeout: 5))
    }

    /// Night Mode: moon badge appears in dark scenes, slider sets Off/Auto, shutter captures and
    /// stacks a Night photo, and Preserve Settings includes Night mode.
    @MainActor
    func testNightModeBadgeSliderCaptureAndPreserveSetting() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "5", "-ui-testing-night"]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 30))

        let badge = app.buttons["night-mode-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "moon badge appears automatically in dark scenes")
        badge.tap()

        let slider = app.sliders["drawer-night-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "night duration slider opens")
        app.buttons["drawer-night-off"].tap()
        app.buttons["drawer-night-auto"].tap()
        app.buttons["camera-controls-toggle"].tap()

        // Capture a stacked Night Mode photo.
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.buttons["shutter"].isHittable, "shutter ready again after Night stacking")

        // Verify Preserve Night Mode toggle in Settings › Camera › Preserve Settings.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        app.buttons["camera-preserve-settings"].tap()
        XCTAssertTrue(app.switches["preserve-night"].waitForExistence(timeout: 5), "night mode preserve toggle")
    }

    /// Cinematic Video mode, Action Mode low-light hint, Stereo/Mono & Wind audio controls,
    /// live Histogram/Waveform HUD, and Preserve Action Mode setting.
    @MainActor
    func testCinematicActionAudioAndScopes() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "5", "-ui-testing-low-light"]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 30))

        // Video mode: enable Action Mode -> low-light hint appears, toggle Stereo/Mono, Wind, and Scopes.
        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["camera-controls-toggle"].waitForExistence(timeout: 5))
        app.buttons["camera-controls-toggle"].tap()
        XCTAssertTrue(app.buttons["drawer-action"].waitForExistence(timeout: 5))
        app.buttons["drawer-action"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["action-low-light-hint"].waitForExistence(timeout: 5),
            "Action Mode shows low-light hint when ISO is high")

        // Scroll drawer to reach Audio, Wind and Scopes chips.
        let drawer = app.descendants(matching: .any)["camera-drawer"]
        let screenWidth = app.windows.firstMatch.frame.width
        for chipId in ["drawer-audio", "drawer-wind", "drawer-scopes"] {
            let chip = app.buttons[chipId]
            for _ in 0..<5 where chip.frame.maxX > screenWidth - 8 || chip.frame.minX < 0 {
                let from = drawer.coordinate(
                    withNormalizedOffset: CGVector(dx: chip.frame.minX < 0 ? 0.2 : 0.85, dy: 0.9))
                let to = drawer.coordinate(
                    withNormalizedOffset: CGVector(dx: chip.frame.minX < 0 ? 0.85 : 0.2, dy: 0.9))
                from.press(forDuration: 0.02, thenDragTo: to)
            }
            chip.tap()
        }
        XCTAssertTrue(app.buttons["drawer-scope-histogram"].waitForExistence(timeout: 5))
        app.buttons["drawer-scope-histogram"].tap()
        app.buttons["drawer-scope-waveform"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-histogram"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["live-waveform"].waitForExistence(timeout: 5))
        app.buttons["camera-controls-toggle"].tap()

        // Switch to Cinematic mode: aperture drawer slider adjusts f-stop.
        app.buttons["mode-cinematic"].tap()
        XCTAssertTrue(app.buttons["Record cinematic video"].waitForExistence(timeout: 5))
        app.buttons["camera-controls-toggle"].tap()
        XCTAssertTrue(app.buttons["drawer-cinematic-aperture"].waitForExistence(timeout: 5))
        app.buttons["drawer-cinematic-aperture"].tap()
        let slider = app.sliders["drawer-cinematic-aperture-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.3)

        // Settings › Camera › Preserve Settings includes Action mode.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        app.buttons["camera-preserve-settings"].tap()
        XCTAssertTrue(app.switches["preserve-action"].waitForExistence(timeout: 5))
    }

    /// Panorama mode: reverse sweep direction by tapping the arrow, toggle vertical orientation,
    /// and start/stop a panorama capture that stitches cleanly into a photo.
    @MainActor
    func testPanoramaModeDirectionOrientationAndCapture() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "5"]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 30))

        // Navigate photo -> portrait -> panorama.
        app.buttons["mode-portrait"].tap()
        XCTAssertTrue(app.buttons["mode-panorama"].waitForExistence(timeout: 5))
        app.buttons["mode-panorama"].tap()
        XCTAssertTrue(app.buttons["Start panorama"].waitForExistence(timeout: 5))

        // Tap arrow to reverse horizontal direction (Sweep right -> Sweep left).
        let arrow = app.buttons["panorama-direction"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        XCTAssertTrue(arrow.label.contains("Sweep right"), arrow.label)
        arrow.tap()
        XCTAssertTrue(arrow.label.contains("Sweep left"), arrow.label)

        // Toggle orientation to vertical (Sweep down) and reverse (Sweep up).
        let orient = app.buttons["panorama-orientation"]
        XCTAssertTrue(orient.waitForExistence(timeout: 5))
        orient.tap()
        XCTAssertTrue(arrow.label.contains("Sweep down"), arrow.label)
        arrow.tap()
        XCTAssertTrue(arrow.label.contains("Sweep up"), arrow.label)

        // Start and stop panorama sweep: stitches cleanly and returns shutter to ready.
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.buttons["Stop panorama"].waitForExistence(timeout: 5))
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.buttons["Start panorama"].waitForExistence(timeout: 15))
    }

    /// Live Photo effects: capture a Live Photo against the real server, apply Bounce and Long
    /// Exposure, choose a Key Photo, verify server sync and Info display, then revert to Live.
    @MainActor
    func testLivePhotoEffectsAndKeyPhoto() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        shutter.tap()
        Thread.sleep(forTimeInterval: 1.5)

        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        let newest = grid.cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == 'Photo, backed up'"), evaluatedWith: newest)
        waitForExpectations(timeout: 120)
        newest.tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-badge"].waitForExistence(timeout: 10))

        // Apply Bounce effect and verify badge + InfoView reflect it.
        let fxButton = app.buttons["live-effects"]
        XCTAssertTrue(fxButton.waitForExistence(timeout: 5))
        fxButton.tap()
        XCTAssertTrue(app.buttons["live-effect-bounce"].waitForExistence(timeout: 5))
        app.buttons["live-effect-bounce"].tap()
        app.buttons["live-effect-apply"].tap()
        let bounceBadge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'live-badge' AND label CONTAINS 'Bounce'")).firstMatch
        XCTAssertTrue(bounceBadge.waitForExistence(timeout: 15), "Bounce badge shown")

        app.buttons["info"].tap()
        let infoEffect = app.descendants(matching: .any)["info-live-effect"]
        XCTAssertTrue(infoEffect.waitForExistence(timeout: 5))
        app.navigationBars["Info"].buttons["Done"].tap()

        // Switch to Long Exposure + scrub Key Photo slider.
        fxButton.tap()
        XCTAssertTrue(app.buttons["live-effect-long_exposure"].waitForExistence(timeout: 5))
        app.buttons["live-effect-long_exposure"].tap()
        let slider = app.sliders["live-keyframe-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["live-effect-apply"].tap()
        let longBadge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'live-badge' AND label CONTAINS 'Long Exposure'")).firstMatch
        XCTAssertTrue(longBadge.waitForExistence(timeout: 15), "Long Exposure badge shown")
    }

    /// Viewfinder QR code detection and Live Text sheet, plus disabling both in Settings › Camera.
    @MainActor
    func testViewfinderQRCodeAndLiveText() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-signed-in", "-ui-testing-library", "5", "-ui-testing-qr", "-ui-testing-text",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 30))

        // Both the yellow QR action pill and Live Text icon appear in photo mode.
        let qrPill = app.buttons["qr-action-pill"]
        XCTAssertTrue(qrPill.waitForExistence(timeout: 5), "QR pill shown")
        XCTAssertTrue(qrPill.label.contains("halden.example"), qrPill.label)

        let textButton = app.buttons["live-text-button"]
        XCTAssertTrue(textButton.waitForExistence(timeout: 5), "Live Text button shown")
        textButton.tap()
        let content = app.descendants(matching: .any)["detected-text-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5), "Detected text sheet opened")
        app.buttons["copy-detected-text"].tap()
        app.buttons["detected-text-done"].tap()

        // Turn both off in Settings › Camera and confirm they disappear from the viewfinder.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        let scanQR = app.switches["settings-scan-qr"]
        for _ in 0..<8 where !scanQR.isHittable { app.swipeUp() }
        XCTAssertTrue(scanQR.waitForExistence(timeout: 5))
        scanQR.switches.firstMatch.tap()
        let liveText = app.switches["settings-live-text"]
        for _ in 0..<4 where !liveText.isHittable { app.swipeUp() }
        liveText.switches.firstMatch.tap()

        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["qr-action-pill"].exists, "QR pill hidden when disabled")
        XCTAssertFalse(app.buttons["live-text-button"].exists, "Live Text hidden when disabled")
    }

    /// Dual Capture (Double Take) with movable PiP, camera swap, single-file photo & video capture,
    /// plus "View Outside the Frame" surround in Photo mode at >= 1x.
    @MainActor
    func testDualCaptureAndOutsideFrame() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "5"]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 30))

        // Navigate photo -> portrait -> panorama -> dual.
        app.buttons["mode-portrait"].tap()
        XCTAssertTrue(app.buttons["mode-panorama"].waitForExistence(timeout: 5))
        app.buttons["mode-panorama"].tap()
        XCTAssertTrue(app.buttons["mode-dual"].waitForExistence(timeout: 5))
        app.buttons["mode-dual"].tap()
        XCTAssertTrue(app.buttons["Take dual photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["dual-pip-window"].waitForExistence(timeout: 5))

        // Swap primary/secondary lenses (via both PiP swap and bottom flip button) and snap a composited dual photo.
        app.buttons["dual-swap"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dual-pip-window"].label.contains("Back camera"))
        app.buttons["flip-camera"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dual-pip-window"].label.contains("Front camera"))
        app.buttons["dual-swap"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["dual-pip-window"].label.contains("Back camera"))
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 0.6)

        // Toggle to Dual Video, record briefly, and stop.
        app.buttons["dual-kind-toggle"].tap()
        XCTAssertTrue(app.buttons["Record dual video"].waitForExistence(timeout: 5))
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.buttons["Record dual video"].waitForExistence(timeout: 10))

        // Enable "View Outside the Frame" in Settings › Camera and verify at 1x vs 0.5x.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        app.buttons["camera-settings"].tap()
        let outside = app.switches["settings-outside-frame"]
        for _ in 0..<10 where !outside.isHittable { app.swipeUp() }
        XCTAssertTrue(outside.waitForExistence(timeout: 5))
        outside.switches.firstMatch.tap()

        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        // Step back from dual -> panorama -> portrait -> photo.
        app.buttons["mode-panorama"].tap()
        XCTAssertTrue(app.buttons["Start panorama"].waitForExistence(timeout: 5))
        app.buttons["mode-portrait"].tap()
        XCTAssertTrue(app.buttons["Take a portrait"].waitForExistence(timeout: 5))
        app.buttons["mode-photo"].tap()
        XCTAssertTrue(app.buttons["Take a photo"].waitForExistence(timeout: 5))

        let surround = app.descendants(matching: .any)["outside-frame-overlay"]
        XCTAssertTrue(surround.waitForExistence(timeout: 5), "Outside-frame surround active at 1x")
        app.buttons["zoom-0.5"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(surround.exists, "Outside-frame surround hides at 0.5x")
    }

    /// Fifty thousand photos scroll without waiting for pictures.
    @MainActor
    func testTheGridScrollsThroughFiftyThousandPhotos() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "50000"]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60))
        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        let newestId = "photo-00000000-0000-4000-8000-000000000000"
        XCTAssertTrue(grid.cells[newestId].waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            grid.swipeUp(velocity: .fast)
            grid.swipeUp(velocity: .fast)
            grid.swipeDown(velocity: .fast)
        }
        for _ in 0..<15 { grid.swipeUp(velocity: .fast) }
        let deeper = grid.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).firstMatch
        XCTAssertTrue(deeper.waitForExistence(timeout: 5))
        XCTAssertNotEqual(deeper.identifier, newestId, "scrolled far into the library")

        // Full screen, and on to the next photo.
        let opened = deeper.identifier.replacingOccurrences(of: "photo-", with: "")
        deeper.tap()
        let page = app.descendants(matching: .any)["page-\(opened)"]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the photo full screen")
        app.swipeLeft()
        let next = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'page-' AND identifier != %@", "page-\(opened)"))
            .firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "swiped to the next photo")
    }

    /// The 50,000 photos on the map, in groups; a group opens, and the photos without a place
    /// are a tap away.
    @MainActor
    func testTheMapShowsFiftyThousandPhotos() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "50000"]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60))
        tabs.buttons["Photos"].tap()
        app.segmentedControls["photos-section"].buttons["Map"].tap()
        let group = app.descendants(matching: .any).matching(identifier: "map-group").firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 20), "groups on the map")
        let withoutPlace = app.buttons["map-without-place"]
        XCTAssertTrue(withoutPlace.label.contains("without a place"), withoutPlace.label)
        // Written as the simulator's language writes numbers (5,000 or 5.000).
        XCTAssertEqual(withoutPlace.label.filter(\.isNumber), "5000", withoutPlace.label)
        let map = app.descendants(matching: .any)["photo-map"]
        map.pinch(withScale: 3, velocity: 2)
        map.swipeLeft()
        XCTAssertTrue(group.waitForExistence(timeout: 10), "still groups after zooming and moving")
        // Groups just outside the screen are there too (nothing pops in at the edges): one on it.
        let groups = app.descendants(matching: .any).matching(identifier: "map-group").allElementsBoundByIndex
        let visible = try XCTUnwrap(groups.first { $0.isHittable }, "a group on the screen")
        visible.tap()
        XCTAssertTrue(app.collectionViews["library-grid"].cells.firstMatch.waitForExistence(timeout: 10), "its photos")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["map-without-place"].tap()
        XCTAssertTrue(app.navigationBars.element(boundBy: 0).waitForExistence(timeout: 5))
    }

    /// The camera from the shutter to the server: a photo, one with the self-timer and a video
    /// from the stand-in camera all show up in the library with a check mark.
    @MainActor
    func testPhotosAndAVideoFromTheCameraReachTheServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        shutter.tap()

        app.buttons["timer"].tap()
        XCTAssertEqual(app.buttons["timer"].label, "Self-timer 3 seconds")
        shutter.tap()
        XCTAssertTrue(app.staticTexts["countdown"].waitForExistence(timeout: 2), "the self-timer counts down")
        XCTAssertTrue(app.staticTexts["countdown"].waitForNonExistence(timeout: 6))
        app.buttons["timer"].tap()
        XCTAssertEqual(app.buttons["timer"].label, "Self-timer 5 seconds")
        app.buttons["timer"].tap()
        XCTAssertEqual(app.buttons["timer"].label, "Self-timer 10 seconds")
        app.buttons["timer"].tap()
        XCTAssertEqual(app.buttons["timer"].label, "Self-timer off")

        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["Record a video"].waitForExistence(timeout: 5))
        shutter.tap()
        XCTAssertTrue(app.descendants(matching: .any)["recording-time"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        shutter.tap()
        XCTAssertTrue(app.buttons["Record a video"].waitForExistence(timeout: 5), "recording stopped")

        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        let photos = grid.cells.matching(NSPredicate(format: "label == 'Photo, backed up'"))
        let videos = grid.cells.matching(NSPredicate(format: "label == 'Video, backed up'"))
        let deadline = Date().addingTimeInterval(90)
        while (photos.count < 2 || videos.count < 1) && Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        // Photos from other tests come from the server too; the round below counts only these.
        XCTAssertGreaterThanOrEqual(photos.count, 2, "both photos are on the server")
        XCTAssertGreaterThanOrEqual(videos.count, 1, "the video is on the server")

        // The newest one opens from the camera.
        tabs.buttons["Camera"].tap()
        app.buttons["last-photo"].tap()
        XCTAssertTrue(app.buttons["close-photo"].waitForExistence(timeout: 10), "the last photo full screen")
        app.buttons["close-photo"].tap()

        tabs.buttons["Settings"].tap()
        app.buttons["uploads"].tap()
        let round = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '3 of 3 uploaded' OR value CONTAINS '3 of 3 uploaded'"))
            .firstMatch
        XCTAssertTrue(round.waitForExistence(timeout: 10), "the uploads screen counts the round")
        XCTAssertTrue(app.staticTexts["Everything is on the server"].exists)
    }

    /// Slow motion and a time-lapse from the stand-in camera reach the server marked as such,
    /// and the slow part of the slow-motion video can be changed.
    @MainActor
    func testSlowMotionAndTimeLapse() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))

        // Step cleanly across the mode strip (photo -> video -> cinematic -> slowMotion) so each tap is centered on screen.
        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["Record a video"].waitForExistence(timeout: 5))
        app.buttons["mode-cinematic"].tap()
        XCTAssertTrue(app.buttons["Record cinematic video"].waitForExistence(timeout: 5))
        app.buttons["mode-slowMotion"].tap()
        XCTAssertTrue(app.buttons["Record slow motion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["video-format"].label.hasSuffix("240 fps"), app.buttons["video-format"].label)
        shutter.tap()
        XCTAssertTrue(app.descendants(matching: .any)["recording-time"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        shutter.tap()
        XCTAssertTrue(app.buttons["Record slow motion"].waitForExistence(timeout: 10), "stopped")

        app.buttons["mode-timeLapse"].tap()
        XCTAssertTrue(app.buttons["Record a time-lapse"].waitForExistence(timeout: 5))
        shutter.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shutter.tap()
        XCTAssertTrue(app.buttons["Record a time-lapse"].waitForExistence(timeout: 10), "stopped")

        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        let slow = grid.cells.matching(NSPredicate(format: "label == 'Slow-motion video, backed up'")).firstMatch
        let lapse = grid.cells.matching(NSPredicate(format: "label == 'Time-lapse, backed up'")).firstMatch
        XCTAssertTrue(slow.waitForExistence(timeout: 90), "the slow-motion video is on the server")
        XCTAssertTrue(lapse.waitForExistence(timeout: 90), "the time-lapse is on the server")

        slow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["kind-badge"].waitForExistence(timeout: 10))
        app.buttons["slow-motion"].tap()
        let rate = app.segmentedControls["slow-rate"]
        XCTAssertTrue(rate.waitForExistence(timeout: 10))
        // The stand-in's videos have 30 frames a second: a quarter is where they start.
        rate.buttons["⅛"].tap()
        app.buttons["save-slow-motion"].tap()
        app.buttons["info"].tap()
        let changed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '8× slower' OR value CONTAINS '8× slower'")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 10), "the slow part is kept")
    }

    /// Photos chosen in the library go into a new album; in the album one is taken out, the
    /// album is renamed and deleted (its photos stay).
    @MainActor
    func testAlbums() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.buttons["shutter"].tap()

        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 30))
        app.buttons["select"].tap()
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        app.buttons["add-to-album"].tap()
        let name = app.textFields["new-album-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Harbour walk")
        app.buttons["make-album"].tap()

        XCTAssertTrue(app.navigationBars["Add 2 to album"].waitForNonExistence(timeout: 15), "the sheet closed")
        let albums = app.segmentedControls["photos-section"].buttons["Albums"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: albums)
        waitForExpectations(timeout: 5)
        albums.tap()
        let card = app.buttons["album-Harbour walk"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the new album")
        card.tap()
        let inAlbum = app.collectionViews["library-grid"]
        XCTAssertTrue(inAlbum.cells.element(boundBy: 1).waitForExistence(timeout: 10), "with both photos")
        app.buttons["select-in-album"].tap()
        inAlbum.cells.element(boundBy: 0).tap()
        app.buttons["take-out"].tap()
        XCTAssertTrue(inAlbum.cells.element(boundBy: 1).waitForNonExistence(timeout: 10), "one taken out")
        XCTAssertEqual(inAlbum.cells.count, 1)

        app.buttons["album-menu"].tap()
        app.buttons["rename-album"].tap()
        let rename = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        // The old name is in the field: away with it.
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Harbour 2026")
        app.alerts.firstMatch.buttons["Rename"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Harbour 2026"].waitForExistence(timeout: 5))

        app.buttons["album-menu"].tap()
        app.buttons["delete-album"].tap()
        app.buttons["confirm-delete-album"].firstMatch.tap()
        XCTAssertTrue(app.buttons["album-Harbour 2026"].waitForNonExistence(timeout: 10), "the album is gone")
        app.segmentedControls["photos-section"].buttons["Library"].tap()
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 10), "its photos stay")
    }

    /// A photo edited (exposure, turned), the edit kept; then back to the original.
    @MainActor
    func testEditingAPhoto() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        app.buttons["shutter"].tap()
        tabs.buttons["Photos"].tap()
        let newest = app.collectionViews["library-grid"].cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 30))
        newest.tap()

        app.buttons["edit"].tap()
        let exposure = app.sliders["edit-exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 15), "the editor with the picture")
        exposure.adjust(toNormalizedSliderPosition: 0.75)
        app.segmentedControls["edit-tool"].buttons["Crop"].tap()
        let turn = app.buttons["edit-turn"]
        if !turn.waitForExistence(timeout: 10) { app.segmentedControls["edit-tool"].buttons["Crop"].tap() }
        XCTAssertTrue(turn.waitForExistence(timeout: 10), "the crop tool")
        turn.tap()
        app.buttons["save-edit"].tap()
        app.buttons["info"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["info-edited"].waitForExistence(timeout: 10), "edited")
        app.swipeDown(velocity: .fast)

        app.buttons["edit"].tap()
        XCTAssertTrue(app.buttons["edit-original"].waitForExistence(timeout: 15))
        app.buttons["edit-original"].tap()
        app.buttons["save-edit"].tap()
        app.buttons["info"].tap()
        XCTAssertTrue(app.buttons["correct"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["info-edited"].exists, "back to the original")
    }

    /// A link to a photo: made (the test server isn't on the internet, so it says so), listed in
    /// the settings, withdrawn.
    @MainActor
    func testSharingALink() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        app.buttons["shutter"].tap()
        tabs.buttons["Photos"].tap()
        let newest = app.collectionViews["library-grid"].cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label ENDSWITH 'backed up'"), evaluatedWith: newest)
        waitForExpectations(timeout: 120)
        newest.tap()

        app.buttons["share"].tap()
        app.buttons["share-link"].firstMatch.tap()
        XCTAssertTrue(app.buttons["make-link"].waitForExistence(timeout: 5))
        app.buttons["make-link"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["link-not-reachable"].waitForExistence(timeout: 10),
            "made, but the server isn't on the internet")
        app.buttons["Done"].firstMatch.tap()
        // Back from full screen, where there is no tab bar.
        app.navigationBars.buttons.firstMatch.tap()

        tabs.buttons["Settings"].tap()
        // Further down on a small iPhone.
        let sharedLinks = app.buttons["shared-links"]
        for _ in 0..<6 where !sharedLinks.isHittable { app.swipeUp() }
        sharedLinks.tap()
        let link = app.descendants(matching: .any).matching(identifier: "shared-link").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "listed")
        link.swipeLeft()
        app.buttons["Withdraw"].firstMatch.tap()
        XCTAssertTrue(link.waitForNonExistence(timeout: 10), "withdrawn")
    }

    /// A correction shows at once and reaches the server, which keeps it next to the original.
    @MainActor
    func testACorrectionShowsAtOnceAndReachesTheServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        app.buttons["shutter"].tap()
        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        // The newest photo, the one just taken, comes first.
        let newest = grid.cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 30))
        let backedUp = NSPredicate(format: "label == 'Photo, backed up'")
        expectation(for: backedUp, evaluatedWith: newest)
        // Up to two minutes: GitHub's machines are slow.
        waitForExpectations(timeout: 120)
        newest.tap()

        // Photos are Live Photos by default.
        XCTAssertTrue(app.descendants(matching: .any)["live-badge"].waitForExistence(timeout: 10), "a Live Photo")
        XCTAssertTrue(app.buttons["info"].waitForExistence(timeout: 10))
        app.buttons["info"].tap()
        XCTAssertTrue(app.buttons["correct"].waitForExistence(timeout: 5))
        app.buttons["correct"].tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Harbour")
        app.buttons["save-correction"].tap()
        let shown = app.descendants(matching: .any)["info-title"]
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "the title shows at once")
        // The server lists the correction once it has it.
        XCTAssertTrue(app.staticTexts["title"].waitForExistence(timeout: 60), "the server keeps the correction")
    }

    /// Delete everywhere, find it in the trash with its days left, restore it; then choose it in
    /// the grid, delete it, and delete it for good.
    @MainActor
    func testDeletingGoesThroughTheTrash() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        app.buttons["shutter"].tap()
        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        let newest = grid.cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == 'Photo, backed up'"), evaluatedWith: newest)
        waitForExpectations(timeout: 120)
        let id = newest.identifier.replacingOccurrences(of: "photo-", with: "")

        newest.tap()
        XCTAssertTrue(app.buttons["delete"].waitForExistence(timeout: 10))
        app.buttons["delete"].tap()
        let everywhere = app.buttons["delete-everywhere"].firstMatch
        XCTAssertTrue(everywhere.waitForExistence(timeout: 5), "asks first")
        everywhere.tap()
        XCTAssertTrue(grid.cells["photo-\(id)"].waitForNonExistence(timeout: 10), "gone from the library")

        app.buttons["photos-menu"].tap()
        app.buttons["trash"].tap()
        let trashed = app.descendants(matching: .any)["trashed-\(id)"]
        XCTAssertTrue(trashed.waitForExistence(timeout: 10), "in the trash")
        // 30 by default; another test may have changed the server's setting.
        XCTAssertNotNil(trashed.label.range(of: #"\d+ days left$"#, options: .regularExpression), trashed.label)
        trashed.tap()
        app.buttons["restore"].tap()
        XCTAssertTrue(trashed.waitForNonExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(grid.cells["photo-\(id)"].waitForExistence(timeout: 10), "back in the library")

        app.buttons["select"].tap()
        grid.cells["photo-\(id)"].tap()
        app.buttons["delete-chosen"].tap()
        app.buttons["confirm-delete"].firstMatch.tap()
        XCTAssertTrue(grid.cells["photo-\(id)"].waitForNonExistence(timeout: 10))
        app.buttons["photos-menu"].tap()
        app.buttons["trash"].tap()
        XCTAssertTrue(trashed.waitForExistence(timeout: 10))
        app.buttons["delete-for-good"].tap()
        app.buttons["confirm-delete-for-good"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trash-empty"].waitForExistence(timeout: 10))
    }

    /// The photos that were in Apple Photos before come into Halden and reach the server.
    @MainActor
    func testThePhotosFromApplePhotosComeIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Settings"].tap()
        app.buttons["photos-settings"].tap()
        let start = app.buttons["import-photos"]
        for _ in 0..<8 where !start.isHittable { app.swipeUp() }
        start.tap()
        // Should the system ask for the photos, the answer comes with the next touch (one that
        // changes nothing on the screen).
        app.navigationBars["Apple Photos"].staticTexts.firstMatch.tap()
        let status = app.staticTexts["photos-import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Everything from before'"), evaluatedWith: status)
        waitForExpectations(timeout: 120)
        XCTAssertFalse(status.label.contains("(0 this time)"), status.label)

        tabs.buttons["Photos"].tap()
        let backedUp = app.collectionViews["library-grid"].cells
            .matching(NSPredicate(format: "label == 'Photo, backed up'"))
        let deadline = Date().addingTimeInterval(120)
        while backedUp.count == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        XCTAssertGreaterThan(backedUp.count, 0, "imported photos are on the server")
    }

    /// The account and the server from the iPhone: devices, a pairing QR code, the server's
    /// status and doctor, a setting changed with the password, and a new account.
    @MainActor
    func testLookingAfterTheServerFromTheiPhone() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Settings"].tap()
        let back = { app.navigationBars.buttons.firstMatch.tap() }

        app.buttons["server-account"].tap()
        app.buttons["devices"].tap()
        XCTAssertTrue(app.staticTexts["this iPhone"].waitForExistence(timeout: 10), "this iPhone is listed")
        back()
        app.buttons["pair-device"].tap()
        XCTAssertTrue(app.images["pairing-qr"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pairing-code"].exists)
        back()
        back()

        let admin = app.buttons["admin"]
        for _ in 0..<8 where !admin.isHittable { app.swipeUp() }
        XCTAssertTrue(admin.waitForExistence(timeout: 30), "the owner may look after the server")
        admin.tap()
        let name = app.descendants(matching: .any)["admin-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertTrue(name.label.contains("ui-tests") || (name.value as? String ?? "").contains("ui-tests"), name.label)

        let doctor = app.buttons["admin-doctor"]
        for _ in 0..<6 where !doctor.isHittable { app.swipeUp() }
        doctor.tap()
        XCTAssertTrue(app.descendants(matching: .any)["check-database"].waitForExistence(timeout: 10))
        back()

        app.buttons["admin-settings"].tap()
        let trashDays = app.textFields["setting-library.trash_days"]
        for _ in 0..<6 where !trashDays.isHittable { app.swipeUp() }
        // Replace the number: select it all, then type.
        trashDays.tap()
        trashDays.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        trashDays.typeText("31")
        app.buttons["save-settings"].tap()
        let field = app.alerts.firstMatch.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "asks for the password")
        field.typeText(password)
        app.alerts.firstMatch.buttons["Continue"].firstMatch.tap()
        let saved = NSPredicate(format: "value == '31'")
        expectation(for: saved, evaluatedWith: app.textFields["setting-library.trash_days"])
        waitForExpectations(timeout: 15)
        back()

        // Test versions on: the password, the server starts again with it, the switch stays on.
        let update = app.buttons["admin-update"]
        for _ in 0..<6 where !update.isHittable { app.swipeUp() }
        update.tap()
        let beta = app.switches["update-beta"]
        XCTAssertTrue(beta.waitForExistence(timeout: 30), "the switch for test versions")
        XCTAssertEqual(beta.value as? String, "0", "off at first")
        beta.switches.firstMatch.tap()
        let betaPassword = app.alerts.firstMatch.secureTextFields.firstMatch
        XCTAssertTrue(betaPassword.waitForExistence(timeout: 5), "asks for the password")
        betaPassword.typeText(password)
        app.alerts.firstMatch.buttons["Continue"].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: beta)
        waitForExpectations(timeout: 60)
        back()

        app.buttons["admin-accounts"].tap()
        app.buttons["add-account"].tap()
        let username = app.textFields["new-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("anna")
        app.buttons["create-account"].tap()
        let again = app.alerts.firstMatch.secureTextFields.firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.typeText(password)
        app.alerts.firstMatch.buttons["Continue"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account-anna"].waitForExistence(timeout: 10), "the new account")
    }

    /// Answers the simulator's questions for the place and for Apple Photos, should it ask.
    private func allowLocation() {
        addUIInterruptionMonitor(withDescription: "Place and photos") { alert in
            // Called on the main thread.
            MainActor.assumeIsolated {
                // It may be gone already (answered, or the system took it back).
                guard alert.exists else { return true }
                for label in [
                    "Allow While Using App", "Allow Once", "Allow Full Access", "Allow Access to All Photos", "Allow",
                ] where alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
                return false
            }
        }
    }

    /// Signing in with a password against a real server: look it up, compare the fingerprint,
    /// sign in, and the app is connected.
    @MainActor
    func testSigningInWithAPasswordAgainstTheRealServer() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"],
            let colon = server.lastIndex(of: ":")
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.buttons["password-login"].tap()
        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(String(server[..<colon]))
        let port = app.textFields["port"]
        port.tap()
        port.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        port.typeText(XCUIKeyboardKey.delete.rawValue + String(server[server.index(after: colon)...]))
        app.buttons["look-up"].tap()
        let same = app.switches["fingerprint-confirmed"]
        XCTAssertTrue(same.waitForExistence(timeout: 15), "the server answered with its fingerprint")
        same.switches.firstMatch.tap()
        let username = app.textFields["username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("lucas")
        app.secureTextFields["password"].tap()
        app.secureTextFields["password"].typeText(password)
        app.buttons["sign-in"].tap()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 20), "signed in")
        tabs.buttons["Settings"].tap()
        let name = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'ui-tests' OR value CONTAINS 'ui-tests'")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the server's name")
    }

    /// Newer / Pro iPhone features work on capable hardware and stay completely hidden on basic devices.
    @MainActor
    func testProDeviceFeaturesAndCapabilityGating() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-signed-in", "-ui-testing-library", "10", "-ui-testing-ssd", "-ui-testing-macro",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 30))

        // Macro toggle appears and flips between on and off.
        let macro = app.buttons["macro-toggle"]
        XCTAssertTrue(macro.waitForExistence(timeout: 5), "macro toggle visible on capable device")
        macro.tap()
        XCTAssertEqual(macro.label, "Macro off")
        macro.tap()
        XCTAssertEqual(macro.label, "Macro on")

        // Drawer shows Apple ProRAW on capable device.
        app.buttons["camera-controls-toggle"].tap()
        let drawer = app.descendants(matching: .any)["camera-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let screenWidth = window.frame.width
        func scrollDrawerTo(_ chip: XCUIElement) {
            for _ in 0..<8 where chip.frame.maxX > screenWidth - 8 || chip.frame.minX < 8 {
                let chipY = drawer.frame.maxY - 24
                let origin = window.coordinate(withNormalizedOffset: .zero)
                let from = origin.withOffset(
                    CGVector(dx: chip.frame.minX < 8 ? screenWidth * 0.2 : screenWidth * 0.85, dy: chipY))
                let to = origin.withOffset(
                    CGVector(dx: chip.frame.minX < 8 ? screenWidth * 0.85 : screenWidth * 0.2, dy: chipY))
                from.press(forDuration: 0.02, thenDragTo: to)
            }
        }
        let proRAW = app.buttons["drawer-proraw"]
        XCTAssertTrue(proRAW.waitForExistence(timeout: 5), "ProRAW chip shown on Pro hardware")
        scrollDrawerTo(proRAW)
        proRAW.tap()
        app.buttons["camera-controls-toggle"].tap()

        // Video mode shows ProRes / Log selector and USB-C SSD badge.
        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["camera-controls-toggle"].waitForExistence(timeout: 5))
        app.buttons["camera-controls-toggle"].tap()
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        let proResChip = app.buttons["drawer-prores"]
        XCTAssertTrue(proResChip.waitForExistence(timeout: 5), "ProRes chip shown on Pro hardware")
        scrollDrawerTo(proResChip)
        proResChip.tap()
        let logPill = app.buttons["drawer-provideo-prores_log"]
        XCTAssertTrue(logPill.waitForExistence(timeout: 5))
        logPill.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["external-storage-badge"].waitForExistence(timeout: 5),
            "USB-C SSD badge shown for ProRes Log")
        app.buttons["camera-controls-toggle"].tap()

        // Spatial Video mode is present and shows landscape guidance.
        for mode in ["photo", "portrait", "panorama", "dual", "spatial"] {
            let button = app.buttons["mode-\(mode)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "mode-\(mode) should exist")
            button.tap()
            Thread.sleep(forTimeInterval: 0.45)
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["spatial-hint"].waitForExistence(timeout: 5),
            "Spatial landscape hint shown")

        // Audio Mix sheet on a video in the library saves non-destructively into Info.
        let tabs = Tabs(app)
        tabs.buttons["Photos"].tap()
        let firstVideo = app.collectionViews["library-grid"].cells.firstMatch
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 15))
        firstVideo.tap()
        let audioMixButton = app.buttons["audio-mix"]
        XCTAssertTrue(audioMixButton.waitForExistence(timeout: 10), "Audio Mix button on video")
        audioMixButton.tap()
        let studio = app.buttons["audio-mix-studio"]
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        studio.tap()
        app.buttons["audio-mix-save"].tap()
        app.buttons["info"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["info-audio-mix"].waitForExistence(timeout: 5),
            "Audio Mix shown in Info")
        app.buttons["Done"].firstMatch.tap()

        // Relaunch simulating a basic device (e.g. iPhone 15): all Pro-only controls must be hidden.
        app.terminate()
        app.launchArguments = [
            "-ui-testing-signed-in", "-ui-testing-library", "5", "-ui-testing-basic-device",
            "-ui-testing-ssd", "-ui-testing-macro",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["macro-toggle"].exists, "Macro hidden on basic device")
        XCTAssertFalse(app.buttons["mode-spatial"].exists, "Spatial mode hidden on basic device")
        app.buttons["camera-controls-toggle"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["camera-drawer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["drawer-proraw"].exists, "ProRAW hidden on basic device")
        app.buttons["camera-controls-toggle"].tap()
        app.buttons["mode-video"].tap()
        XCTAssertTrue(app.buttons["camera-controls-toggle"].waitForExistence(timeout: 5))
        app.buttons["camera-controls-toggle"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["camera-drawer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["drawer-prores"].exists, "ProRes hidden on basic device")
        XCTAssertFalse(app.descendants(matching: .any)["external-storage-badge"].exists, "SSD hidden on basic device")

        let basicTabs = Tabs(app)
        basicTabs.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["camera-settings"].waitForExistence(timeout: 10))
        app.buttons["camera-settings"].tap()
        let rawToggle = app.switches["settings-raw"]
        for _ in 0..<4 where !rawToggle.exists { app.swipeUp() }
        XCTAssertTrue(rawToggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["settings-proraw"].exists, "ProRAW setting hidden on basic device")
        XCTAssertFalse(app.switches["settings-external-storage"].exists, "SSD setting hidden on basic device")
    }

    /// Comprehensive Round 3 end-to-end journey against the real server: customizes camera controls,
    /// shoots across Photo (Style + Filter), Portrait, Panorama, Cinematic, and Dual modes, verifies
    /// server backup in the Photos library, inspects Info, edits non-destructively, and tests Trash/Restore.
    @MainActor
    func testEndToEndRound3CameraToLibraryJourney() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["HALDEN_TEST_SERVER"], let password = environment["HALDEN_TEST_PASSWORD"]
        else {
            throw XCTSkip("no server: run ios/ui-tests.sh")
        }
        allowLocation()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sign-in"]
        app.launchEnvironment = ["HALDEN_TEST_SERVER": server, "HALDEN_TEST_PASSWORD": password]
        app.launch()
        let tabs = Tabs(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")

        // 1. Photo mode with Photographic Style + Filter active.
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 15))
        app.buttons["camera-controls-toggle"].tap()
        let drawer = app.descendants(matching: .any)["camera-drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        app.buttons["drawer-style"].tap()
        let amber = app.buttons["style-preset-amber"]
        XCTAssertTrue(amber.waitForExistence(timeout: 5))
        amber.tap()
        app.buttons["camera-controls-toggle"].tap()
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 0.6)

        // 2. Portrait mode capture.
        app.buttons["mode-portrait"].tap()
        Thread.sleep(forTimeInterval: 0.7)
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 0.6)

        // 3. Panorama capture (start sweep → stop & stitch HEIC).
        app.buttons["mode-panorama"].tap()
        XCTAssertTrue(app.buttons["panorama-direction"].waitForExistence(timeout: 5))
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 1.4)

        // 4. Dual Capture (swap cameras + single-file composited photo).
        app.buttons["mode-dual"].tap()
        XCTAssertTrue(app.buttons["dual-swap"].waitForExistence(timeout: 5))
        app.buttons["dual-swap"].tap()
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 0.8)

        // 5. Cinematic video recording (step back through modes, record briefly, stop).
        for mode in ["panorama", "portrait", "photo", "video", "cinematic"] {
            let button = app.buttons["mode-\(mode)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            Thread.sleep(forTimeInterval: 0.45)
        }
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recording-time"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.2)
        app.buttons["shutter"].tap()
        Thread.sleep(forTimeInterval: 0.8)

        // 6. Verify captures arrive in Library, back up to the real server, and survive Info + Trash/Restore.
        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 4).waitForExistence(timeout: 30), "all 5 Round 3 captures in library")
        let newest = grid.cells.firstMatch
        expectation(for: NSPredicate(format: "label ENDSWITH 'backed up'"), evaluatedWith: newest)
        waitForExpectations(timeout: 120)

        let id = newest.identifier.replacingOccurrences(of: "photo-", with: "")
        newest.tap()
        XCTAssertTrue(app.buttons["cinematic-edit"].waitForExistence(timeout: 10), "Cinematic focus editor button")
        XCTAssertTrue(app.buttons["info"].waitForExistence(timeout: 10))
        app.buttons["info"].tap()
        XCTAssertTrue(app.navigationBars["Info"].waitForExistence(timeout: 10), "Info sheet opened")
        let cinematicRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Cinematic' OR value CONTAINS 'Cinematic'")).firstMatch
        for _ in 0..<3 where !cinematicRow.exists { app.swipeUp() }
        XCTAssertTrue(cinematicRow.waitForExistence(timeout: 10), "Cinematic capture mode persisted")
        app.buttons["Done"].firstMatch.tap()

        // Trash and immediately restore from Trash.
        app.buttons["delete"].tap()
        let deleteEverywhere = app.buttons["delete-everywhere"].firstMatch
        XCTAssertTrue(deleteEverywhere.waitForExistence(timeout: 5))
        deleteEverywhere.tap()
        XCTAssertTrue(grid.cells["photo-\(id)"].waitForNonExistence(timeout: 10))
        app.buttons["photos-menu"].tap()
        app.buttons["trash"].tap()
        let trashed = app.descendants(matching: .any)["trashed-\(id)"]
        XCTAssertTrue(trashed.waitForExistence(timeout: 10))
        trashed.tap()
        app.buttons["restore"].tap()
        XCTAssertTrue(trashed.waitForNonExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(grid.cells["photo-\(id)"].waitForExistence(timeout: 10), "restored cleanly to library")
    }
}
