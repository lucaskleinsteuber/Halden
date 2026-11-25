import XCTest

/// Every screen, checked for what people see as a broken layout:
///
/// 1. something cut off by the edge of the screen (half in, half out; wholly outside is fine, as
///    with the modes left and right of the chosen one, and anything in a list, grid or map,
///    which scrolls),
/// 2. two controls on top of each other,
/// 3. our own buttons smaller than 44×44 points (Apple's smallest size to hit reliably),
/// 4. buttons and texts that can't be seen: hardly any difference in brightness inside them on
///    the screenshot (white on white).
///
/// Each screen is also saved as a screenshot when `HALDEN_SCREENSHOTS` names a folder
/// (`TEST_RUNNER_HALDEN_SCREENSHOTS` for xcodebuild), to look at before an iPhone gets a build.
/// Runs without a server, on any simulator; `ios/layout-tests.sh` runs it on the smallest and
/// the biggest iPhone, also with big text.
final class LayoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testEveryScreenFits() throws {
        try walk(textSize: nil)
    }

    /// The biggest text size before the accessibility sizes.
    @MainActor
    func testEveryScreenFitsWithBigText() throws {
        try walk(textSize: "UICTContentSizeCategoryXXXL")
    }

    @MainActor
    private func walk(textSize: String?) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "300"]
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launch()
        let prefix = textSize == nil ? "" : "big-text-"
        let shot = { (name: String) in self.check(app, prefix + name) }

        // The camera, in every mode and with what opens on it.
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5), "the tab bar is visible in the camera")
        settle()
        shot("camera-photo")
        app.buttons["manual"].tap()
        settle()
        shot("camera-manual")
        app.buttons["manual"].tap()
        app.buttons["camera-controls-toggle"].tap()
        settle()
        shot("camera-controls-photo")
        app.buttons["drawer-exposure"].tap()
        settle()
        shot("camera-controls-exposure")
        app.buttons["camera-controls-toggle"].tap()
        settle()
        app.buttons["zoom-1"].press(forDuration: 0.1, thenDragTo: app.buttons["zoom-0.5"])
        shot("camera-zoom-dial")
        settle(1.5)
        for mode in ["video", "slowMotion", "timeLapse"] {
            app.buttons["mode-\(mode)"].tap()
            settle()
            shot("camera-\(mode)")
            if mode == "video" {
                app.buttons["camera-controls-toggle"].tap()
                settle()
                shot("camera-controls-video")
                app.buttons["camera-controls-toggle"].tap()
                settle()
            }
        }
        // Back through the modes, each one beside the chosen one (the far ones are off screen).
        for mode in ["slowMotion", "video", "photo"] {
            app.buttons["mode-\(mode)"].tap()
            settle(0.5)
        }

        // The newest photo from the camera, then the library.
        app.buttons["last-photo"].tap()
        let all = app.buttons["all-photos"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        settle()
        shot("photo-from-camera")
        all.tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        settle()
        shot("library")
        app.buttons["select"].tap()
        settle()
        shot("library-choosing")
        app.buttons["select"].tap()
        let sections = app.segmentedControls["photos-section"]
        sections.buttons["Albums"].tap()
        settle()
        shot("albums")
        sections.buttons["Map"].tap()
        settle(2)
        shot("map")
        sections.buttons["Library"].tap()
        settle()

        // A photo full screen and the editor (the second one: the first is a video, whose file
        // isn't here without a server).
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["share"].waitForExistence(timeout: 10))
        settle()
        shot("photo")
        // Next photo has an estimated device place (subtitle under the date).
        app.swipeLeft()
        settle()
        shot("photo-estimated-place")
        app.swipeRight()
        settle()
        if app.buttons["edit"].exists {
            app.buttons["edit"].tap()
            settle(1.5)
            shot("edit")
            // Without a server the photo itself isn't here: the editor says so and closes.
            let alert = app.alerts.firstMatch
            if alert.exists {
                alert.buttons.firstMatch.tap()
            } else {
                app.buttons["edit-cancel"].tap()
            }
            settle()
        }
        app.navigationBars.buttons.firstMatch.tap()

        // Settings and each page in it.
        let tabs = Tabs(app)
        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        settle()
        shot("settings")
        for (page, title) in [
            ("server-account", nil), ("upload-settings", "Uploads"), ("camera-settings", "Camera"),
            ("place-settings", "Place"), ("photos-settings", "Apple Photos"), ("storage-settings", "Storage"),
        ] as [(String, String?)] {
            let button = app.buttons[page]
            for _ in 0..<6 where !button.isHittable { app.swipeUp() }
            guard button.exists else { continue }
            button.tap()
            settle()
            shot("settings-\(page)")
            if page == "camera-settings" {
                for (sub, subTitle) in [
                    ("camera-preserve-settings", "Preserve Settings"),
                    ("camera-top-bar-settings", "Top Bar Controls"),
                ] {
                    let subButton = app.buttons[sub]
                    if subButton.waitForExistence(timeout: 3) {
                        subButton.tap()
                        settle()
                        shot("settings-\(sub)")
                        app.navigationBars[subTitle].buttons.firstMatch.tap()
                        settle()
                    }
                }
            }
            let bar = title.map { app.navigationBars[$0] } ?? app.navigationBars.element(boundBy: 0)
            bar.buttons.firstMatch.tap()
            settle()
        }

        // Turn on the camera level and check the camera screen with the level overlay visible.
        let camSettings = app.buttons["camera-settings"]
        for _ in 0..<6 where !camSettings.isHittable { app.swipeDown() }
        if camSettings.exists {
            camSettings.tap()
            settle()
            let levelToggle = app.switches["settings-show-level"]
            for _ in 0..<8 where !levelToggle.isHittable { app.swipeUp() }
            if levelToggle.exists {
                levelToggle.switches.firstMatch.tap()
                settle(0.4)
                tabs.buttons["Camera"].tap()
                XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
                settle()
                shot("camera-level")
            }
        }
    }

    /// Lets animations finish before looking.
    private func settle(_ seconds: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: The checks

    /// What is checked on a screen: whatever shows, by its place on the screen.
    private struct Seen {
        let type: XCUIElement.ElementType
        let identifier: String
        let label: String
        let frame: CGRect
        /// Inside something that scrolls (a list, a grid, a map), where being cut off is normal.
        let scrolls: Bool
        /// In a bar the system lays out (title bar, toolbar, tab bar): its sizes are Apple's.
        let inBar: Bool
        let inTabBar: Bool
        /// Its place in the tree, to tell parents and children apart.
        let path: [Int]

        var name: String {
            let shown = identifier.isEmpty ? "\"\(label)\"" : identifier
            return "\(type.name) \(shown)"
        }

        func contains(_ other: Seen) -> Bool {
            other.path.count > path.count && Array(other.path.prefix(path.count)) == path
        }
    }

    private static let controls: Set<XCUIElement.ElementType> = [
        .button, .segmentedControl, .switch, .toggle, .slider, .textField, .secureTextField, .searchField,
        .link, .menuButton, .stepper, .picker, .datePicker,
    ]
    private static let shown: Set<XCUIElement.ElementType> = controls.union([.staticText, .image])
    private static let scrollers: Set<XCUIElement.ElementType> = [
        .scrollView, .table, .collectionView, .map, .webView, .textView,
    ]
    private static let bars: Set<XCUIElement.ElementType> = [.navigationBar, .toolbar, .tabBar]
    /// Meant to be partly outside: the modes beside the chosen one, as in Apple's camera.
    private static let mayStickOut = ["mode-"]
    /// Lie on purpose over another control (none yet).
    private static let mayOverlap: [String] = []

    @MainActor
    private func check(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HALDEN_SCREENSHOTS"], !folder.isEmpty {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }

        guard let root = try? app.snapshot() else {
            XCTFail("\(name): no snapshot of the screen", file: file, line: line)
            return
        }
        let screen = app.windows.firstMatch.frame
        var seen: [Seen] = []
        collect(root, path: [], scrolls: false, bar: nil, into: &seen)
        let visible = seen.filter { $0.frame.width > 1 && $0.frame.height > 1 && $0.frame.intersects(screen) }

        // 1. Cut off by the edge of the screen.
        for element in visible where !element.scrolls && !screen.insetBy(dx: -1, dy: -1).contains(element.frame) {
            if Self.mayStickOut.contains(where: { element.identifier.hasPrefix($0) }) { continue }
            XCTFail(
                "\(name): \(element.name) is cut off by the edge of the screen (\(element.frame) on \(screen))",
                file: file, line: line)
        }

        // 2. Controls on top of each other (tab bar buttons may only touch each other, never
        // camera or screen controls).
        let controls = visible.filter { Self.controls.contains($0.type) && !$0.scrolls }
        for (index, one) in controls.enumerated() {
            for other in controls[(index + 1)...] where !one.contains(other) && !other.contains(one) {
                // The tab bar's own buttons touch each other by Apple's design.
                if one.inTabBar && other.inTabBar { continue }
                let overlap = one.frame.intersection(other.frame)
                guard overlap.width > 2, overlap.height > 2 else { continue }
                if Self.mayOverlap.contains(one.identifier) || Self.mayOverlap.contains(other.identifier) { continue }
                XCTFail(
                    "\(name): \(one.name) and \(other.name) lie on top of each other (\(overlap))",
                    file: file, line: line)
            }
        }
        // In the camera, the shutter row must stay visibly clear above the floating tab bar.
        let tabTop = controls.filter(\.inTabBar).map(\.frame.minY).min()
        if let tabTop {
            for control in controls where ["shutter", "last-photo", "flip-camera"].contains(control.identifier) {
                let gap = tabTop - control.frame.maxY
                if gap < 11.5 {
                    XCTFail(
                        "\(name): \(control.name) is too close to the tab bar (gap \(String(format: "%.1f", gap)) pt)",
                        file: file, line: line)
                }
            }
        }

        // 4. Buttons and texts that can be seen: some contrast inside them on the screenshot.
        let pixels = Pixels(screenshot.image)
        // Only what is wholly on the screen (a mode sticking out shows just a dark sliver).
        for element in visible
        where !element.scrolls && [.button, .staticText].contains(element.type) && screen.contains(element.frame) {
            guard !element.label.isEmpty || !element.identifier.isEmpty,
                element.frame.width >= 6, element.frame.height >= 6,
                let contrast = pixels?.contrast(in: element.frame.intersection(screen))
            else { continue }
            if contrast < 0.12 {
                XCTFail(
                    "\(name): \(element.name) can hardly be seen (contrast \(String(format: "%.2f", contrast)))",
                    file: file, line: line)
            }
        }

        // 3. Our own buttons big enough to hit.
        for button in controls where button.type == .button && !button.identifier.isEmpty && !button.inBar {
            if button.frame.width < 43.5 || button.frame.height < 43.5 {
                XCTFail(
                    "\(name): \(button.name) is only \(button.frame.width)×\(button.frame.height) points",
                    file: file, line: line)
            }
        }
    }

    private func collect(
        _ element: XCUIElementSnapshot, path: [Int], scrolls: Bool, bar: XCUIElement.ElementType?,
        into seen: inout [Seen]
    ) {
        if Self.shown.contains(element.elementType) {
            seen.append(
                Seen(
                    type: element.elementType, identifier: element.identifier, label: element.label,
                    frame: element.frame, scrolls: scrolls, inBar: bar != nil, inTabBar: bar == .tabBar, path: path))
        }
        let inside = scrolls || Self.scrollers.contains(element.elementType)
        let inBar = bar ?? (Self.bars.contains(element.elementType) ? element.elementType : nil)
        for (index, child) in element.children.enumerated() {
            collect(child, path: path + [index], scrolls: inside, bar: inBar, into: &seen)
        }
    }
}

