import XCTest

final class AssistantPhoneUITests: XCTestCase {
    @MainActor
    func testCompanionStartsWithMessagesAndPairing() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["messagesInstructions"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields.count, 2)
        XCTAssertTrue(app.buttons["Ask on this iPhone"].exists)
        XCTAssertTrue(app.buttons["phoneModelPicker"].exists)
        XCTAssertFalse(app.buttons["downloadPhoneModel"].exists)
        XCTAssertFalse(app.buttons["Ask locally"].exists)
        XCTAssertFalse(app.buttons["Import Mac context"].exists)
    }

    @MainActor
    func testChoosingOpenModelRequiresExplicitDownloadAndDoesNotPretendInstalled() {
        let app = XCUIApplication()
        app.launch()
        let picker = app.buttons["phoneModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        if !picker.isHittable { app.swipeUp() }
        picker.tap()
        app.buttons["Qwen3 0.6B · 4-bit"].tap()
        let download = app.buttons["downloadPhoneModel"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Cancel download"].exists)
        XCTAssertFalse(app.buttons["Remove selected model"].exists)
        XCTAssertFalse(app.buttons["Ask on this iPhone"].isEnabled)
        if !picker.isHittable { app.swipeDown() }
        picker.tap()
        app.buttons["Apple on-device (no download)"].tap()
    }
}
