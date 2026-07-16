import XCTest

final class InstaBlogShellUITests: InstaBlogUITestCase {
    @MainActor
    func testLaunchesIntoJournalShell() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["Journal"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.buttons["Trips"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.buttons["New BlogItem"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testComposeButtonOpensCaptureWorkspace() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

        XCTAssertTrue(app.textViews["BlogItem blog text"].waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testTabBarRemainsAtBottomAfterChangingDestination() throws {
        let app = makeApp()
        app.launch()

        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: uiLoadTimeout))
        share.tap()

        let compose = app.buttons["New BlogItem"]
        XCTAssertTrue(compose.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertGreaterThan(compose.frame.midY, app.frame.height * 0.75)
    }

    @MainActor
    func testComposeButtonIsHiddenWhileEditingSettings() throws {
        let app = makeApp()
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: uiLoadTimeout))
        settings.tap()

        let editDisplayName = app.buttons["Edit Display name"]
        XCTAssertTrue(editDisplayName.waitForExistence(timeout: uiLoadTimeout))
        editDisplayName.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertFalse(app.buttons["New BlogItem"].exists)
    }
}
