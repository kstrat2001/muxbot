import XCTest

/// A tour of the main screens on an iPhone or iPad simulator (in-memory
/// store, `-uiTesting`), each kept as a screenshot for a look at its layout.
/// Only waits on elements, never on time.
final class ScreensTourUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The first element whose label contains `text`.
    private func element(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func testActivity() {
        let app = launch(["-uiTesting"])
        // A tab on iPhone, a sidebar row on iPad.
        let activity = element(app, "Activity")
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        XCTAssertTrue(element(app, "Activity").waitForExistence(timeout: 10))
        keep(app, "activity")
    }

    /// One way in: "New" (the sidebar row on iPad, Home's + on iPhone) opens
    /// the chooser, with "Just a bot, no project" last.
    func testNew() {
        let app = launch(["-uiTesting"])
        let new = app.buttons.matching(NSPredicate(format: "label == %@", "New")).firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        keep(app, "new-entry")
        new.tap()
        XCTAssertTrue(element(app, "What do you want to get done?").waitForExistence(timeout: 10))
        let justABot = element(app, "Just a bot, no project")
        if !justABot.isHittable { app.swipeUp() }
        XCTAssertTrue(justABot.waitForExistence(timeout: 10))
        keep(app, "new-chooser")
    }

    func testBotInfo() {
        let app = launch(["-uiTesting", "-openBot", "My website"])
        let info = element(app, "info")
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 10))
        keep(app, "bot-info-top")
        app.swipeUp()
        keep(app, "bot-info-middle")
        app.swipeUp()
        keep(app, "bot-info-bottom")
    }

    func testSetupCheck() {
        let app = launch(["-uiTesting"])
        let chip = app.buttons["Check my setup"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        XCTAssertTrue(element(app, "darkmux installed").waitForExistence(timeout: 10))
        keep(app, "setup-check")
    }

    func testSettingsFromTheGuide() throws {
        let app = launch(["-uiTesting"])
        // The chip row scrolls: the third chip may need a swipe to appear.
        let setup = app.buttons["Check my setup"].firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let chip = element(app, "Change a setting")
        if !chip.exists { setup.swipeLeft() }
        // Not offered in every layout (the iPad's lead thread can open on
        // its own chips); the iPhone tour covers it.
        guard chip.waitForExistence(timeout: 5) else { throw XCTSkip("no settings chip in this layout") }
        chip.tap()
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 10))
        keep(app, "settings-cards")
    }

    func testSettingsComputers() {
        let app = launch(["-uiTesting"])
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let computers = element(app, "Computers")
        XCTAssertTrue(computers.waitForExistence(timeout: 10))
        computers.tap()
        XCTAssertTrue(element(app, "Runs start from the Mac app").waitForExistence(timeout: 10))
        keep(app, "settings-computers")
    }

    func testExistingProject() {
        let app = launch(["-uiTestingEmpty"])
        let existing = element(app, "Work on a project I already have")
        XCTAssertTrue(existing.waitForExistence(timeout: 10))
        existing.tap()
        XCTAssertTrue(element(app, "Where is the code").waitForExistence(timeout: 10))
        keep(app, "existing-project")
    }

    func testPreviewFullScreen() {
        let app = launch(["-uiTesting", "-openBot", "My website", "-showPreview", "YES"])
        XCTAssertTrue(app.buttons["Back to chat"].firstMatch.waitForExistence(timeout: 10))
        keep(app, "preview")
    }
}
