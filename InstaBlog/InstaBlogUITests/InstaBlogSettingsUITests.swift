import XCTest

final class InstaBlogSettingsUITests: InstaBlogUITestCase {
    @MainActor
    func testSettingsViewDisplaysCloudSharingAndIdentitySections() {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-open-tab=settings")
        app.launch()

        let settingsHeader = app.staticTexts["Settings"]
        XCTAssertTrue(settingsHeader.waitForExistence(timeout: uiLoadTimeout))

        let displayNameField = app.textFields["Settings display name"]
        XCTAssertTrue(
            displayNameField.waitForExistence(timeout: uiLoadTimeout),
            "Expected the Display Name text field to be visible in Settings."
        )

        let exportButton = app.buttons["Export Blog Archive"]
        XCTAssertTrue(
            exportButton.waitForExistence(timeout: uiLoadTimeout),
            "Expected the Export Blog Archive button to be visible in Settings."
        )
    }

}
