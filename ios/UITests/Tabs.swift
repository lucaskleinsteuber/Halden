import XCTest

/// The app's tab bar (Camera, Photos, Settings), visible on the main screens.
@MainActor
struct Tabs {
    let app: XCUIApplication

    init(_ app: XCUIApplication) {
        self.app = app
    }

    /// The app is up: the tab bar is there.
    func waitForExistence(timeout: TimeInterval) -> Bool {
        app.tabBars.firstMatch.waitForExistence(timeout: timeout)
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
            XCTAssertTrue(button.waitForExistence(timeout: 10), "the tab \(name)")
            button.tap()
        }
    }
}
