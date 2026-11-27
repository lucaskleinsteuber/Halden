import XCTest

/// The app's tab bar (Camera, Photos, Settings), visible on the main screens: the system one in
/// Photos and Settings, the camera's own slim one in the camera.
@MainActor
struct Tabs {
    let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
    }

    /// The app is up: a tab bar is there.
    func waitForExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.tabBars.firstMatch.exists || app.otherElements["camera-tab-bar"].exists { return true }
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 0.5)
        } while Date() < deadline
        return false
    }

    var buttons: Finder { Finder(app: app) }

    @MainActor
    struct Finder {
        let app: XCUIApplication

        subscript(name: String) -> Tab { Tab(app: app, name: name) }
    }

    @MainActor
    struct Tab {
        let app: XCUIApplication
        let name: String

        func tap() {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                let system = app.tabBars.firstMatch.buttons[name]
                if system.exists && system.isHittable {
                    system.tap()
                    return
                }
                let own = app.buttons["camera-tab-\(name.lowercased())"]
                if own.exists && own.isHittable {
                    own.tap()
                    return
                }
                _ = own.waitForExistence(timeout: 0.5)
            } while Date() < deadline
            XCTFail("the tab \(name)")
        }
    }
}

extension XCUIElement {
    /// Taps once the element can be hit: right after something slides in, its place on the
    /// screen isn't settled yet.
    func tapWhenHittable(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(exists && isHittable) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(exists && isHittable, "\(identifier) can be tapped", file: file, line: line)
        tap()
    }
}
