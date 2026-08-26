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
        XCTAssertEqual(altitudeField.value as? String, "1200.0")
        app.swipeUp()

        let elevationSwitch = app.switches["BlogItem show elevation"]
        XCTAssertTrue(elevationSwitch.exists)

        elevationSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
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
    func testPhotoCaptionIgnoresReturn() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

        let caption = app.textFields["Photo caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: uiLoadTimeout))
        caption.tap()
        caption.typeText("First")
        caption.typeText("\n")

        XCTAssertEqual(caption.value as? String, "First")
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

        app.textFields["BlogItem location"].tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "value == %@", "12.5"), on: temperature)
        )
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

        app.textFields["BlogItem location"].tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "value == %@", "60"), on: temperature)
        )
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
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launchArguments.append("-ui-testing-open-compose")
        app.launch()

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

        XCTAssertEqual(photo.frame.minX, card.frame.minX, accuracy: 2)
        XCTAssertEqual(photo.frame.maxX, card.frame.maxX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(metadataPill.frame.minY, photo.frame.maxY)
        XCTAssertTrue(photo.frame.contains(uploadStatusPill.frame))
        XCTAssertGreaterThanOrEqual(text.frame.minY, photo.frame.maxY)
        XCTAssertGreaterThanOrEqual(location.frame.minY, text.frame.maxY)
        XCTAssertEqual(text.frame.minX, photo.frame.minX, accuracy: 2)
        XCTAssertEqual(location.frame.minX, photo.frame.minX, accuracy: 2)
        let buttonSize: CGFloat = 44
        let graphicSize: CGFloat = 22
        let graphicTrailingInset = (buttonSize - graphicSize) / 2

        XCTAssertEqual(addButton.frame.width, buttonSize, accuracy: 1)
        XCTAssertEqual(addButton.frame.height, buttonSize, accuracy: 1)
        XCTAssertEqual(addButton.frame.midY, metadataPill.frame.midY, accuracy: 2)
        XCTAssertEqual(
            addButton.frame.maxX - graphicTrailingInset,
            photo.frame.maxX,
            accuracy: 2
        )
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

    @MainActor
    private func assertDebugRedTint(
        in element: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(2)
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
                            if red >= 200, green <= 90, blue <= 100 {
                                count += 1
                            }
                        }
                    }
            }
            .max() ?? 0
    }

    @MainActor
    func testInlineEditingEmptyTextSilentlyDeletesPhotoLessEntry() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Inline text editing is iPad-only")
        }

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()

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
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Inline text editing is iPad-only")
        }

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()

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
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Inline text editing is iPad-only")
        }

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()

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
    func testInlineEditingDetailDisclosureIsIPadOnly() throws {
        guard UIDevice.current.userInterfaceIdiom != .pad else {
            throw XCTSkip("This test verifies the iPhone behaviour without inline editing")
        }

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
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Inline text editing is iPad-only")
        }

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()

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
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Inline text editing is iPad-only")
        }

        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-inline-editing")
        app.launch()

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
    private func beginInlineEditingAndClearText(in card: XCUIElement, app: XCUIApplication) {
        let text = descendant(withAccessibilityIdentifier: "Journal blog item text", in: card)
        XCTAssertTrue(text.waitForExistence(timeout: uiLoadTimeout))
        text.tap()

        let editor = app.textViews["Journal blog item text editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: uiLoadTimeout))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: uiLoadTimeout))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        for _ in 0..<40 {
            app.keys["delete"].tap()
        }
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
        let journalTab = app.buttons["Journal"]
        XCTAssertTrue(journalTab.waitForExistence(timeout: uiLoadTimeout))
        journalTab.tap()
    }
}
