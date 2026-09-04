import CoreGraphics
import Foundation
import Testing
@testable import InstaBlog

struct FilmstripPhotoLayoutTests {
    @Test func usesPersistedPixelDimensionsWithoutReadingTheImageFile() {
        let photo = PhotoItemDisplay(
            date: .now,
            localImagePath: "/missing/image.jpg",
            pixelWidth: 4_000,
            pixelHeight: 3_000
        )

        #expect(abs(FilmstripPhotoLayout(photo: photo).sourceAspectRatio - (4.0 / 3.0)) < 0.0001)
    }

    @Test func preservesStandardAndIntermediateCameraAspectRatios() {
        #expect(
            FilmstripPhotoLayout(sourceAspectRatio: 3 / 4).clampedAspectRatio
                == FilmstripPhotoLayout.portraitAspectRatio
        )
        #expect(FilmstripPhotoLayout(sourceAspectRatio: 1).clampedAspectRatio == 1)
        #expect(
            FilmstripPhotoLayout(sourceAspectRatio: 4 / 3).clampedAspectRatio
                == FilmstripPhotoLayout.landscapeAspectRatio
        )
    }

    @Test func clampsPanoramasAndTallScreenshotsToCameraAspectRatios() {
        #expect(
            FilmstripPhotoLayout(sourceAspectRatio: 3).clampedAspectRatio
                == FilmstripPhotoLayout.landscapeAspectRatio
        )
        #expect(
            FilmstripPhotoLayout(sourceAspectRatio: 1 / 3).clampedAspectRatio
                == FilmstripPhotoLayout.portraitAspectRatio
        )
    }

    @Test func matchesExistingLandscapeHeightUntilItReachesTheMaximum() {
        #expect(
            FilmstripPhotoLayout.stripHeight(
                availableWidth: 362,
                maximumHeight: 260,
                trailingPeekWidth: 50
            ) == 234
        )
        #expect(
            FilmstripPhotoLayout.stripHeight(
                availableWidth: 600,
                maximumHeight: 260,
                trailingPeekWidth: 50
            ) == 260
        )
    }

    @Test func portraitLedGalleryFillsTheCardBeforeTheNextPhotoPeek() {
        let height = FilmstripPhotoLayout.stripHeight(
            availableWidth: 744,
            maximumHeight: 520,
            trailingPeekWidth: 50,
            leadingAspectRatio: FilmstripPhotoLayout.portraitAspectRatio
        )
        #expect(abs(height - 925.3333333333334) < 0.001)
    }
}
