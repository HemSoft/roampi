import XCTest

final class RoamPiUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoDashboardLaunchesWithoutOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Good evening"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["machine-studio-mini"].exists)
        XCTAssertTrue(app.staticTexts["Review offline sync"].exists)
        XCTAssertTrue(app.staticTexts["Running"].exists)
        XCTAssertFalse(app.staticTexts["Remote connection setup is coming next."].exists)
    }

    @MainActor
    func testSwitchesBetweenFictionalMachines() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()

        let buildBox = app.buttons["machine-build-box"]
        XCTAssertTrue(buildBox.waitForExistence(timeout: 5))
        buildBox.tap()

        XCTAssertTrue(app.staticTexts["Profile cache misses"].waitForExistence(timeout: 2))
    }
}
