import XCTest

final class InstaBlogJournalEditingUITests: InstaBlogUITestCase {
    @MainActor
    func testSavingPhotoPostShowsItAtTopOfJournal() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launch()
        openSeededTripJournal(in: app)

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

        let caption = "UI Test Saved Post"
        let captionEditor = app.textViews["BlogItem blog text"]
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
    func testGalleryMetadataPillStaysBelowFilmstripPhotos() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-gallery")
        app.launch()
        openSeededTripJournal(in: app)

        let card = journalCard(containing: "Flamingos gathering in the late light.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        let filmstrip = app.descendants(matching: .any)
            .matching(identifier: "Journal blog item photo strip")
            .firstMatch
        let metadataPill = descendant(
            withAccessibilityIdentifier: "Journal blog item metadata pill",
            in: card
        )

        XCTAssertTrue(filmstrip.exists)
        XCTAssertTrue(metadataPill.exists)
        XCTAssertTrue(metadataPill.label.contains("24"))
        XCTAssertEqual(
            metadataPill.frame.minY - filmstrip.frame.maxY,
            4,
            accuracy: 1,
            "Expected four points of padding above the gallery metadata pill."
        )
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

        let caption = app.textViews["BlogItem blog text"]
        XCTAssertTrue(caption.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(caption.value as? String, "")
        XCTAssertTrue(app.buttons["Add Photo"].exists)

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
}
