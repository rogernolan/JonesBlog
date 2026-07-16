import XCTest

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
}
