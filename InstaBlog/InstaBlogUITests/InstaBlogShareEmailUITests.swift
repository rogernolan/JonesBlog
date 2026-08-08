import XCTest

final class InstaBlogShareEmailUITests: InstaBlogUITestCase {
    @MainActor
    func testEmailPreviewShowsRecipientBccCount() throws {
        let app = makeApp()
        app.launch()

        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: uiLoadTimeout))
        share.tap()

        let recipientsRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Email recipients")
        ).firstMatch
        XCTAssertTrue(recipientsRow.waitForExistence(timeout: uiLoadTimeout))
        recipientsRow.tap()

        let addRecipient = app.buttons["Add recipient"]
        XCTAssertTrue(addRecipient.waitForExistence(timeout: uiLoadTimeout))
        addRecipient.tap()

        let emailField = app.textFields["Recipient email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: uiLoadTimeout))
        emailField.tap()
        emailField.typeText("rog@example.com")

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: uiLoadTimeout))
        addButton.tap()

        let recipientsNavBar = app.navigationBars["Recipients"]
        XCTAssertTrue(recipientsNavBar.waitForExistence(timeout: uiLoadTimeout))
        recipientsNavBar.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(
            app.staticTexts["1 recipient"].waitForExistence(timeout: uiLoadTimeout),
            "Expected the recipients count to appear on the Share screen after saving."
        )

        let generate = app.buttons["Generate shared post"]
        XCTAssertTrue(generate.waitForExistence(timeout: uiLoadTimeout))
        generate.tap()

        let bccCount = app.staticTexts["1 recipient (BCC)"]
        XCTAssertTrue(
            bccCount.waitForExistence(timeout: uiLoadTimeout),
            "Expected the email preview to show the recipient count for the BCC list."
        )
    }
}
