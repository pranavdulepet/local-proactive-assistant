import XCTest

final class AssistantPhoneUITests: XCTestCase {
    @MainActor
    func testMessagesFirstHomeAndOptionalLocalDemo() {
        let app = XCUIApplication()
        app.launch()
        let instructions = app.staticTexts["messagesInstructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 15))
        XCTAssertTrue(instructions.label.contains("private self-chat"))
        XCTAssertFalse(app.buttons["Ask locally"].exists)
        XCTAssertFalse(app.buttons["Enable Calendar"].exists)
        let tools = app.buttons["phoneModelTools"]
        for _ in 0..<3 where !tools.isHittable { app.swipeUp() }
        XCTAssertTrue(tools.isHittable)
        tools.tap()
        let ask = app.buttons["Ask locally"]
        XCTAssertTrue(ask.waitForExistence(timeout: 15))
        for _ in 0..<3 where !ask.isHittable { app.swipeUp() }
        ask.tap()
        app.swipeUp()
        let answer = app.staticTexts["localAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 45))
        for _ in 0..<3 where !answer.isHittable { app.swipeUp() }
        XCTAssertTrue(answer.label.contains("Friday at 5 PM"))
        XCTAssertTrue(answer.label.contains("Public demo data only"))
        let clear = app.buttons["Clear local context"]
        for _ in 0..<3 where !clear.isHittable { app.swipeDown() }
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertFalse(answer.exists)
    }
}
