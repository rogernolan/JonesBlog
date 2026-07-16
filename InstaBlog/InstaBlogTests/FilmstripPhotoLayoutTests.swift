import CoreGraphics
import Testing
@testable import InstaBlog

struct FilmstripPhotoLayoutTests {
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

    @Test func cropsOnlyImagesOutsideAcceptedAspectRatios() {
        #expect(FilmstripPhotoLayout(sourceAspectRatio: 1).scaling == .fit)
        #expect(FilmstripPhotoLayout(sourceAspectRatio: 3).scaling == .fill)
        #expect(FilmstripPhotoLayout(sourceAspectRatio: 1 / 3).scaling == .fill)
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
}
