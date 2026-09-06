import XCTest
import UIKit

final class InstaBlogPhotoStatusUITests: InstaBlogUITestCase {
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
    func testGalleryJournalScrollKeepsPhotoFilmstripVisible() throws {
        let app = makeApp()
        app.launchArguments.append("-ui-testing-seed-gallery")
        app.launch()
        openSeededTripJournal(in: app)

        let filmstrip = app.descendants(matching: .any)
            .matching(identifier: "Journal blog item photo strip")
            .firstMatch
        for _ in 0..<4 where !filmstrip.exists {
            app.swipeUp()
        }

        XCTAssertTrue(filmstrip.waitForExistence(timeout: uiLoadTimeout))
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any)
                .matching(identifier: "Journal blog item photo")
                .count,
            2
        )
        app.terminate()
    }

    @MainActor
    func testPortraitPhotoLayoutsFitTheViewportAndGalleryScrollsInBothOrientations() throws {
        let originalOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = originalOrientation }

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation

            let app = makeApp()
            app.launchArguments.append("-ui-testing-seed-photo-layout")
            app.launch()
            openSeededTripJournal(in: app)

            let singlePhotoCard = journalCard(containing: "Portrait single photo layout", in: app)
            XCTAssertTrue(singlePhotoCard.waitForExistence(timeout: uiLoadTimeout))
            let singlePhoto = descendant(
                withAccessibilityIdentifier: "Journal blog item photo",
                in: singlePhotoCard
            )
            XCTAssertLessThanOrEqual(
                singlePhoto.frame.height,
                app.frame.height - 30,
                "A single portrait photo should fit within the viewport in \(orientation)."
            )
            XCTAssertEqual(
                singlePhoto.frame.minX,
                singlePhotoCard.frame.minX,
                accuracy: 2,
                "A single portrait photo should be left aligned in \(orientation)."
            )

            let galleryCard = journalCard(containing: "Portrait-led gallery layout", in: app)
            for _ in 0..<4 where !galleryCard.exists {
                app.swipeUp()
            }
            XCTAssertTrue(galleryCard.waitForExistence(timeout: uiLoadTimeout))

            let filmstrip = descendant(
                withAccessibilityIdentifier: "Journal blog item photo strip",
                in: galleryCard
            )
            XCTAssertTrue(filmstrip.exists)
            XCTAssertLessThanOrEqual(filmstrip.frame.height, app.frame.height - 30)
            XCTAssertLessThanOrEqual(
                filmstrip.frame.height,
                (filmstrip.frame.width - 50) / (4.0 / 3.0) + 1,
                "The gallery must leave room for a landscape photo to snap into view."
            )

            filmstrip.swipeLeft()
            XCTAssertTrue(filmstrip.isHittable, "The gallery should remain scrollable after a swipe.")
            app.terminate()
        }
    }

    @MainActor
    private func assertPhotoSyncStatus(
        _ status: SyncStatusFixture,
        accessibilityDescription: String
    ) {
        let app = makeApp()
        app.launchEnvironment["UI_TEST_SYNC_STATUS"] = status.rawValue
        app.launchEnvironment["UI_TEST_PHOTO_AVAILABILITY"] = PhotoAvailabilityFixture.available.rawValue
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
}
