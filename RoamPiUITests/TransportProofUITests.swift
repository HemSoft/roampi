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
                "Use a MagicDNS name, full .ts.net name, or Tailscale IP. " +
                    "RoamPi never asks for Tailscale account credentials."
            ].exists
        )
        captureScreenshot(named: "ssh-transport-initial")

        app.buttons["run-transport-probe"].tap()

        XCTAssertTrue(app.staticTexts["host-fingerprint"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(app.buttons["trust-host-key"].waitForExistence(timeout: 2))
        captureScreenshot(named: "ssh-host-key-confirmation")
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

    private func captureScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
