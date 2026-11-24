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
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["Photos"].tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["empty-library"].waitForExistence(timeout: 5))
        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sign-out"].exists)
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 5))
    }

    /// Fifty thousand photos scroll without waiting for pictures.
    @MainActor
    func testTheGridScrollsThroughFiftyThousandPhotos() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "50000"]
        app.launch()
        let tabs = app.tabBars.firstMatch
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
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30), "signed in")
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
        app.buttons["timer"].tap()
        XCTAssertEqual(app.buttons["timer"].label, "Self-timer off")

        app.segmentedControls["camera-mode"].buttons["Video"].tap()
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
        XCTAssertEqual(photos.count, 2, "both photos are on the server")
        XCTAssertEqual(videos.count, 1, "the video is on the server")
    }

    /// Answers the question for the place, should the simulator ask.
    private func allowLocation() {
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
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
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 20), "signed in")
        tabs.buttons["Settings"].tap()
        let name = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'ui-tests' OR value CONTAINS 'ui-tests'")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the server's name")
    }
}
