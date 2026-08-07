import XCTest

final class InstaBlogSettingsUITests: InstaBlogUITestCase {
    @MainActor
    func testSettingsViewDisplaysCloudSharingAndIdentitySections() {
        let app = makeApp()
        app.launch()

        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: uiLoadTimeout))
        settingsTab.tap()

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

    @MainActor
    func testSettingsDisplayNameCanBeEdited() {
        let app = makeApp()
        app.launch()

        let settingsTab = app.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: uiLoadTimeout))
        settingsTab.tap()

        let displayNameField = app.textFields["Settings display name"]
        XCTAssertTrue(displayNameField.waitForExistence(timeout: uiLoadTimeout))

        displayNameField.tap()
        
        let clearButton = app.buttons["Clear display name"]
        if clearButton.waitForExistence(timeout: 2) {
            clearButton.tap()
        }

        displayNameField.typeText("New Test Name\n")

        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "value == %@", "New Test Name"),
                on: displayNameField
            ),
            "Expected the display name field to update to the newly typed name."
        )
    }
}
