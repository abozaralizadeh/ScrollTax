import XCTest

/// Walks the whole first version in demo mode (pretend blocker, pretend purchase, fake Apple sign in)
/// against a local backend running with APPLE_MODE=fake on port 8787.
final class DemoFlowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-reset"]
        app.launch()
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A toggle row is wide and the switch sits at its right edge, so tap there and not in the middle.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }

    private func appears(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Expected to see: \(what)")
    }

    func testRegisterBlockUnlockLeaveAndDelete() {
        // Welcome shows the deal, including the free exit
        appears(app.staticTexts["Here's the deal"], "welcome")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'for free'")).count > 0)
        shot("1-welcome")
        app.buttons["Continue"].tap()

        // The demo button stays off until both boxes are ticked
        let demo = app.buttons["Continue in demo mode"]
        appears(demo, "demo sign in")
        XCTAssertFalse(demo.isEnabled)
        flip(app.switches.element(boundBy: 0))
        XCTAssertFalse(demo.isEnabled)
        flip(app.switches.element(boundBy: 1))
        XCTAssertTrue(demo.isEnabled)
        shot("2-age-and-terms")
        demo.tap()

        appears(app.buttons["Allow Screen Time"], "permission screen")
        shot("3-permission")
        app.buttons["Allow Screen Time"].tap()

        appears(app.buttons["Turn on the block"], "picker screen")
        shot("4-picker")
        app.buttons["Turn on the block"].tap()

        // Blocked, with an unlock on offer and the daily count shown
        appears(app.staticTexts["Blocked"], "blocked status")
        let unlock = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unlock for'")).firstMatch
        appears(unlock, "unlock button")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '4 of 4 left today'")).count > 0)
        shot("5-blocked")
        unlock.tap()

        let pay = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pay'")).firstMatch
        appears(pay, "pay button")
        shot("6-confirm")
        pay.tap()

        // Paid: unlocked with a countdown, and no second unlock on offer
        appears(app.staticTexts["Unlocked"], "unlocked status")
        XCTAssertFalse(unlock.exists)
        shot("7-unlocked")

        // The backend recorded the payment
        app.buttons["History"].tap()
        appears(app.navigationBars["Payments"], "payments list")
        appears(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '0.99'")).firstMatch, "the 0.99 payment")
        shot("8-history")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Leave: starts the wait, the app says so
        app.buttons["Settings"].tap()
        appears(app.buttons["Leave ScrollTax"], "leave button")
        shot("9-settings")

        // A copy of the person's own data: the backend builds it, the app offers to share the file
        let copy = app.buttons["Get a copy of my data"]
        appears(copy, "data copy button")
        copy.tap()
        appears(app.buttons["Share my data file"], "share button after the export")
        app.buttons["Leave ScrollTax"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start the'")).firstMatch.tap()
        appears(app.buttons["Cancel leaving"], "cancel leaving")
        app.buttons["Cancel leaving"].tap()
        appears(app.buttons["Leave ScrollTax"], "leave button again")

        // Delete: wipes everything and goes back to the start
        app.buttons["Delete my account now"].tap()
        app.buttons["Delete and remove the block"].tap()
        appears(app.staticTexts["Here's the deal"], "back at the welcome screen")
        shot("10-after-delete")
    }
}