extension XCUIElement.ElementType {
    fileprivate var name: String {
        switch self {
        case .button: "button"
        case .staticText: "text"
        case .image: "image"
        case .segmentedControl: "segmented control"
        case .switch, .toggle: "switch"
        case .slider: "slider"
        case .textField, .secureTextField, .searchField: "text field"
        default: "element \(rawValue)"
        }
    }
}

/// The screenshot's pixels, to look at how much the brightness changes inside an element.
private struct Pixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        width = cgImage.width
        height = cgImage.height
        scale = CGFloat(width) / image.size.width
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    /// The difference between the darkest and the brightest pixel in `frame` (points), 0…1.
    func contrast(in frame: CGRect) -> Double? {
        let left = max(Int(frame.minX * scale), 0)
        let right = min(Int(frame.maxX * scale), width - 1)
        let top = max(Int(frame.minY * scale), 0)
        let bottom = min(Int(frame.maxY * scale), height - 1)
        guard right > left, bottom > top else { return nil }
        var darkest = 1.0
        var brightest = 0.0
        for y in stride(from: top, through: bottom, by: 2) {
            for x in stride(from: left, through: right, by: 2) {
                let index = (y * width + x) * 4
                let light =
                    (0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1])
                        + 0.0722 * Double(bytes[index + 2])) / 255
                darkest = min(darkest, light)
                brightest = max(brightest, light)
            }
        }
        return brightest - darkest
    }
}
