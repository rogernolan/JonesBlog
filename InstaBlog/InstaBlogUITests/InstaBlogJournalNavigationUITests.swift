import XCTest
import UIKit

final class InstaBlogJournalNavigationUITests: InstaBlogUITestCase {
    @MainActor
    func testJournalHeaderLeadingPositionMatchesDeviceLayout() throws {
        let app = makeApp()
        app.launch()

        let title = app.staticTexts["Journal trip title"]
        XCTAssertTrue(title.waitForExistence(timeout: uiLoadTimeout))

        let menuButton = app.buttons["Show menu"]
        if menuButton.exists {
            XCTAssertGreaterThanOrEqual(
                title.frame.minX,
                menuButton.frame.maxX,
                "The iPad journal title should leave room for the menu button."
            )
        } else {
            XCTAssertEqual(
                title.frame.minX,
                app.frame.minX + 18,
                accuracy: 2,
                "The iPhone journal title should have no leading action offset."
            )
        }
    }

    @MainActor
    func testJournalHeaderCollapsePreservesDeviceSpecificPositioning() throws {
        let expandedApp = makeApp()
        expandedApp.launch()

        let expandedTitle = expandedApp.staticTexts["Journal trip title"]
        XCTAssertTrue(expandedTitle.waitForExistence(timeout: uiLoadTimeout))
        let expandedWidth = expandedTitle.frame.width
        expandedApp.terminate()

        let app = makeApp()
        app.launchArguments.append("-ui-testing-collapsed-journal-header")
        app.launch()

        let title = app.staticTexts["Journal trip title"]
        XCTAssertTrue(title.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertLessThan(
            title.frame.width,
            expandedWidth - 20,
            "Expected the journal title to use its collapsed width."
        )

        let menuButton = app.buttons["Show menu"]
        if menuButton.exists {
            XCTAssertGreaterThanOrEqual(
                title.frame.minX,
                menuButton.frame.maxX,
                "The collapsing iPad title should continue to leave room for the menu button."
            )
        } else {
            XCTAssertEqual(
                title.frame.midX,
                app.frame.midX - 26,
                accuracy: 3,
                "The collapsing iPhone title should use the original trailing-action reservation."
            )
        }
    }

    @MainActor
    func testJournalOpensAtLatestDay() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let latestDay = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "DAY 2 OF")
        ).firstMatch
        XCTAssertTrue(latestDay.waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testJournalHeaderHasActionsAndNoBackButton() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        XCTAssertTrue(app.staticTexts["Journal trip title"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.buttons["Trip actions"].exists)
        XCTAssertFalse(app.buttons["Back"].exists)
    }

    @MainActor
    func testDetailHidesAppTabBar() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad uses a sidebar and floating compose control rather than the iPhone tab bar."
        )

        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let journalCards = app.descendants(matching: .any)
            .matching(identifier: "Journal blog item card")
        let blogItem = journalCards.allElementsBoundByIndex.first {
            $0.frame.intersects(app.frame)
        } ?? journalCards.firstMatch
        XCTAssertTrue(blogItem.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(blogItem.label.contains("BlogItem by"))
        tapScreenPoint(blogItem.frame.center, in: app)
        XCTAssertTrue(app.textViews["BlogItem blog text"].waitForExistence(timeout: uiLoadTimeout))

        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "hittable == false"), on: app.buttons["Journal"])
        )
        XCTAssertFalse(app.buttons["Trips"].isHittable)
        XCTAssertFalse(app.buttons["New BlogItem"].isHittable)
    }
}
