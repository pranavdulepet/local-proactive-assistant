import XCTest

final class AssistantPhoneUITests: XCTestCase {
    @MainActor
    func testCompanionStartsWithMessagesAndPairing() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["messagesInstructions"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields.count, 2)
        XCTAssertTrue(app.buttons["Ask on this iPhone"].exists)
        XCTAssertFalse(app.buttons["Ask locally"].exists)
        XCTAssertFalse(app.buttons["Import Mac context"].exists)
    }
}
