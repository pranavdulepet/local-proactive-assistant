import XCTest

final class AssistantPhoneUITests: XCTestCase {
    @MainActor
    func testCompanionStartsWithMessagesAndPairing() {
        let app = XCUIApplication()
        app.launch()
        defer {
            _ = selectModel("Apple on-device (no download)", in: app)
            app.terminate()
        }
        XCTAssertTrue(app.staticTexts["messagesInstructions"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["pairingInstructions"].exists)
        XCTAssertFalse(app.textFields["phoneMessageField"].exists)
        XCTAssertFalse(app.buttons["phoneModelPicker"].exists)

        guard openPhoneConversation(in: app),
              selectModel("Apple on-device (no download)", in: app) else {
            XCTFail("The optional phone conversation and model picker should be reachable.")
            return
        }
        XCTAssertFalse(app.buttons["downloadPhoneModel"].exists)
        XCTAssertTrue(reveal(app.textFields["phoneMessageField"], in: app))
        XCTAssertTrue(reveal(app.textFields["phoneContactField"], in: app))
        XCTAssertTrue(reveal(app.buttons["askPhoneButton"], in: app, allowDisabled: true))
        XCTAssertFalse(app.buttons["askPhoneButton"].isEnabled)
    }

    @MainActor
    func testChoosingOpenModelRequiresExplicitDownloadAndDoesNotPretendInstalled() {
        let app = XCUIApplication()
        app.launch()
        defer {
            _ = selectModel("Apple on-device (no download)", in: app)
            app.terminate()
        }
        XCTAssertTrue(app.staticTexts["messagesInstructions"].waitForExistence(timeout: 15))
        guard openPhoneConversation(in: app),
              selectModel("Apple on-device (no download)", in: app),
              selectModel("Qwen3 0.6B · 4-bit", in: app) else {
            XCTFail("Model selection should work through the normal phone controls.")
            return
        }
        let download = app.buttons["downloadPhoneModel"]
        XCTAssertTrue(reveal(download, in: app))
        XCTAssertTrue(download.isEnabled)
        XCTAssertFalse(app.buttons["Cancel download"].exists)
        XCTAssertFalse(app.buttons["Remove selected model"].exists)
        guard reveal(app.buttons["askPhoneButton"], in: app, allowDisabled: true) else {
            XCTFail("The phone conversation's ask button should be visible after scrolling.")
            return
        }
        XCTAssertFalse(app.buttons["askPhoneButton"].isEnabled)
    }

    @MainActor
    private func openPhoneConversation(in app: XCUIApplication) -> Bool {
        let disclosure = app.descendants(matching: .any)
            .matching(identifier: "phoneConversationDisclosure").firstMatch
        guard reveal(disclosure, in: app) else { return false }
        disclosure.tap()
        return reveal(app.buttons["phoneModelPicker"], in: app)
    }

    @MainActor
    private func selectModel(_ title: String, in app: XCUIApplication) -> Bool {
        let picker = app.buttons["phoneModelPicker"]
        let choice = app.buttons[title].firstMatch
        if !choice.exists || !choice.isHittable {
            guard reveal(picker, in: app) else { return false }
            picker.tap()
        }
        guard choice.waitForExistence(timeout: 5), choice.isHittable else { return false }
        choice.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: picker)
        return XCTWaiter.wait(for: [selected], timeout: 5) == .completed
    }

    /// Form rows are materialized as they enter the viewport. Assertions on a
    /// disabled control still need its actual visible frame, rather than a
    /// hittability check that could require the control to be enabled.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, allowDisabled: Bool = false) -> Bool {
        func visible() -> Bool {
            guard element.exists else { return false }
            if allowDisabled {
                return !element.frame.isEmpty && app.frame.insetBy(dx: 0, dy: 60).intersects(element.frame)
            }
            return element.isHittable
        }
        for _ in 0..<6 {
            if visible() { return true }
            if element.exists, element.frame.maxY < app.frame.minY + 60 { app.swipeDown() }
            else { app.swipeUp() }
        }
        for _ in 0..<10 {
            if visible() { return true }
            app.swipeDown()
        }
        return visible()
    }
}
