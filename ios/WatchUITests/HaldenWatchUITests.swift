import XCTest

/// UI tests for the Apple Watch Halden camera remote app (runs in stand-in mode with `-ui-testing`).
final class HaldenWatchUITests: XCTestCase {
    @MainActor
    func testWatchCameraRemoteShutterTimerFlipAndPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let shutter = app.buttons["watch-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "Watch shutter ready")
        XCTAssertTrue(app.staticTexts["watch-zoom"].waitForExistence(timeout: 5), "Zoom readout shown")

        // Flip camera and trigger shutter -> post-capture photo preview sheet appears.
        app.buttons["watch-flip"].tap()
        shutter.tap()
        XCTAssertTrue(app.images["watch-last-photo"].waitForExistence(timeout: 5), "Captured photo preview shown")
        app.buttons["watch-last-done"].tap()

        // 3-second timer button triggers countdown then shows captured photo preview.
        app.buttons["watch-timer-3s"].tap()
        XCTAssertTrue(app.images["watch-last-photo"].waitForExistence(timeout: 10), "Timer photo preview shown")
        app.buttons["watch-last-done"].tap()
    }
}
