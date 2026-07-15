import Foundation
import Testing
@testable import InstaBlog

@Suite("Persistence model defaults")
struct PersistenceModelTests {
    @Test func bootstrapDefaultsRemainMinimal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let blog = Blog(id: UUID(), createdAt: now, updatedAt: now)
        let blogger = Blogger(id: UUID(), blogID: blog.id, createdAt: now, updatedAt: now)

        #expect(blog.title == "My Blog")
        #expect(blogger.displayName == "Me")
        #expect(BootstrapDefaults.mailingListName == "Subscribers")
    }

    @Test func photoItemKeepsItsOwnCaptionAndDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let photo = PhotoItem(
            id: UUID(),
            blogID: UUID(),
            blogItemID: UUID(),
            mediaAssetID: UUID(),
            photoCaption: "Harbour",
            photoDate: date,
            createdAt: date,
            updatedAt: date
        )

        #expect(photo.photoCaption == "Harbour")
        #expect(photo.photoDate == date)
    }
}

@Suite("Blog item validation")
struct BlogItemValidationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [nil, "", " \n\t "] as [String?])
    func rejectsMissingTextAndPhotos(_ blogText: String?) {
        let item = makeItem(blogText: blogText)
        #expect(throws: ModelValidationError.missingBlogItemContent) {
            try item.validate(relativeTo: now, hasPhotos: false)
        }
    }

    @Test func acceptsTextOnlyPost() throws {
        try makeItem(blogText: "A day in London")
            .validate(relativeTo: now, hasPhotos: false)
    }

    @Test func acceptsPhotoOnlyPost() throws {
        try makeItem(blogText: nil)
            .validate(relativeTo: now, hasPhotos: true)
    }

    @Test func rejectsFutureItemDate() {
        let item = makeItem(blogText: "Tomorrow", itemDate: now.addingTimeInterval(1))
        #expect(throws: ModelValidationError.futureBlogItemDate) {
            try item.validate(relativeTo: now, hasPhotos: false)
        }
    }

    private func makeItem(blogText: String?, itemDate: Date? = nil) -> BlogItem {
        BlogItem(
            id: UUID(),
            blogID: UUID(),
            authorID: UUID(),
            blogText: blogText,
            createdAt: now,
            updatedAt: now,
            itemDate: itemDate ?? now,
            localDay: "2027-01-15"
        )
    }
}

@Suite("Media asset validation")
struct MediaAssetValidationTests {
    @Test func acceptsPhotoAndRejectsVideo() throws {
        let photo = makeAsset(kind: "photo")
        try photo.validate()

        let video = makeAsset(kind: "video")
        #expect(throws: ModelValidationError.unsupportedMediaKind("video")) {
            try video.validate()
        }
    }

    private func makeAsset(kind: String) -> MediaAsset {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return MediaAsset(
            id: UUID(),
            blogID: UUID(),
            kind: kind,
            filename: "asset.jpg",
            mimeType: "image/jpeg",
            createdAt: now,
            updatedAt: now
        )
    }
}
