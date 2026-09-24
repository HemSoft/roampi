import XCTest

final class SessionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSavedHostEditorTrustAndTerminalJourney() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-hosts-demo"]
        app.launch()

        XCTAssertTrue(app.navigationBars["SSH hosts"].waitForExistence(timeout: 5))
        app.buttons["add-saved-host"].tap()
        XCTAssertTrue(app.navigationBars["Add SSH host"].waitForExistence(timeout: 3))
        app.textFields["host-display-name"].tap()
        app.textFields["host-display-name"].typeText("Studio")
        app.textFields["host-connection"].tap()
        app.textFields["host-connection"].typeText("operator@studio.example")
        app.textFields["host-project"].tap()
        app.textFields["host-project"].typeText("/home/operator/project")
        app.textFields["host-session"].tap()
        app.textFields["host-session"].typeText("studio-pi")
        captureScreenshot(named: "saved-host-editor")
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'open-saved-host-'"))
            .firstMatch.waitForExistence(timeout: 5))
        captureScreenshot(named: "saved-host-list")

        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'edit-saved-host-'"))
            .firstMatch
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit SSH host"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["host-display-name"].value as? String, "Studio")
        app.buttons["Cancel"].tap()

        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'open-saved-host-'"))
            .firstMatch.tap()
        let fingerprint = app.staticTexts["saved-host-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["trust-saved-host"].isEnabled)
        captureScreenshot(named: "saved-host-fingerprint")
        app.buttons["reject-saved-host"].tap()
        XCTAssertFalse(app.buttons["launch-saved-terminal"].exists)

        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'open-saved-host-'"))
            .firstMatch.tap()
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 5))
        let input = app.textFields["verified-fingerprint-input"]
        input.tap()
        input.typeText("SHA256:RoamPiDemoFingerprintNotForProduction")
        app.swipeUp()
        app.buttons["trust-saved-host"].tap()
        XCTAssertTrue(app.buttons["launch-saved-terminal"].waitForExistence(timeout: 5))
        app.buttons["launch-saved-terminal"].tap()
        XCTAssertTrue(app.staticTexts["Attached"].waitForExistence(timeout: 5))
        captureScreenshot(named: "saved-terminal-attached")
        app.buttons["terminal-detach"].tap()
        XCTAssertTrue(app.staticTexts["Detached"].waitForExistence(timeout: 5))
        captureScreenshot(named: "saved-terminal-detached")
        app.buttons["terminal-reconnect"].tap()
        XCTAssertTrue(app.staticTexts["Attached"].waitForExistence(timeout: 5))
        captureScreenshot(named: "saved-terminal-reconnected")
        app.buttons["back-to-hosts"].tap()
        XCTAssertTrue(app.navigationBars["SSH hosts"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTerminalDemoRendersAndExposesMobileKeys() {
        let app = XCUIApplication()
        app.launchArguments = ["--terminal-demo"]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["terminal-view"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Attached"].waitForExistence(timeout: 5))

        for identifier in [
            "key-esc",
            "key-ctrl",
            "key-tab",
            "key-↑",
            "key-↓",
            "key-←",
            "key-→",
            "key-pgup",
            "key-pgdn",
        ] {
            XCTAssertTrue(app.buttons[identifier].exists, "Missing mobile key \(identifier)")
        }

        app.buttons["terminal-detach"].tap()
        XCTAssertTrue(app.staticTexts["Detached"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["terminal-reconnect"].isEnabled)
        captureScreenshot(named: "terminal-session-demo")
    }

    @MainActor
    func testLivePhysicalTerminalReconnect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-session-profile"]
        app.launch()

        let terminal = app.descendants(matching: .any)["terminal-view"]
        guard terminal.waitForExistence(timeout: 5) else {
            throw XCTSkip("No terminal development session profile is staged.")
        }
        XCTAssertTrue(app.staticTexts["Attached"].waitForExistence(timeout: 30))

        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()

        app.buttons["terminal-detach"].tap()
        XCTAssertTrue(app.staticTexts["Detached"].waitForExistence(timeout: 5))

        try setWiFi(enabled: false)
        defer { try? setWiFi(enabled: true) }
        sleep(5)
        app.activate()

        app.buttons["terminal-reconnect"].tap()
        XCTAssertTrue(app.staticTexts["Attached"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.staticTexts["Reconnected to the same tmux session and process."]
                .waitForExistence(timeout: 5)
        )

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        // Do not retain the live terminal image: remote output is untrusted
        // and can contain endpoint, account, command, or project details.
        let attachment = XCTAttachment(
            string: "physical-terminal-suspend-cellular-reconnect-same-process"
        )
        attachment.name = "physical-terminal-session-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLivePhysicalRPCExchange() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-session-profile"]
        app.launch()

        guard app.descendants(matching: .any)["rpc-phase-banner"].waitForExistence(timeout: 5) else {
            throw XCTSkip("No RPC development session profile is staged.")
        }
        XCTAssertTrue(app.staticTexts["Attached"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["RPC exchange completed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Response frames: 1"].exists)
        captureScreenshot(named: "physical-rpc-session")

        let attachment = XCTAttachment(string: "physical-rpc-get-state-completed")
        attachment.name = "physical-rpc-session-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testRPCDemoCompletesStrictExchange() {
        let app = XCUIApplication()
        app.launchArguments = ["--rpc-demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Attached"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["RPC exchange completed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Response frames: 1"].exists)
        XCTAssertTrue(app.staticTexts["Event frames: 1"].exists)

        app.buttons["rpc-send-state"].tap()
        XCTAssertTrue(app.staticTexts["The state request completed."].waitForExistence(timeout: 3))
        captureScreenshot(named: "rpc-session-demo")
    }

    @MainActor
    private func setWiFi(enabled: Bool) throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        let wifiRow = settings.buttons["com.apple.settings.wifi"].firstMatch
        if wifiRow.waitForExistence(timeout: 3) {
            wifiRow.tap()
        }

        let wifiSwitch = settings.switches["Wi-Fi"].firstMatch
        XCTAssertTrue(wifiSwitch.waitForExistence(timeout: 5))
        let expectedValue = enabled ? "1" : "0"
        if wifiSwitch.value as? String != expectedValue {
            wifiSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: wifiSwitch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    @MainActor
    private func captureScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
