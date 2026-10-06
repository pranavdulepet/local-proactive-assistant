import XCTest

final class AssistantPhoneUITests: XCTestCase {
    @MainActor
    func testCompanionStartsWithMessagesAndPairing() {
        let app = XCUIApplication()
        app.launch()
        defer {
            restoreAppleModel(in: app)
            app.terminate()
        }
        XCTAssertTrue(app.staticTexts["messagesInstructions"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["pairingInstructions"].exists)
        XCTAssertFalse(app.textFields["phoneMessageField"].exists)
        XCTAssertFalse(app.buttons["phoneModelPicker"].exists)

        guard openPhoneConversation(in: app),
              selectModel("Apple on-device (no download)", in: app) else {
            XCTFail("Phone conversation should open with a reachable model picker.")
            return
        }
        assertPrimaryControls(in: app)
        XCTAssertFalse(app.buttons["downloadPhoneModel"].exists)
    }

    @MainActor
    func testChoosingOpenModelRequiresExplicitDownloadAndDoesNotPretendInstalled() {
        let app = XCUIApplication()
        app.launch()
        defer {
            restoreAppleModel(in: app)
            app.terminate()
        }
        XCTAssertTrue(app.staticTexts["messagesInstructions"].waitForExistence(timeout: 15))
        guard openPhoneConversation(in: app),
              selectModel("Apple on-device (no download)", in: app),
              selectModel("Qwen3 0.6B · 4-bit", in: app) else {
            XCTFail("Model selection should work through the normal phone controls.")
            return
        }
        assertPrimaryControls(in: app)
        let download = app.buttons["downloadPhoneModel"]
        guard scrollUpTo(download, in: app) else {
            XCTFail("The selected model should offer an explicit download.")
            return
        }
        XCTAssertTrue(download.isEnabled)
        XCTAssertFalse(app.buttons["Cancel download"].exists)
        XCTAssertFalse(app.buttons["Remove selected model"].exists)
    }

    @MainActor
    private func assertPrimaryControls(in app: XCUIApplication) {
        let message = app.textFields["phoneMessageField"]
        let contact = app.textFields["phoneContactField"]
        XCTAssertTrue(message.exists && message.isHittable)
        XCTAssertTrue(contact.exists && contact.isHittable)
        let ask = app.buttons["askPhoneButton"]
        guard ask.exists else {
            XCTFail("Ask should be visible alongside the message fields.")
            return
        }
        // A disabled button cannot be tapped, but should still occupy a visible row.
        let frame = ask.frame
        XCTAssertTrue(app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
        XCTAssertFalse(ask.isEnabled)
    }

    @MainActor
    private func openPhoneConversation(in app: XCUIApplication) -> Bool {
        let link = app.buttons["phoneConversationLink"]
        guard scrollUpTo(link, in: app) else { return false }
        link.tap()
        return app.buttons["phoneModelPicker"].waitForExistence(timeout: 5)
    }

    @MainActor
    private func selectModel(_ title: String, in app: XCUIApplication) -> Bool {
        let picker = app.buttons["phoneModelPicker"]
        let choice = app.buttons[title].firstMatch
        if !choice.exists || !choice.isHittable {
            guard picker.exists, picker.isHittable else { return false }
            picker.tap()
        }
        guard choice.waitForExistence(timeout: 5), choice.isHittable else { return false }
        choice.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: picker)
        return XCTWaiter.wait(for: [selected], timeout: 5) == .completed
    }

    @MainActor
    private func restoreAppleModel(in app: XCUIApplication) {
        // Only scroll the conversation screen if it was actually opened.
        guard app.navigationBars["Phone conversation"].exists else { return }
        let picker = app.buttons["phoneModelPicker"]
        for _ in 0..<3 {
            if picker.exists && picker.isHittable { break }
            app.swipeDown()
        }
        _ = selectModel("Apple on-device (no download)", in: app)
    }

    @MainActor
    private func scrollUpTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
