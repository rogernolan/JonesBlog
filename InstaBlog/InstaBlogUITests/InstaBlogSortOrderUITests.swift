import XCTest

final class InstaBlogSortOrderUITests: InstaBlogUITestCase {
    @MainActor
    func testSortToggleAppearsInEllipsisMenu() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        app.buttons["Trip actions"].tap()
        let sortButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Oldest first")
        ).firstMatch
        XCTAssertTrue(
            sortButton.waitForExistence(timeout: uiLoadTimeout),
            "Expected a sort toggle in the ellipsis menu."
        )
    }

    @MainActor
    func testSortToggleChangesLabel() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        app.buttons["Trip actions"].tap()
        let oldestFirst = app.buttons.matching(
            NSPredicate(format: "label == %@", "Oldest first")
        ).firstMatch
        XCTAssertTrue(oldestFirst.waitForExistence(timeout: uiLoadTimeout))
        oldestFirst.tap()

        app.buttons["Trip actions"].tap()
        let newestFirst = app.buttons.matching(
            NSPredicate(format: "label == %@", "Newest first")
        ).firstMatch
        XCTAssertTrue(newestFirst.waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testDefaultJournalSortShowsNewestDayFirst() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let day2Header = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "DAY 2 OF")
        ).firstMatch
        XCTAssertTrue(
            day2Header.waitForExistence(timeout: uiLoadTimeout),
            "Expected Day 2 to be visible in the default newest-first journal sort."
        )
    }

    @MainActor
    func testTogglingSortReversesDayOrder() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let day2Header = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "DAY 2 OF")
        ).firstMatch
        XCTAssertTrue(day2Header.waitForExistence(timeout: uiLoadTimeout))

        app.buttons["Trip actions"].tap()
        app.buttons.matching(
            NSPredicate(format: "label == %@", "Oldest first")
        ).firstMatch.tap()

        let day1Header = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "DAY 1 OF")
        ).firstMatch
        XCTAssertTrue(
            day1Header.waitForExistence(timeout: uiLoadTimeout),
            "Expected Day 1 to become visible after toggling to oldest-first."
        )
    }

    @MainActor
    func testJournalTabReselectShowsJournalContent() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad uses sidebar navigation rather than the iPhone tab bar."
        )

        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let journalTab = app.buttons["Journal"]
        XCTAssertTrue(journalTab.waitForExistence(timeout: uiLoadTimeout))
        journalTab.tap()

        let journalTitle = app.staticTexts["Journal trip title"]
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "exists == true"), on: journalTitle),
            "Expected the journal content to remain visible after tapping Journal tab."
        )
    }
}
