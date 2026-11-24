import XCTest

/// Measurements, not checks: how fast the app starts and the camera is there, and what scrolling
/// through 50,000 photos costs. Run on purpose, results go to `Local/benchmarks/`:
///
///     TEST_RUNNER_HALDEN_MEASURE=1 ios/ui-tests.sh -only-testing:HaldenUITests/PerformanceTests
final class PerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HALDEN_MEASURE"] != nil, "set HALDEN_MEASURE to measure")
    }

    private func options(_ iterations: Int) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        return options
    }

    /// From tapping the icon until the app answers.
    @MainActor
    func testLaunch() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options(5)) {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing-signed-in"]
            app.launch()
        }
    }

    /// From starting the app until the camera's picture is on the screen (the first tab).
    @MainActor
    func testTheCameraIsThereAtOnce() {
        measure(metrics: [XCTClockMetric()], options: options(5)) {
            let app = XCUIApplication()
            app.launchArguments = ["-ui-testing-signed-in"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["camera-preview"].waitForExistence(timeout: 20))
        }
    }

    /// Memory and processor while scrolling through 50,000 photos.
    @MainActor
    func testScrollingFiftyThousandPhotos() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "50000"]
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 60))
        tabs.buttons["Photos"].tap()
        let grid = app.collectionViews["library-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        measure(
            metrics: [
                XCTMemoryMetric(application: app), XCTCPUMetric(application: app),
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
            ], options: options(5)
        ) {
            for _ in 0..<4 { grid.swipeUp(velocity: .fast) }
            grid.swipeDown(velocity: .fast)
        }
    }

    /// Memory and processor while moving and zooming the map with 45,000 photos on it.
    @MainActor
    func testTheMapWithFiftyThousandPhotos() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-library", "50000"]
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 60))
        tabs.buttons["Photos"].tap()
        app.segmentedControls["photos-section"].buttons["Map"].tap()
        let map = app.descendants(matching: .any)["photo-map"]
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "map-group").firstMatch.waitForExistence(timeout: 20))
        measure(
            metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app), XCTClockMetric()],
            options: options(5)
        ) {
            map.pinch(withScale: 2.5, velocity: 3)
            map.swipeLeft()
            map.swipeUp()
            map.pinch(withScale: 0.4, velocity: -3)
        }
    }
}
