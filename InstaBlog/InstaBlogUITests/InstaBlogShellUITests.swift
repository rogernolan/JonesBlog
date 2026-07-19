import XCTest
import UIKit

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
    func testEmptyJournalShowsPlaceholderAndNewEntryAction() throws {
        let app = makeApp()
        app.launchArguments.append(contentsOf: [
            "-ui-testing-empty-current-trip",
            "-ui-testing-seed-photo-post-draft"
        ])
        app.launch()

        XCTAssertTrue(app.staticTexts["No entries"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.staticTexts["You will see a list of your blog entries here"].exists)
        XCTAssertTrue(app.images["Empty blog placeholder"].exists)

        let newEntryButton = app.buttons["Empty placeholder New Entry"]
        XCTAssertTrue(newEntryButton.exists)
        newEntryButton.tap()

        XCTAssertTrue(app.textViews["BlogItem blog text"].waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testNoCurrentTripRetainsStartTripPlaceholder() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-empty-blog")
        app.launch()

        XCTAssertTrue(app.staticTexts["No Current Trip"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.staticTexts["Start a trip to add new journal entries."].exists)

        if UIDevice.current.userInterfaceIdiom == .phone {
            let journalHeader = app.staticTexts
                .matching(identifier: "Primary screen header title")
                .matching(NSPredicate(format: "label == %@", "Journal"))
                .firstMatch
            XCTAssertTrue(journalHeader.exists)
            let journalHeaderMinY = journalHeader.frame.minY

            app.buttons["Trips"].tap()
            let tripsHeader = app.staticTexts
                .matching(identifier: "Primary screen header title")
                .matching(NSPredicate(format: "label == %@", "Trips"))
                .firstMatch
            XCTAssertTrue(tripsHeader.waitForExistence(timeout: uiLoadTimeout))
            XCTAssertEqual(tripsHeader.frame.minY, journalHeaderMinY, accuracy: 1)

            app.buttons["Journal"].tap()
            XCTAssertTrue(app.staticTexts["No Current Trip"].waitForExistence(timeout: uiLoadTimeout))
        }

        let startTripButton = app.buttons["Start new trip"]
        XCTAssertTrue(startTripButton.exists)
        startTripButton.tap()

        XCTAssertTrue(app.textFields["Trip title"].waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testEmptyTripsShowsPlaceholderAndNewTripAction() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-empty-blog")
        app.launch()

        let tripsTab = app.buttons["Trips"]
        XCTAssertTrue(tripsTab.waitForExistence(timeout: uiLoadTimeout))
        if app.buttons["Show menu"].exists {
            app.buttons["Show menu"].tap()
        }
        tripsTab.tap()

        XCTAssertTrue(app.staticTexts["No trips"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.staticTexts["You will see a list of your blog trips here"].exists)
        XCTAssertTrue(app.images["Empty blog placeholder"].exists)

        let newTripButton = app.buttons["Empty placeholder New Trip"]
        XCTAssertTrue(newTripButton.exists)
        newTripButton.tap()

        XCTAssertTrue(app.textFields["Trip title"].waitForExistence(timeout: uiLoadTimeout))
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

}
