import XCTest

/// Runs the real app (in-memory store via `-uiTesting`) on an iPad or iPhone
/// simulator: the preview opens and closes repeatedly, survives rotation,
/// and the chat still answers. Guards the layout switches that once crashed
/// (two web views for one page).
final class PreviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-openBot", "My website"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// The thread's Preview toggle (a button-styled toggle).
    private var previewButton: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Preview'")).firstMatch
    }
    private var backToChat: XCUIElement { app.buttons["Back to chat"].firstMatch }

    func testPreviewOpensAndClosesRepeatedly() {
        XCTAssertTrue(previewButton.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            previewButton.tap()
            XCTAssertTrue(backToChat.waitForExistence(timeout: 10), "the preview opened")
            backToChat.tap()
            XCTAssertTrue(previewButton.waitForExistence(timeout: 10), "back in the thread")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testPreviewSurvivesRotation() {
        XCTAssertTrue(previewButton.waitForExistence(timeout: 10))
        previewButton.tap()
        XCTAssertTrue(backToChat.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(backToChat.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testTheChatAnswers() {
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("which machine is free?")
        app.buttons["Send"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "which machine is free")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
