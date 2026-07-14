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
    func testJournalBlogItemLayoutAlignsAddButtonWithPhotoAndLocation() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let captionText = "Flamingos gathering in the late light."
        let card = journalCard(containing: captionText, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        let photo = descendant(withAccessibilityIdentifier: "Journal blog item photo", in: card)
        let text = descendant(withAccessibilityIdentifier: "Journal blog item text", in: card)
        let metadataPill = descendant(withAccessibilityIdentifier: "Journal blog item metadata pill", in: card)
        let uploadStatusPill = descendant(
            withAccessibilityIdentifier: "Journal blog item upload status pill",
            in: card
        )
        let location = app.staticTexts
            .matching(identifier: "Journal blog item location")
            .matching(NSPredicate(format: "label == %@", "Pont de Gau"))
            .firstMatch
        let addButton = addButton(alignedWith: location, in: app)

        XCTAssertTrue(photo.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(text.exists)
        XCTAssertEqual(text.label, captionText)
        XCTAssertTrue(metadataPill.exists)
        XCTAssertTrue(metadataPill.label.contains("Rog"))
        XCTAssertTrue(card.label.contains("24.0 degrees"))
        XCTAssertTrue(uploadStatusPill.exists)
        XCTAssertTrue(location.exists)
        XCTAssertTrue(addButton.exists)

        XCTAssertEqual(photo.frame.minX, card.frame.minX, accuracy: 2)
        XCTAssertEqual(photo.frame.maxX, card.frame.maxX, accuracy: 2)
        XCTAssertTrue(photo.frame.contains(metadataPill.frame))
        XCTAssertTrue(photo.frame.contains(uploadStatusPill.frame))
        XCTAssertGreaterThanOrEqual(text.frame.minY, photo.frame.maxY)
        XCTAssertGreaterThanOrEqual(location.frame.minY, text.frame.maxY)
        XCTAssertEqual(text.frame.minX, photo.frame.minX, accuracy: 2)
        XCTAssertEqual(location.frame.minX, photo.frame.minX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(addButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(addButton.frame.height, 44)
        XCTAssertEqual(addButton.frame.maxX, photo.frame.maxX, accuracy: 2)
        XCTAssertEqual(addButton.frame.midY, location.frame.midY, accuracy: 2)
    }

    @MainActor
    func testAddBlogItemButtonOpensBlankDetail() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let captionText = "Flamingos gathering in the late light."
        var card = journalCard(containing: captionText, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        var photo = descendant(withAccessibilityIdentifier: "Journal blog item photo", in: card)
        tapScreenPoint(photo.frame.center, in: app)
        assertDetailShows(caption: captionText, in: app)
        app.buttons["Cancel"].tap()

        card = journalCard(containing: captionText, in: app)
        let text = descendant(withAccessibilityIdentifier: "Journal blog item text", in: card)
        tapScreenPoint(text.frame.center, in: app)
        assertDetailShows(caption: captionText, in: app)
        app.buttons["Cancel"].tap()

        card = journalCard(containing: captionText, in: app)
        photo = descendant(withAccessibilityIdentifier: "Journal blog item photo", in: card)
        let initialCardCount = app.descendants(matching: .any)
            .matching(identifier: "Journal blog item card")
            .count
        let location = app.staticTexts
            .matching(identifier: "Journal blog item location")
            .matching(NSPredicate(format: "label == %@", "Pont de Gau"))
            .firstMatch
        let addButton = addButton(alignedWith: location, in: app)
        XCTAssertTrue(addButton.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertGreaterThanOrEqual(addButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(addButton.frame.height, 44)

        let targetPoint = CGPoint(x: addButton.frame.minX + 2, y: addButton.frame.midY)
        XCTAssertLessThan(targetPoint.x, addButton.frame.maxX - 28)
        tapScreenPoint(targetPoint, in: app)

        let caption = app.textViews["BlogItem caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(caption.value as? String, "")
        let photoPlaceholder = app.buttons["BlogItem photo placeholder"]
        XCTAssertTrue(photoPlaceholder.exists)

        let locationField = app.textFields["BlogItem location"]
        let temperatureField = app.textFields["BlogItem temperature"]
        XCTAssertTrue(locationField.exists)
        XCTAssertTrue(temperatureField.exists)
        XCTAssertEqual(locationField.value as? String, locationField.placeholderValue)
        XCTAssertEqual(temperatureField.value as? String, temperatureField.placeholderValue)
        XCTAssertTrue(app.buttons["Change date"].exists)
        XCTAssertTrue(app.buttons["Change time"].exists)
        XCTAssertTrue(app.buttons["BlogItem weather condition"].exists)
        XCTAssertEqual(app.buttons["BlogItem weather condition"].label, "Unknown")
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.exists)
        XCTAssertFalse(saveButton.isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "exists == false"), on: caption),
            "Expected cancelling a new item to dismiss its detail view."
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "Journal blog item card")
                .count,
            initialCardCount,
            "Expected cancelling a new item to delete it from the journal."
        )
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

    private func journalCard(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "Journal blog item card")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func descendant(withAccessibilityIdentifier identifier: String, in element: XCUIElement) -> XCUIElement {
        element.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func addButton(alignedWith location: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "Add blog item")
            .allElementsBoundByIndex
            .min { lhs, rhs in
                abs(lhs.frame.midY - location.frame.midY) < abs(rhs.frame.midY - location.frame.midY)
            } ?? app.descendants(matching: .any).matching(identifier: "Add blog item").firstMatch
    }

    private func tapScreenPoint(_ point: CGPoint, in app: XCUIApplication) {
        let appFrame = app.frame
        app.coordinate(
            withNormalizedOffset: CGVector(
                dx: (point.x - appFrame.minX) / appFrame.width,
                dy: (point.y - appFrame.minY) / appFrame.height
            )
        ).tap()
    }

    private func assertDetailShows(caption expectedCaption: String, in app: XCUIApplication) {
        let caption = app.textViews["BlogItem caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(caption.value as? String, expectedCaption)
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

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
