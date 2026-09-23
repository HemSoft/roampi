import XCTest

final class TransportProofUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstConnectionRequiresFingerprintConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--transport-proof-demo"]
        app.launch()

        XCTAssertTrue(app.navigationBars["SSH transport proof"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["connection-string"].value as? String, "operator@studio-mini")
        XCTAssertTrue(
            app.staticTexts[
                "Use any DNS hostname or IP address reachable from this device. " +
                    "Tailscale MagicDNS names and Tailscale IPs are optional."
            ].exists
        )
        captureScreenshot(named: "ssh-transport-initial")

        app.buttons["run-transport-probe"].tap()

        XCTAssertTrue(app.staticTexts["host-fingerprint"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.buttons["trust-host-key"].waitForExistence(timeout: 2))
        let reject = app.buttons["reject-host-key"]
        XCTAssertTrue(reject.exists)
        captureScreenshot(named: "ssh-host-key-confirmation")

        reject.tap()
        XCTAssertTrue(app.staticTexts["No connection attempted"].waitForExistence(timeout: 2))
        app.swipeDown()
        XCTAssertTrue(app.textFields["connection-string"].isEnabled)
    }

    @MainActor
    func testLivePhysicalSSHHandshake() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-transport-profile"]
        app.launch()

        let run = app.buttons["run-transport-probe"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        guard run.isEnabled else {
            throw XCTSkip("No private development transport profile is staged.")
        }

        run.tap()
        let fingerprint = app.staticTexts["host-fingerprint"]
        let passed = app.staticTexts["Verified SSH command completed once"]
        let authenticationFailed = app.staticTexts[
            "Authentication failed. Verify the selected method and remote authorization."
        ]

        if fingerprint.waitForExistence(timeout: 10) {
            app.swipeUp()
            let trust = app.buttons["verified-trust-host-key"]
            XCTAssertTrue(trust.waitForExistence(timeout: 3))
            trust.tap()
        }

        let reachedExpectedResult = passed.waitForExistence(timeout: 20) || authenticationFailed.exists
        XCTAssertTrue(reachedExpectedResult)

        let result = passed.exists ? "probe-passed" : "authentication-rejected-after-verified-handshake"
        let attachment = XCTAttachment(string: result)
        attachment.name = "physical-ssh-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLivePhysicalCancellation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-transport-profile"]
        app.launch()

        let run = app.buttons["run-transport-probe"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        guard run.isEnabled else {
            throw XCTSkip("No private development transport profile is staged.")
        }

        run.tap()
        let cancel = app.buttons["cancel-transport-probe"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(app.staticTexts["The probe was cancelled."].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(string: "pending-connection-cancelled")
        attachment.name = "physical-ssh-cancellation-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLivePhysicalDisconnect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-transport-profile"]
        app.launch()

        let run = app.buttons["run-transport-probe"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        guard run.isEnabled else {
            throw XCTSkip("No private development transport profile is staged.")
        }

        run.tap()
        let fingerprint = app.staticTexts["host-fingerprint"]
        if fingerprint.waitForExistence(timeout: 10) {
            app.swipeUp()
            let trust = app.buttons["verified-trust-host-key"]
            XCTAssertTrue(trust.waitForExistence(timeout: 3))
            trust.tap()
        }

        let messages = [
            "The SSH connection failed. Check the network route and remote SSH availability.",
            "The harmless probe did not return the expected result.",
            "The SSH probe timed out. Check the host and try again.",
        ]
        let stopped = app.staticTexts.matching(NSPredicate(format: "label IN %@", messages)).firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 40))

        let attachment = XCTAttachment(string: "active-connection-stopped-without-success")
        attachment.name = "physical-ssh-disconnect-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLivePhysicalChangedHostKeyBlocks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-transport-profile"]
        app.launch()

        let run = app.buttons["run-transport-probe"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        guard run.isEnabled else {
            throw XCTSkip("No private development transport profile is staged.")
        }

        run.tap()
        XCTAssertTrue(
            app.staticTexts[
                "The saved host key changed. RoamPi blocked the connection before authentication."
            ].waitForExistence(timeout: 20)
        )

        let attachment = XCTAttachment(string: "changed-key-blocked-before-command")
        attachment.name = "physical-ssh-changed-host-key-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLivePhysicalTailscaleSSHStandardKeyFallback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-transport-profile"]
        app.launch()

        let run = app.buttons["run-transport-probe"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        guard run.isEnabled else {
            throw XCTSkip("No private development transport profile is staged.")
        }

        let authentication = app.buttons["authentication-mode"]
        XCTAssertTrue(authentication.waitForExistence(timeout: 3))
        authentication.tap()
        let tailscaleMode = app.buttons["Tailscale SSH, then key"]
        XCTAssertTrue(tailscaleMode.waitForExistence(timeout: 3))
        tailscaleMode.tap()

        run.tap()
        let fingerprint = app.staticTexts["host-fingerprint"]
        if fingerprint.waitForExistence(timeout: 10) {
            app.swipeUp()
            let trust = app.buttons["verified-trust-host-key"]
            XCTAssertTrue(trust.waitForExistence(timeout: 3))
            trust.tap()
        }

        XCTAssertTrue(
            app.staticTexts["Verified SSH command completed once"].waitForExistence(timeout: 30)
        )
        XCTAssertTrue(
            app.staticTexts["Authentication, Ed25519 key"].waitForExistence(timeout: 3)
        )
        let attachment = XCTAttachment(string: "none-rejected-standard-key-fallback-passed")
        attachment.name = "physical-tailscale-ssh-fallback-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLivePhysicalCellularSSHHandshake() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--install-development-transport-profile"]
        app.launch()

        let run = app.buttons["run-transport-probe"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        guard run.isEnabled else {
            throw XCTSkip("No private development transport profile is staged.")
        }

        try setWiFi(enabled: false)
        defer { try? setWiFi(enabled: true) }
        sleep(5)
        app.activate()

        run.tap()
        let fingerprint = app.staticTexts["host-fingerprint"]
        if fingerprint.waitForExistence(timeout: 10) {
            app.swipeUp()
            let trust = app.buttons["verified-trust-host-key"]
            XCTAssertTrue(trust.waitForExistence(timeout: 3))
            trust.tap()
        }

        let passed = app.staticTexts["Verified SSH command completed once"]
        let stoppedMessages = [
            "The SSH connection failed. Check the network route and remote SSH availability.",
            "The harmless probe did not return the expected result.",
            "The SSH probe timed out. Check the host and try again.",
        ]
        let stopped = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", stoppedMessages)
        ).firstMatch
        let reachedFirstResult = passed.waitForExistence(timeout: 30) || stopped.exists
        XCTAssertTrue(reachedFirstResult)

        let result: String
        if passed.exists {
            result = "probe-passed-over-cellular"
        } else {
            XCTAssertTrue(run.waitForExistence(timeout: 3))
            run.tap()
            XCTAssertTrue(passed.waitForExistence(timeout: 30))
            result = "handoff-stopped-then-cellular-reconnect-passed"
        }

        let attachment = XCTAttachment(string: result)
        attachment.name = "physical-cellular-ssh-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testTrustedDemoProbeCompletesOnce() {
        let app = XCUIApplication()
        app.launchArguments = ["--transport-proof-demo"]
        app.launch()

        app.buttons["run-transport-probe"].tap()
        XCTAssertTrue(app.staticTexts["host-fingerprint"].waitForExistence(timeout: 5))
        app.swipeUp()
        let trust = app.buttons["trust-host-key"]
        XCTAssertTrue(trust.waitForExistence(timeout: 2))
        trust.tap()

        XCTAssertTrue(app.staticTexts["Verified SSH command completed once"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ed25519 key"].exists)
        captureScreenshot(named: "ssh-transport-success")
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
