import XCTest
import UIKit

final class InstaBlogJournalEditingUITests: InstaBlogUITestCase {
    @MainActor
    func testDetailClearButtonsOnlyAppearForFocusedFields() throws {
        let app = makeApp()
        app.launch()
        openSeededTripJournal(in: app)

        let card = journalCard(containing: "Flamingos gathering in the late light.", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: uiLoadTimeout))
        tapScreenPoint(card.frame.center, in: app)

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
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

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
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

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
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

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
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

        let temperature = revealTemperatureField(in: app)
        temperature.tap()
        temperature.typeText("100")

        app.textFields["BlogItem location"].tap()
        XCTAssertTrue(
            waitForPredicate(NSPredicate(format: "value == %@", "60"), on: temperature)
        )
    }

    @MainActor
    func testNewPostEditorUsesOrangeTint() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-photo-post-draft")
        app.launch()

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

        let editorCancel = app.buttons["Cancel"]
        XCTAssertTrue(editorCancel.waitForExistence(timeout: uiLoadTimeout))
        assertOrangeTint(in: editorCancel, app: app)

        let save = app.buttons["Save"]
        XCTAssertTrue(save.exists)
        XCTAssertTrue(save.isEnabled)
        assertOrangeTint(in: save, app: app)

        let addPhoto = app.buttons["Add Another Photo"]
        XCTAssertTrue(addPhoto.waitForExistence(timeout: uiLoadTimeout))
        assertOrangeTint(in: addPhoto, app: app)

        let filmstripAddPhoto = app.buttons["Add photo filmstrip tile"]
        XCTAssertTrue(filmstripAddPhoto.exists)
    }

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
        app.launch()
        openSeededTripJournal(in: app)

        let composeButton = app.buttons["New BlogItem"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: uiLoadTimeout))
        composeButton.tap()

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
        app.launch()
        openSeededTripJournal(in: app)

        let post = card(withAccessibilityIdentifier: "Journal blog item card", in: app)
        XCTAssertTrue(post.waitForExistence(timeout: uiLoadTimeout))
        tapScreenPoint(post.frame.center, in: app)

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
        XCTAssertEqual(temperatureField.value as? String, temperatureField.placeholderValue)
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
    private func assertOrangeTint(
        in element: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screenshot = app.screenshot()
        guard let image = UIImage(data: screenshot.pngRepresentation),
              let cgImage = image.cgImage else {
            XCTFail("Expected to decode the app screenshot.", file: file, line: line)
            return
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
            XCTFail("Expected to create a screenshot bitmap context.", file: file, line: line)
            return
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
        let orangePixelCount = [pixelFrame, flippedPixelFrame]
            .map { bitmapFrame in
                (Int(bitmapFrame.minY)..<Int(bitmapFrame.maxY))
                    .reduce(into: 0) { count, y in
                        for x in Int(bitmapFrame.minX)..<Int(bitmapFrame.maxX) {
                            let offset = ((y * width) + x) * 4
                            let red = pixels[offset]
                            let green = pixels[offset + 1]
                            let blue = pixels[offset + 2]
                            if red >= 210, green >= 80, green <= 175, blue <= 90 {
                                count += 1
                            }
                        }
                    }
            }
            .max() ?? 0

        XCTAssertGreaterThan(
            orangePixelCount,
            3,
            "Expected the control to render with the app's orange tint.",
            file: file,
            line: line
        )
    }
}
