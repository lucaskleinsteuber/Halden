import XCTest

/// The way between the camera and the tabs. The camera has no tab bar (like Apple's camera): the
/// last photo leads to the library ("All Photos"), from where the tab bar leads on. Reads like
/// the tab bar itself: `tabs.buttons["Photos"].tap()`.
@MainActor
struct Tabs {
    let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
    }

    /// The app is up: the camera or a tab is there.
    func waitForExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.buttons["shutter"].exists || app.tabBars.firstMatch.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
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
            let button = app.tabBars.firstMatch.buttons[name]
            if !button.isHittable, app.buttons["last-photo"].isHittable {
                if name == "Camera" { return }
                // In the camera: the last photo, then "All Photos" (with no photos yet the
                // library comes at once).
                app.buttons["last-photo"].tap()
                let all = app.buttons["all-photos"]
                let deadline = Date().addingTimeInterval(15)
                while !button.isHittable, Date() < deadline {
                    if all.exists, all.isHittable { all.tap() }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            XCTAssertTrue(button.waitForExistence(timeout: 10), "the tab \(name)")
            button.tap()
        }
    }
}
