import XCTest

final class AssistantPhoneUITests: XCTestCase {
    @MainActor
    func testDemoAnswersWithoutPersonalPermissionsAndContextCanBeCleared() {
        let app = XCUIApplication()
        app.launch()
        let ask = app.buttons["Ask locally"]
        XCTAssertTrue(ask.waitForExistence(timeout: 15))
        ask.tap()
        app.swipeUp()
        let answer = app.staticTexts["localAnswer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 45))
        XCTAssertTrue(answer.label.contains("Friday at 5 PM"))
        XCTAssertTrue(answer.label.contains("Public demo data only"))
        app.swipeDown()
        let clear = app.buttons["Clear local context"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertFalse(answer.exists)
    }
}
