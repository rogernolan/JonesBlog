import XCTest

final class InstaBlogUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesIntoJournalShell() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["Journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Trips"].exists)
        XCTAssertTrue(app.buttons["New BlogItem"].exists)
        XCTAssertTrue(app.buttons["Search"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.staticTexts["Provence by Train"].exists)
    }

    @MainActor
    func testComposeButtonOpensCaptureWorkspace() throws {
        let app = makeApp()
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 5))
        composeButton.tap()

        XCTAssertTrue(app.navigationBars["New Photo Post"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSavingPhotoPostShowsItAtTopOfJournal() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchEnvironment["UI_TEST_PHOTO_POST_CAPTION"] = "UI Test Saved Post"
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 5))
        composeButton.tap()

        XCTAssertTrue(app.navigationBars["New BlogItem"].waitForExistence(timeout: 5))

        let caption = "UI Test Saved Post"
        let captionEditor = app.textViews["Photo post caption"]
        XCTAssertTrue(captionEditor.waitForExistence(timeout: 5))

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        let newPost = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", caption)
        ).firstMatch
        XCTAssertTrue(newPost.waitForExistence(timeout: 5))

        let firstJournalCard = app.buttons["Journal blog item card"].firstMatch
        XCTAssertTrue(firstJournalCard.waitForExistence(timeout: 5))
        XCTAssertTrue(firstJournalCard.label.contains(caption))
    }

    @MainActor
    func testJournalOpensAtLatestDay() throws {
        let app = makeApp()
        app.launch()

        let latestDay = app.staticTexts["DAY 2 OF 2"]
        XCTAssertTrue(latestDay.waitForExistence(timeout: 5))
        XCTAssertTrue(latestDay.isHittable)
        XCTAssertFalse(app.staticTexts["DAY 1 OF 2"].isHittable)
    }

    @MainActor
    func testDetailHidesAppTabBar() throws {
        let app = makeApp()
        app.launch()

        let blogItem = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'BlogItem by Jane'")
        ).element
        XCTAssertTrue(blogItem.waitForExistence(timeout: 5))
        blogItem.tap()

        XCTAssertTrue(app.navigationBars["BlogItem"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New BlogItem"].exists)
    }

    @MainActor
    func testTabBarRemainsAtBottomAfterChangingDestination() throws {
        let app = makeApp()
        app.launch()

        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()

        let compose = app.buttons["New BlogItem"]
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(compose.frame.midY, app.frame.height * 0.75)
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-in-memory-database")
        return app
    }
}
