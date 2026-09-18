import XCTest
import UIKit

final class InstaBlogJournalEditingUITests: InstaBlogUITestCase {
    @MainActor
    func testDetailUsesCelsiusDegreeLabelAndKeepsLocationFieldSnugToChevron() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-open-detail")
        app.launch()

        let location = app.textFields["BlogItem location"]
        XCTAssertTrue(location.waitForExistence(timeout: uiLoadTimeout))
        location.tap()
        location.typeText("A very long location name used to verify the detail row layout")
        app.textViews["BlogItem blog text"].tap()

        _ = revealTemperatureField(in: app)
        let temperatureLabel = app.staticTexts["Temperature °C"]
        XCTAssertTrue(temperatureLabel.waitForExistence(timeout: uiLoadTimeout))

        let chevron = app.buttons["Adjust location on map"]
        XCTAssertTrue(chevron.exists)
        XCTAssertLessThanOrEqual(
            chevron.frame.minX - location.frame.maxX,
            24,
            "The location field should extend snugly to the disclosure chevron."
        )
    }

    @MainActor
    func testDetailClearButtonsOnlyAppearForFocusedFields() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-open-detail")
        app.launch()

        let blogText = app.textViews["BlogItem blog text"]
        let location = app.textFields["BlogItem location"]
        let clearPost = app.buttons["Clear post"]
        let clearLocation = app.buttons["Clear location"]
        XCTAssertTrue(blogText.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(location.exists)
        XCTAssertFalse(clearPost.isHittable)
        XCTAssertFalse(clearLocation.isHittable)

        blogText.tap()
        XCTAssertTrue(waitForPredicate(NSPredicate(format: "isHittable == true"), on: clearPost))
        XCTAssertFalse(clearLocation.isHittable)

        location.tap()
        XCTAssertFalse(clearPost.isHittable)
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isHittable == true"), on: clearLocation)
        )
    }

    @MainActor
    func testTurningOnElevationForAnExistingPostRendersItInTheJournal() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-elevation")
        app.launchArguments.append("-ui-testing-open-detail")
        app.launch()

        let altitudeField = app.textFields["BlogItem altitude"]
        for _ in 0..<3 where !altitudeField.exists {
            app.swipeUp()
        }
        XCTAssertTrue(altitudeField.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(altitudeField.value as? String, "1200")
        app.swipeUp()

        let elevationSwitch = app.switches["BlogItem show elevation"]
        XCTAssertTrue(elevationSwitch.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "isHittable == true"), on: elevationSwitch)
        )

        // The row-level switch element does not toggle when tapped over its label;
        // aim at the trailing switch control and retry in case a tap lands mid-scroll.
        let switchControl = elevationSwitch
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: elevationSwitch.frame.width - 40, dy: elevationSwitch.frame.height / 2))
        for _ in 0..<2 where (elevationSwitch.value as? String) != "1" {
            switchControl.tap()
            _ = waitForPredicate(NSPredicate(format: "value == '1'"), on: elevationSwitch)
        }
        XCTAssertEqual(elevationSwitch.value as? String, "1")
        app.buttons["Save"].tap()
        let elevationMetadata = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == 'Journal blog item metadata pill' AND label CONTAINS '1,200m'"
            )
        ).firstMatch
        XCTAssertTrue(
            elevationMetadata.waitForExistence(timeout: uiLoadTimeout),
            "Expected elevation in the journal metadata"
        )
    }

    @MainActor
    func testLinkedPostsExposeMetadataAndOpenSupportedLinks() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "External browser handoff is covered by the iPhone UI flow; iPad uses a different browser presentation."
        )
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-linked-posts")
        app.launch()
        openSeededTripJournal(in: app)

        let card = journalCard(containing: "Journal link test", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        let metadata = descendant(withAccessibilityIdentifier: "Journal blog item metadata pill", in: card)
        XCTAssertTrue(metadata.exists)
        XCTAssertTrue(metadata.label.contains("Rog"))
        XCTAssertTrue(card.label.contains("Journal link test"))

        let link = app.links["https://example.com/journal"]
        XCTAssertTrue(link.waitForExistence(timeout: uiLoadTimeout))
        link.tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "state == %d", XCUIApplication.State.runningBackground.rawValue), on: app),
            "Expected tapping an HTTPS link to hand off to the browser."
        )
    }

    @MainActor
    func testMultiPhotoImportCompletesWithOrderedDrafts() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-multi-photo-import")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        let firstDraft = app.descendants(matching: .any).matching(identifier: "Imported photo 1").firstMatch
        XCTAssertTrue(firstDraft.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Imported photo 2").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Imported photo 3").firstMatch.exists)
        XCTAssertEqual(app.textFields.matching(identifier: "Photo caption").count, 3)
    }

    @MainActor
    func testPhotoFilmstripReordersIndividualPhotos() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-multi-photo-import")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        let secondPhoto = app.descendants(matching: .any).matching(identifier: "Imported photo 2").firstMatch
        let thirdPhoto = app.descendants(matching: .any).matching(identifier: "Imported photo 3").firstMatch
        XCTAssertTrue(secondPhoto.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(thirdPhoto.exists)
        XCTAssertTrue(secondPhoto.isHittable)
        XCTAssertTrue(thirdPhoto.isHittable, "The third photo should be visible before it is dragged.")
        XCTAssertEqual(secondPhoto.value as? String, "ui-test-photo-2")
        XCTAssertEqual(thirdPhoto.value as? String, "ui-test-photo-3")
        // Drag from the photo surface itself, not the caption TextField below it.
        secondPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(
                forDuration: 0.8,
                thenDragTo: thirdPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            )
        XCTAssertTrue(waitForPredicate(
            NSPredicate(format: "value == %@", "ui-test-photo-3"),
            on: secondPhoto
        ))
        XCTAssertTrue(waitForPredicate(
            NSPredicate(format: "value == %@", "ui-test-photo-2"),
            on: thirdPhoto
        ))
    }

    @MainActor
    func testPhotoCaptionIgnoresReturn() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        dismissComposeSetupPrompts()

        let caption = app.textFields["Photo caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: uiLoadTimeout))
        caption.tap()
        caption.typeText("First")
        caption.typeText("\n")

        XCTAssertTrue(waitForPredicate(NSPredicate(format: "value == %@", "First"), on: caption))
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "hasKeyboardFocus == false"), on: caption),
            "Expected Return to end caption editing."
        )
    }

    @MainActor
    func testTemperatureIsRoundedWhenEditingEnds() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        let temperature = revealTemperatureField(in: app)
        temperature.tap()
        temperature.typeText("12.26")

        commitTemperatureEditExpecting("12.5", temperature: temperature, in: app)
    }

    @MainActor
    func testTemperatureIsConstrainedWhenEditingEnds() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        let temperature = revealTemperatureField(in: app)
        temperature.tap()
        temperature.typeText("100")

        commitTemperatureEditExpecting("60", temperature: temperature, in: app)
    }

    @MainActor
    func testEditingSurvivesBackgrounding() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-open-detail")
        app.launch()

        let blogText = app.textViews["BlogItem blog text"]
        XCTAssertTrue(blogText.waitForExistence(timeout: uiLoadTimeout))
        let originalText = blogText.value as? String ?? ""
        blogText.tap()
        blogText.typeText(" Preserved after backgrounding.")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "state == %d", XCUIApplication.State.runningBackground.rawValue),
                on: app
            )
        )
        app.activate()
        XCTAssertTrue(blogText.waitForExistence(timeout: uiLoadTimeout))

        let restoredText = blogText.value as? String ?? ""
        XCTAssertTrue(
            restoredText.contains(originalText),
            "Expected the original entry text to survive backgrounding."
        )
        XCTAssertTrue(
            restoredText.contains(" Preserved after backgrounding."),
            "Expected in-progress edits to survive backgrounding, got: \(restoredText)"
        )
    }

    @MainActor
    func testEditingSurvivesTerminationAndRelaunch() throws {
        let draftDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstaBlogDraftStoreUITests", isDirectory: true)

        let app = makeApp()
        app.launchEnvironment["UI_TEST_DRAFT_DIRECTORY"] = draftDirectory.path
        app.launchArguments.append("-ui-testing-reset-drafts")
        app.launchArguments.append("-ui-testing-open-detail")
        app.launch()

        let blogText = app.textViews["BlogItem blog text"]
        XCTAssertTrue(blogText.waitForExistence(timeout: uiLoadTimeout))
        let originalText = blogText.value as? String ?? ""
        blogText.tap()
        blogText.typeText(" Restored after relaunch.")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "state == %d", XCUIApplication.State.runningBackground.rawValue),
                on: app
            )
        )
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate { _, _ in
                    let urls = (try? FileManager.default.contentsOfDirectory(
                        at: draftDirectory,
                        includingPropertiesForKeys: nil
                    )) ?? []
                    return urls.contains { $0.pathExtension == "json" }
                },
                on: app
            ),
            "Expected the editor to persist its draft when backgrounded."
        )

        app.launchArguments.removeAll { $0 == "-ui-testing-reset-drafts" }
        app.terminate()
        app.launch()

        XCTAssertTrue(blogText.waitForExistence(timeout: uiLoadTimeout))
        let restoredText = blogText.value as? String ?? ""
        XCTAssertTrue(
            restoredText.contains(originalText),
            "Expected the original entry text to survive termination and relaunch."
        )
        XCTAssertTrue(
            restoredText.contains(" Restored after relaunch."),
            "Expected in-progress edits to be restored after termination and relaunch, got: \(restoredText)"
        )
    }

    @MainActor
    func testNewPostEditorUsesDebugRedTint() throws {
        let originalAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = originalAppearance }
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        dismissComposeSetupPrompts()

        let editorCancel = app.buttons["Cancel"]
        XCTAssertTrue(editorCancel.waitForExistence(timeout: uiLoadTimeout))
        assertDebugRedTint(in: editorCancel, app: app)

        let save = app.buttons["Save"]
        XCTAssertTrue(save.exists)
        XCTAssertTrue(save.isEnabled)
        assertDebugRedTint(in: save, app: app)

        let addPhoto = app.buttons["Add Another Photo"]
        XCTAssertTrue(addPhoto.waitForExistence(timeout: uiLoadTimeout))
        assertDebugRedTint(in: addPhoto, app: app)

        let filmstripAddPhoto = app.buttons["Add photo filmstrip tile"]
        XCTAssertTrue(filmstripAddPhoto.exists)
    }

    @MainActor
    func testSavingPhotoPostShowsItAtTopOfJournal() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

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
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "Journal blog item card")
                .matching(NSPredicate(format: "label CONTAINS %@", caption))
                .count,
            1,
            "Expected one visible journal result for the saved photo post."
        )
    }

    @MainActor
    func testSavingEntryRefreshesJournalToOneNewCard() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        let text = "Refresh exactly once"
        let editor = app.textViews["BlogItem blog text"]
        XCTAssertTrue(editor.waitForExistence(timeout: uiLoadTimeout))
        editor.tap()
        editor.typeText(text)
        app.buttons["Save"].tap()

        let refreshedCard = journalCard(containing: text, in: app)
        XCTAssertTrue(refreshedCard.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "Journal blog item card")
                .matching(NSPredicate(format: "label CONTAINS %@", text))
                .count,
            1,
            "Expected one visible result for the saved entry."
        )
    }

    @MainActor
    func testEditingPostShowsLastEditorBelowAuthor() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-open-detail")
        app.launch()

        let blogText = app.textViews["BlogItem blog text"]
        XCTAssertTrue(blogText.waitForExistence(timeout: uiLoadTimeout))
        blogText.tap()
        blogText.typeText(" Edited by Rog.")
        app.buttons["Save"].tap()

        let editedPost = journalCard(containing: "Edited by Rog", in: app)
        XCTAssertTrue(editedPost.waitForExistence(timeout: uiLoadTimeout))
        tapScreenPoint(editedPost.frame.center, in: app)

        let author = app.staticTexts["Author"]
        let editor = app.staticTexts["Last Edit"]
        for _ in 0..<3 where !editor.exists {
            app.swipeUp()
        }
        XCTAssertTrue(author.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertTrue(editor.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertGreaterThan(editor.frame.minY, author.frame.minY)
        XCTAssertEqual(app.staticTexts["BlogItem last editor"].label, "Rog")
        XCTAssertTrue(app.staticTexts["BlogItem last edit date"].label.hasPrefix("Edited "))
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

        XCTAssertGreaterThanOrEqual(metadataPill.frame.minY, photo.frame.maxY)
        XCTAssertTrue(photo.frame.contains(uploadStatusPill.frame))
        XCTAssertGreaterThanOrEqual(text.frame.minY, photo.frame.maxY)
        XCTAssertGreaterThanOrEqual(location.frame.minY, text.frame.maxY)
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

        XCTAssertTrue(card.isHittable)
        let firstPhoto = descendant(withAccessibilityIdentifier: "Journal blog item photo", in: card)
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: uiLoadTimeout))
        firstPhoto.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            let inlineEditor = app.textViews["Journal blog item text editor"]
            if inlineEditor.waitForExistence(timeout: 3) {
                XCTAssertEqual(inlineEditor.value as? String, captionText)
                app.buttons["Commit edits"].tap()
            } else {
                let detailCaption = app.textViews["BlogItem blog text"]
                XCTAssertTrue(detailCaption.waitForExistence(timeout: uiLoadTimeout))
                XCTAssertEqual(detailCaption.value as? String, captionText)
                app.buttons["Cancel"].tap()
            }
        } else {
            let firstDetailCaption = app.textViews["BlogItem blog text"]
            XCTAssertTrue(firstDetailCaption.waitForExistence(timeout: uiLoadTimeout))
            XCTAssertEqual(firstDetailCaption.value as? String, captionText)
            app.buttons["Cancel"].tap()
        }

        card = journalCard(containing: captionText, in: app)
        let text = descendant(withAccessibilityIdentifier: "Journal blog item text", in: card)
        tapScreenPoint(text.frame.center, in: app)
        if UIDevice.current.userInterfaceIdiom == .pad {
            let inlineEditor = app.textViews["Journal blog item text editor"]
            XCTAssertTrue(inlineEditor.waitForExistence(timeout: uiLoadTimeout))
            XCTAssertTrue(inlineEditor.value as? String == captionText)
            app.buttons["Commit edits"].tap()
        } else {
            assertDetailShows(caption: captionText, in: app)
            app.buttons["Cancel"].tap()
        }

        card = journalCard(containing: captionText, in: app)
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

        let addButtonControl = app.buttons
            .matching(NSPredicate(format: "label == %@", "Add blog item"))
            .allElementsBoundByIndex
            .min { lhs, rhs in
                abs(lhs.frame.midY - location.frame.midY) < abs(rhs.frame.midY - location.frame.midY)
            } ?? app.buttons["Add blog item"].firstMatch
        XCTAssertTrue(addButtonControl.exists)
        addButtonControl.tap()

        let caption = app.textViews["BlogItem blog text"]
        XCTAssertTrue(caption.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertEqual(caption.value as? String, "")
        XCTAssertTrue(app.buttons["Add Photo"].exists)

        let locationField = app.textFields["BlogItem location"]
        let temperatureField = app.textFields["BlogItem temperature"]
        XCTAssertTrue(locationField.exists)
        XCTAssertTrue(temperatureField.exists)
        XCTAssertEqual(locationField.value as? String, locationField.placeholderValue)
        XCTAssertEqual(temperatureField.value as? String, "\u{2014}")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "BlogItem date")
                .firstMatch.exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "BlogItem time")
                .firstMatch.exists
        )
        XCTAssertTrue(app.buttons["BlogItem weather condition"].exists)
        XCTAssertEqual(app.buttons["BlogItem weather condition"].label, "Unknown")
        XCTAssertTrue(app.staticTexts["BlogItem created date"].exists)
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
    private func revealTemperatureField(in app: XCUIApplication) -> XCUIElement {
        let temperature = app.textFields["BlogItem temperature"]
        for _ in 0..<3 where !temperature.exists {
            app.swipeUp()
        }
        XCTAssertTrue(temperature.waitForExistence(timeout: uiLoadTimeout))
        return temperature
    }

    /// Ends temperature editing by moving focus to the location field and waits for
    /// the committed value. The keyboard's appearance shifts the form while the first
    /// tap is in flight, so the tap may miss — retry until the value normalizes.
    @MainActor
    private func commitTemperatureEditExpecting(
        _ expected: String,
        temperature: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let location = app.textFields["BlogItem location"]
        for _ in 0..<3 {
            location.tap()
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expected),
                object: temperature
            )
            if XCTWaiter.wait(for: [expectation], timeout: 3) == .completed {
                return
            }
        }
        XCTAssertEqual(
            temperature.value as? String,
            expected,
            "Expected the temperature to normalize to \(expected) when editing ends.",
            file: file,
            line: line
        )
    }

    @MainActor
    private func dismissComposeSetupPrompts() {
        // Fresh simulators can obscure the editor with first-run system prompts.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyLocation = springboard.buttons["Don’t Allow"]
        if denyLocation.waitForExistence(timeout: 3) {
            denyLocation.tap()
        }
        let notNow = springboard.alerts["Enable Dictation?"].buttons["Not Now"]
        if notNow.waitForExistence(timeout: 2) {
            notNow.tap()
        }
    }

    @MainActor
    private func assertDebugRedTint(
        in element: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(5)
        var bestCount = 0
        repeat {
            bestCount = max(bestCount, sampleRedPixelCount(in: element, app: app))
            if bestCount > 3 || Date() >= deadline {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while bestCount <= 3

        XCTAssertGreaterThan(
            bestCount,
            3,
            "Expected the control to render with the Debug build's red tint.",
            file: file,
            line: line
        )
    }

    private func sampleRedPixelCount(in element: XCUIElement, app: XCUIApplication) -> Int {
        let screenshot = app.screenshot()
        guard let image = UIImage(data: screenshot.pngRepresentation),
              let cgImage = image.cgImage else {
            return 0
        }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let xScale = CGFloat(width) / app.frame.width
        let yScale = CGFloat(height) / app.frame.height
        let frame = element.frame.insetBy(dx: -3, dy: -3)
        let pixelFrame = CGRect(
            x: frame.minX * xScale,
            y: frame.minY * yScale,
            width: frame.width * xScale,
            height: frame.height * yScale
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))

        let flippedPixelFrame = CGRect(
            x: pixelFrame.minX,
            y: CGFloat(height) - pixelFrame.maxY,
            width: pixelFrame.width,
            height: pixelFrame.height
        )
        return [pixelFrame, flippedPixelFrame]
            .map { bitmapFrame in
                (Int(bitmapFrame.minY)..<Int(bitmapFrame.maxY))
                    .reduce(into: 0) { count, y in
                        for x in Int(bitmapFrame.minX)..<Int(bitmapFrame.maxX) {
                            let offset = ((y * width) + x) * 4
                            let red = pixels[offset]
                            let green = pixels[offset + 1]
                            let blue = pixels[offset + 2]
                            if red >= 180, Double(red) > Double(green) * 1.35, Double(red) > Double(blue) * 1.35 {
                                count += 1
                            }
                        }
                    }
            }
            .max() ?? 0
    }

    @MainActor
    func testInlineEditingEmptyTextSilentlyDeletesPhotoLessEntry() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Inline text editing is iPad-only."
        )

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()
        assertIPadNavigationShell(in: app)

        let card = journalCard(containing: "Flamingos gathering in the late light.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        beginInlineEditingAndClearText(in: card, app: app)

        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "exists == false"), on: card),
            "Expected the emptied photo-less entry to be silently removed on focus loss."
        )
        XCTAssertFalse(
            app.alerts.firstMatch.exists,
            "Expected no confirmation dialog before removing the emptied photo-less entry."
        )
    }

    @MainActor
    func testInlineEditingEmptyTextKeepsPhotoEntry() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Inline text editing is iPad-only."
        )

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()
        assertIPadNavigationShell(in: app)

        let card = journalCard(containing: "Salt flats stretching to the horizon.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        XCTAssertFalse(
            descendant(
                withAccessibilityIdentifier: "Journal blog item detail disclosure",
                in: card
            ).exists,
            "Expected no disclosure button on a photo entry."
        )

        beginInlineEditingAndClearText(in: card, app: app)

        XCTAssertFalse(
            app.alerts.firstMatch.exists,
            "Expected no confirmation dialog when emptying a photo entry's text."
        )
        let remainingCard = app.descendants(matching: .any)
            .matching(identifier: "Journal blog item card")
            .matching(NSPredicate(format: "label CONTAINS %@", "Camargue"))
            .firstMatch
        XCTAssertTrue(
            remainingCard.waitForExistence(timeout: uiLoadTimeout),
            "Expected the photo entry to remain in the journal after emptying its text."
        )
    }

    @MainActor
    func testInlineEditingTextOnlyEntryHasDetailDisclosure() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Inline text editing is iPad-only."
        )

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()
        assertIPadNavigationShell(in: app)

        let card = journalCard(containing: "Flamingos gathering in the late light.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        let disclosure = descendant(
            withAccessibilityIdentifier: "Journal blog item detail disclosure",
            in: app
        )
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: uiLoadTimeout),
            "Expected a disclosure button on the text-only entry."
        )
        disclosure.tap()

        let detailLocation = app.descendants(matching: .any)
            .matching(identifier: "BlogItem location")
            .firstMatch
        XCTAssertTrue(
            detailLocation.waitForExistence(timeout: uiLoadTimeout),
            "Expected the detail view to open after tapping the disclosure chevron."
        )
    }

    @MainActor
    func testInlineEditingDetailDisclosureIsPhoneOnly() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "This test verifies iPhone behavior without inline editing."
        )

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()

        openSeededTripJournal(in: app)

        let card = journalCard(containing: "Flamingos gathering in the late light.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        XCTAssertFalse(
            descendant(
                withAccessibilityIdentifier: "Journal blog item detail disclosure",
                in: app
            ).exists,
            "Expected no disclosure chevron on iPhone, where the whole card navigates."
        )
    }

    @MainActor
    func testInlineEditingReturnInsertsNewlineWithoutReleasingFocus() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Inline text editing is iPad-only."
        )

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()
        assertIPadNavigationShell(in: app)

        let card = journalCard(containing: "Flamingos gathering in the late light.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        let text = descendant(withAccessibilityIdentifier: "Journal blog item text", in: card)
        XCTAssertTrue(text.waitForExistence(timeout: uiLoadTimeout))
        text.tap()

        let editor = app.textViews["Journal blog item text editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: uiLoadTimeout))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiLoadTimeout))

        editor.typeText("\n")

        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "value CONTAINS %@", "\n"),
                on: editor
            ),
            "Expected Return to insert a newline into the entry."
        )
        XCTAssertTrue(
            editor.exists,
            "Expected Return to keep the editor focused instead of committing."
        )
    }

    @MainActor
    func testInlineEditingCommitSurvivesBackgroundingAndRelaunch() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Inline text editing is iPad-only."
        )

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()
        assertIPadNavigationShell(in: app)

        let card = journalCard(containing: "Flamingos gathering in the late light.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))

        let text = descendant(withAccessibilityIdentifier: "Journal blog item text", in: card)
        XCTAssertTrue(text.waitForExistence(timeout: uiLoadTimeout))
        text.tap()

        let editor = app.textViews["Journal blog item text editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: uiLoadTimeout))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiLoadTimeout))
        editor.typeText(" committed on background.")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "state == %d", XCUIApplication.State.runningBackground.rawValue),
                on: app
            )
        )
        app.activate()

        let committedCard = journalCard(containing: "committed on background.", in: app)
        XCTAssertTrue(
            committedCard.waitForExistence(timeout: uiLoadTimeout),
            "Expected the in-progress inline edit to be committed when the app left the foreground."
        )
        XCTAssertFalse(
            editor.exists,
            "Expected the inline editor to be dismissed after committing on background."
        )
    }

    @MainActor
    private func assertIPadNavigationShell(in app: XCUIApplication) {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            app.buttons["Show menu"].waitForExistence(timeout: uiLoadTimeout),
            "Expected the iPad navigation menu in landscape rather than the iPhone tab bar."
        )
        XCTAssertFalse(
            app.tabBars.firstMatch.exists,
            "The iPhone tab bar must not be shown in the iPad inline-editing flow."
        )

        // Device orientation is global simulator state: restore portrait so later
        // tests (and the next run) do not inherit landscape.
        XCUIDevice.shared.orientation = .portrait
        let portraitDeadline = Date().addingTimeInterval(uiLoadTimeout)
        while app.frame.height <= app.frame.width, Date() < portraitDeadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertGreaterThan(
            app.frame.height,
            app.frame.width,
            "Expected the app to return to portrait after restoring orientation."
        )
    }

    @MainActor
    private func beginInlineEditingAndClearText(in card: XCUIElement, app: XCUIApplication) {
        let text = descendant(withAccessibilityIdentifier: "Journal blog item text", in: card)
        XCTAssertTrue(text.waitForExistence(timeout: uiLoadTimeout))
        text.tap()

        let editor = app.textViews["Journal blog item text editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: uiLoadTimeout))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiLoadTimeout))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "value == %@", ""),
                on: editor
            ),
            "Expected the entry text to be cleared before committing."
        )
        releaseEditorFocus(in: app)
    }

    @MainActor
    private func releaseEditorFocus(in app: XCUIApplication) {
        let commitEdits = app.buttons["Commit edits"]
        XCTAssertTrue(commitEdits.waitForExistence(timeout: uiLoadTimeout))
        commitEdits.tap()
        XCTAssertTrue(
            waitForPredicate(
                NSPredicate(format: "exists == false"),
                on: app.textViews["Journal blog item text editor"]
            ),
            "Expected the inline edit to commit and release focus."
        )
    }
}
