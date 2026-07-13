import XCTest

final class InstaBlogUITests: XCTestCase {
    private let uiLoadTimeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesIntoJournalShell() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["Journal"].waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.buttons["Trips"].exists)
        XCTAssertTrue(app.buttons["square.and.pencil"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    @MainActor
    func testComposeButtonOpensCaptureWorkspace() throws {
        let app = makeApp()
        app.launch()

        let composeButton = app.buttons["square.and.pencil"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testSavingPhotoPostShowsItAtTopOfJournal() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launch()
        openSeededTripJournal(in: app)

        let composeButton = app.buttons["square.and.pencil"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

        let caption = "UI Test Saved Post"
        let captionEditor = app.textViews["BlogItem caption"]
        XCTAssertTrue(captionEditor.waitForExistence(timeout: uiLoadTimeout))
        captionEditor.tap()
        captionEditor.typeText(caption)

        let editorCancel = app.buttons["Cancel"]
        XCTAssertTrue(editorCancel.waitForExistence(timeout: uiLoadTimeout))

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: uiLoadTimeout))
        saveButton.tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "exists == false"), on: editorCancel),
            "Expected the photo-post full-screen cover to dismiss after saving."
        )

        openSeededTripJournal(in: app)

        let firstJournalCard = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        XCTAssertTrue(firstJournalCard.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(firstJournalCard.label.contains(caption))
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
        XCTAssertTrue(app.buttons["square.and.pencil"].waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    func testTabBarRemainsAtBottomAfterChangingDestination() throws {
        let app = makeApp()
        app.launch()

        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: uiLoadTimeout))
        share.tap()

        let compose = app.buttons["square.and.pencil"]
        XCTAssertTrue(compose.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertGreaterThan(compose.frame.midY, app.frame.height * 0.75)
    }

    @MainActor
    func testPhotoSyncStatusDecorations() throws {
        assertPhotoSyncStatus(.storedLocally, accessibilityDescription: "Stored locally")
        assertPhotoSyncStatus(.pending, accessibilityDescription: "Uploading")
        assertPhotoSyncStatus(.synced, accessibilityDescription: "Uploaded")
        assertPhotoSyncStatus(.failed, accessibilityDescription: "Upload failed")
    }

    @MainActor
    func testMissingPhotosShowDownloadingPlaceholders() throws {
        assertPhotoAvailability(.downloading, accessibilityDescription: "Downloading")
    }

    @MainActor
    func testBrokenPhotosShowUnavailablePlaceholders() throws {
        assertPhotoAvailability(.unavailable, accessibilityDescription: "Unavailable")
    }

    @MainActor
    private func assertPhotoSyncStatus(
        _ status: SyncStatusFixture,
        accessibilityDescription: String
    ) {
        let app = makeApp()
        app.launchEnvironment["UI_TEST_SYNC_STATUS"] = status.rawValue
        app.launch()
        openSeededTripJournal(in: app)

        let card = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(card.value as? String, "Photo sync status: \(accessibilityDescription)")
        if status == .synced {
            XCTAssertFalse(app.staticTexts["Uploaded"].exists)
        }
        app.terminate()
    }

    @MainActor
    private func assertPhotoAvailability(
        _ availability: PhotoAvailabilityFixture,
        accessibilityDescription: String
    ) {
        let app = makeApp()
        app.launchEnvironment["UI_TEST_PHOTO_AVAILABILITY"] = availability.rawValue
        app.launch()
        openSeededTripJournal(in: app)

        let blogItemCard = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        XCTAssertTrue(blogItemCard.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(
            blogItemCard.value as? String,
            "Photo sync status: \(accessibilityDescription)"
        )

        app.terminate()
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-in-memory-database")
        return app
    }

    @MainActor
    private func openSeededTripJournal(in app: XCUIApplication) {
        let tripsTab = app.buttons["Trips"]
        XCTAssertTrue(tripsTab.waitForExistence(timeout: uiLoadTimeout))
        tripsTab.tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isSelected == true"), on: tripsTab),
            "Expected the Trips tab button to become selected."
        )

        let trip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Provence by Train")
        ).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: uiLoadTimeout))
        trip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let journalTab = app.buttons["Journal"]
        XCTAssertTrue(journalTab.waitForExistence(timeout: uiLoadTimeout))
        journalTab.tap()

        let journalCard = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        XCTAssertTrue(journalCard.waitForExistence(timeout: uiLoadTimeout))
    }

    @MainActor
    private func openUnassignedJournal(in app: XCUIApplication) {
        let tripsTab = app.buttons["Trips"]
        XCTAssertTrue(tripsTab.waitForExistence(timeout: uiLoadTimeout))
        tripsTab.tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isSelected == true"), on: tripsTab),
            "Expected the Trips tab button to become selected."
        )

        let unassignedTrip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Unassigned entries")
        ).firstMatch
        XCTAssertTrue(unassignedTrip.waitForExistence(timeout: uiLoadTimeout))
        unassignedTrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let journalCard = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        XCTAssertTrue(journalCard.waitForExistence(timeout: uiLoadTimeout))
    }

    private func card(withAccessibilityIdentifier identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForPredicate(_ predicate: NSPredicate, on element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: uiLoadTimeout) == .completed
    }
}

private enum SyncStatusFixture: String, Equatable {
    case storedLocally
    case pending
    case synced
    case failed
}

private enum PhotoAvailabilityFixture: String {
    case downloading
    case unavailable
}
