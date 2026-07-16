import XCTest

final class InstaBlogJournalNavigationUITests: InstaBlogUITestCase {
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
