import XCTest

/// End-to-end UI tests against scripted fake services (`-uiTestFakes`), so they never use
/// the real microphone, OpenAI, or the user's saved history. IDs match docs/TEST_CASES.md §5.
final class V2VfolderUITests: XCTestCase {
    private let timeout: TimeInterval = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = [], resetDefaults: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFakes"] + (resetDefaults ? ["-uiTestResetDefaults"] : []) + extra
        app.launch()
        return app
    }

    @MainActor
    private func orb(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["orbStatus"]
    }

    @MainActor
    private func waitForOrb(_ app: XCUIApplication, toSay label: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", label), object: orb(app))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "orb never showed \"\(label)\"; last value: \(String(describing: orb(app).value))", file: file, line: line)
    }

    /// Starts a session, waits for the fake greeting, ends it (which saves it to history).
    @MainActor
    private func haveOneConversation(_ app: XCUIApplication) {
        app.buttons["startButton"].tap()
        waitForOrb(app, toSay: "Listening")
        XCTAssertTrue(greetingBubble(app).waitForExistence(timeout: timeout))
        app.buttons["endButton"].tap()
        XCTAssertTrue(app.buttons["startButton"].waitForExistence(timeout: timeout))
    }

    @MainActor
    private func greetingBubble(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS %@", "Hello from the fake assistant"))
            .firstMatch
    }

    // MARK: - UI-01 / UI-04

    @MainActor
    func testUI01_startListenEndSavesToHistory() {
        let app = launch()
        waitForOrb(app, toSay: "Tap Start to talk")

        haveOneConversation(app)
        waitForOrb(app, toSay: "Tap Start to talk")

        app.buttons["historyButton"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: timeout))
        XCTAssertEqual(app.cells.count, 1)
    }

    @MainActor
    func testUI04_transcriptShowsAssistantTurn() {
        let app = launch()
        app.buttons["startButton"].tap()
        XCTAssertTrue(greetingBubble(app).waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["endButton"].exists)
    }

    // MARK: - UI-02 / UI-03

    @MainActor
    func testUI02_micDeniedShowsOpenSettings() {
        let app = launch(["-uiTestMicDenied"])
        app.buttons["startButton"].tap()
        XCTAssertTrue(app.buttons["openSettingsButton"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["startButton"].exists, "app must stay usable, not crash")
    }

    @MainActor
    func testUI03_tokenServerDownShowsErrorAndRetryWithoutHanging() {
        let app = launch(["-uiTestTokenFailure"])
        app.buttons["startButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["errorBanner"].waitForExistence(timeout: timeout))
        let retry = app.buttons["retryButton"]
        XCTAssertTrue(retry.exists)

        retry.tap()
        // Still failing (server is "down"), but the UI answers instead of hanging.
        XCTAssertTrue(app.descendants(matching: .any)["errorBanner"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["startButton"].isHittable)
    }

    // MARK: - UI-05

    @MainActor
    func testUI05_personaPickerHasThreeAndPersists() {
        var app = launch()
        let menu = app.buttons["Quick"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        for name in ["Quick", "Storyteller", "Coach"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: timeout), "missing persona \(name)")
        }
        app.buttons["Storyteller"].tap()
        XCTAssertTrue(app.buttons["Storyteller"].waitForExistence(timeout: timeout))

        app.terminate()
        app = launch(resetDefaults: false)
        XCTAssertTrue(app.buttons["Storyteller"].waitForExistence(timeout: timeout), "persona should survive a relaunch")
    }

    // MARK: - UI-06

    @MainActor
    func testUI06_historySwipeToDelete() {
        let app = launch()
        haveOneConversation(app)
        app.buttons["historyButton"].tap()

        let cell = app.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: timeout))
        cell.swipeLeft()
        app.buttons["Delete"].tap()

        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.cells.count, 0)
    }

    // MARK: - UI-08

    @MainActor
    func testUI08_tripleTapOrbTogglesDebugOverlay() {
        let app = launch()
        let overlay = app.descendants(matching: .any)["debugOverlay"]
        XCTAssertFalse(overlay.exists)

        orb(app).tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(overlay.waitForExistence(timeout: timeout))

        orb(app).tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: timeout))
    }
}
