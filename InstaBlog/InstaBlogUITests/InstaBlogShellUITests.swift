import XCTest
import UIKit

final class InstaBlogShellUITests: InstaBlogUITestCase {
    @MainActor
    func testSettingsDisplayNameClearButtonOnlyAppearsWhileEditingAndClearsText() throws {
        let app = makeApp()
        app.launch()

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["Show menu"].waitForExistence(timeout: uiLoadTimeout))
            app.buttons["Show menu"].tap()
        }
        let settingsButtons = app.buttons.matching(identifier: "Settings")
        XCTAssertTrue(settingsButtons.firstMatch.waitForExistence(timeout: uiLoadTimeout))
        settingsButtons.element(boundBy: settingsButtons.count - 1).tap()

        let displayName = app.textFields["Settings display name"]
        let clearDisplayName = app.buttons["Clear display name"]
        XCTAssertTrue(displayName.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertFalse(clearDisplayName.isHittable)

        displayName.tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isHittable == true"), on: clearDisplayName)
        )

        clearDisplayName.tap()

        XCTAssertEqual(displayName.value as? String, displayName.placeholderValue)
        XCTAssertFalse(clearDisplayName.isHittable)
        displayName.tap()
        displayName.typeText("New Test Name")
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "value == %@", "New Test Name"),
                on: displayName
            ),
            "Expected the display name field to update to the newly typed name."
        )
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isHittable == true"), on: clearDisplayName),
            "Expected the clear button to appear after typing into the focused field."
        )
    }

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
    func testComposeButtonVisibilityInJournalAndTrips() throws {
        let app = makeApp()
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isHittable == true"), on: composeButton),
            composeButton.debugDescription
        )
        XCTAssertEqual(composeButton.frame.midX, app.frame.midX, accuracy: 1)

        if UIDevice.current.userInterfaceIdiom == .pad {
            let showMenu = app.buttons["Show menu"]
            XCTAssertTrue(showMenu.waitForExistence(timeout: uiLoadTimeout))
            showMenu.tap()
        }

        app.buttons["Trips"].tap()

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(
                waitForPredicate(NSPredicate(format: "isHittable == false"), on: composeButton)
            )
        } else {
            XCTAssertTrue(composeButton.isHittable)
        }

        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["Show menu"].tap()
        }

        app.buttons["Journal"].tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isHittable == true"), on: composeButton)
        )
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
    func testEmptyBlogShowsAllEntriesJournalAndStartsFirstTripFromTrips() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-empty-blog")
        app.launch()

        XCTAssertTrue(app.staticTexts["No entries"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.staticTexts["You will see a list of your blog entries here"].exists)

        if UIDevice.current.userInterfaceIdiom == .phone {
            app.buttons["Trips"].tap()
        } else {
            app.buttons["Show menu"].tap()
            app.buttons["Trips"].tap()
        }

        XCTAssertTrue(app.staticTexts["No trips"].waitForExistence(timeout: uiLoadTimeout))
        let newTripButton = app.buttons["Empty placeholder New Trip"]
        XCTAssertTrue(newTripButton.exists)
        newTripButton.tap()

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
