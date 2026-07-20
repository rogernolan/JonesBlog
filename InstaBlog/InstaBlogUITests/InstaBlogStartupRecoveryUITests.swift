import XCTest

final class InstaBlogStartupRecoveryUITests: InstaBlogUITestCase {
    @MainActor
    func testStaleIdentityOffersAvailableBloggersAndUsesSelection() throws {
        let app = recoveryApp()
        app.launch()

        XCTAssertTrue(app.buttons["Jane"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.buttons["Rog"].exists)
        XCTAssertTrue(app.buttons["Create New Blogger"].exists)

        app.buttons["Jane"].tap()

        XCTAssertTrue(app.buttons["Journal"].waitForExistence(timeout: uiLoadTimeout))
        app.buttons["Settings"].tap()
        let displayName = app.textFields["Settings display name"]
        XCTAssertTrue(displayName.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(displayName.value as? String, "Jane")
    }

    @MainActor
    func testStaleIdentityCanCreateAndUseNewBlogger() throws {
        let app = recoveryApp()
        app.launch()

        let createNewBlogger = app.buttons["Create New Blogger"]
        XCTAssertTrue(createNewBlogger.waitForExistence(timeout: uiLoadTimeout))
        createNewBlogger.tap()

        let displayName = app.textFields["Display name"]
        XCTAssertTrue(displayName.waitForExistence(timeout: uiLoadTimeout))
        displayName.tap()
        displayName.typeText("Alex")
        app.buttons["Create"].tap()

        XCTAssertTrue(app.buttons["Journal"].waitForExistence(timeout: uiLoadTimeout))
        app.buttons["Settings"].tap()
        let settingsDisplayName = app.textFields["Settings display name"]
        XCTAssertTrue(settingsDisplayName.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(settingsDisplayName.value as? String, "Alex")
    }

    @MainActor
    func testStartupFailureCanRetryWithoutResettingData() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-startup-failure-once")
        app.launch()

        XCTAssertTrue(app.staticTexts["Unable to Open InstaBlog"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(
            app.staticTexts["InstaBlog could not prepare its database. Your data has not been changed. Please try again."].exists
        )

        app.buttons["Try Again"].tap()

        XCTAssertTrue(app.buttons["Journal"].waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testMissingActiveBlogIsRepairedDuringLaunch() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-missing-active-blog")
        app.launch()

        XCTAssertTrue(app.buttons["Journal"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertFalse(app.staticTexts["Unable to Open InstaBlog"].exists)
    }

    private func recoveryApp() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-stale-blogger-identity")
        return app
    }
}
