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
        let signOut = app.buttons["sign-out"]
        for _ in 0..<6 where !signOut.exists { app.swipeUp() }
        XCTAssertTrue(signOut.exists)
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
        // Photos from other tests come from the server too; the round below counts only these.
        XCTAssertGreaterThanOrEqual(photos.count, 2, "both photos are on the server")
        XCTAssertGreaterThanOrEqual(videos.count, 1, "the video is on the server")

        tabs.buttons["Settings"].tap()
        app.buttons["uploads"].tap()
        let round = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '3 of 3 uploaded' OR value CONTAINS '3 of 3 uploaded'"))
            .firstMatch
        XCTAssertTrue(round.waitForExistence(timeout: 10), "the uploads screen counts the round")
        XCTAssertTrue(app.staticTexts["Everything is on the server"].exists)
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
        let tabs = app.tabBars.firstMatch
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
        waitForExpectations(timeout: 60)
        newest.tap()

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
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        app.buttons["shutter"].tap()
        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        let newest = grid.cells.firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == 'Photo, backed up'"), evaluatedWith: newest)
        waitForExpectations(timeout: 60)
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
        XCTAssertTrue(trashed.label.hasSuffix("30 days left"), trashed.label)
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
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 60), "signed in")
        tabs.buttons["Settings"].tap()
        let start = app.buttons["import-photos"]
        for _ in 0..<8 where !start.isHittable { app.swipeUp() }
        start.tap()
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

    /// Answers the question for the place, should the simulator ask.
    private func allowLocation() {
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            // Called on the main thread.
            MainActor.assumeIsolated {
                for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
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
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 20), "signed in")
        tabs.buttons["Settings"].tap()
        let name = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'ui-tests' OR value CONTAINS 'ui-tests'")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "the server's name")
    }
}
