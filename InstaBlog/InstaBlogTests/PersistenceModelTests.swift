import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Persistence model defaults")
struct PersistenceModelDefaultTests {
    @Test func blogUsesBootstrapDefaults() {
        let blog = Blog(id: TestFixtures.blogID, createdAt: TestFixtures.now, updatedAt: TestFixtures.now)

        #expect(blog.title == "My Blog")
        #expect(blog.galleryIntervalSeconds == 900)
        #expect(blog.galleryDistanceMeters == 500.0)
    }

    @Test func relatedModelsUseBootstrapDefaults() {
        let blogger = Blogger(
            id: TestFixtures.bloggerID,
            blogID: TestFixtures.blogID,
            createdAt: TestFixtures.now,
            updatedAt: TestFixtures.now,
            cloudKitParticipantIdentifier: nil
        )
        let mailingList = MailingList(
            id: TestFixtures.mailingListID,
            blogID: TestFixtures.blogID,
            createdAt: TestFixtures.now,
            updatedAt: TestFixtures.now
        )

        #expect(blogger.displayName == "Me")
        #expect(mailingList.name == "Subscribers")
        #expect(BootstrapDefaults.blogTitle == "My Blog")
        #expect(BootstrapDefaults.bloggerDisplayName == "Me")
        #expect(BootstrapDefaults.mailingListName == "Subscribers")
        #expect(BootstrapDefaults.galleryIntervalSeconds == 900)
        #expect(BootstrapDefaults.galleryDistanceMeters == 500.0)
    }

    @Test func blogDerivesSyncMetadataIdentifier() {
        let blog = Blog(id: TestFixtures.blogID, createdAt: TestFixtures.now, updatedAt: TestFixtures.now)

        #expect(blog.syncMetadataID.recordPrimaryKey == blog.id.uuidString)
        #expect(blog.syncMetadataID.recordType == Blog.tableName)
    }
}

@Suite("Blog item validation")
struct BlogItemValidationTests {
    @Test(arguments: [nil, "", " \n\t "] as [String?])
    func rejectsMissingCaptionAndPhoto(_ caption: String?) {
        let item = TestFixtures.blogItem(caption: caption, photoAssetID: nil)

        #expect(throws: ModelValidationError.missingBlogItemContent) {
            try item.validate(relativeTo: TestFixtures.now)
        }
    }

    @Test func acceptsCaptionWithoutPhoto() throws {
        let item = TestFixtures.blogItem(caption: "A day in London", photoAssetID: nil)

        try item.validate(relativeTo: TestFixtures.now)
    }

    @Test func acceptsPhotoWithoutCaption() throws {
        let item = TestFixtures.blogItem(caption: nil, photoAssetID: TestFixtures.mediaAssetID)

        try item.validate(relativeTo: TestFixtures.now)
    }

    @Test func acceptsCaptionAndPhoto() throws {
        let item = TestFixtures.blogItem(
            caption: "A day in London",
            photoAssetID: TestFixtures.mediaAssetID
        )

        try item.validate(relativeTo: TestFixtures.now)
    }

    @Test(arguments: [TestFixtures.now.addingTimeInterval(-1), TestFixtures.now])
    func acceptsCurrentOrPastItemDate(_ itemDate: Date) throws {
        let item = TestFixtures.blogItem(caption: "Published", itemDate: itemDate)

        try item.validate(relativeTo: TestFixtures.now)
    }

    @Test func rejectsFutureItemDate() {
        let item = TestFixtures.blogItem(
            caption: "From the future",
            itemDate: TestFixtures.now.addingTimeInterval(1)
        )

        #expect(throws: ModelValidationError.futureBlogItemDate) {
            try item.validate(relativeTo: TestFixtures.now)
        }
    }
}

@Suite("Media asset validation")
struct MediaAssetValidationTests {
    @Test func usesPhotoKindByDefault() {
        let asset = MediaAsset(
            id: TestFixtures.mediaAssetID,
            blogID: TestFixtures.blogID,
            localOriginalPath: "Media/original.jpg",
            cloudAssetIdentifier: "cloud-asset-1",
            filename: "original.jpg",
            mimeType: "image/jpeg",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            createdAt: TestFixtures.now,
            updatedAt: TestFixtures.now
        )

        #expect(asset.kind == "photo")
    }

    @Test func acceptsPhoto() throws {
        let asset = TestFixtures.mediaAsset(kind: "photo")

        try asset.validate()
    }

    @Test func rejectsVideo() {
        let asset = TestFixtures.mediaAsset(kind: "video")

        #expect(throws: ModelValidationError.unsupportedMediaKind("video")) {
            try asset.validate()
        }
    }
}

private enum TestFixtures {
    static let blogID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1))
    static let bloggerID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2))
    static let mediaAssetID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 3))
    static let mailingListID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 4))
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func blogItem(
        caption: String?,
        photoAssetID: UUID? = nil,
        itemDate: Date = now
    ) -> BlogItem {
        BlogItem(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 5)),
            blogID: blogID,
            authorID: bloggerID,
            caption: caption,
            createdAt: now,
            updatedAt: now,
            itemDate: itemDate,
            itemTimeZoneIdentifier: "Europe/London",
            localDay: "2027-01-15",
            latitude: 51.5074,
            longitude: -0.1278,
            locationName: "London",
            countryCode: "GB",
            weatherTemperatureCelsius: 12.5,
            weatherConditionCode: "cloudy",
            photoAssetID: photoAssetID,
            deletedAt: nil
        )
    }

    static func mediaAsset(kind: String) -> MediaAsset {
        MediaAsset(
            id: mediaAssetID,
            blogID: blogID,
            kind: kind,
            localOriginalPath: "Media/original.jpg",
            cloudAssetIdentifier: "cloud-asset-1",
            filename: "original.jpg",
            mimeType: "image/jpeg",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            createdAt: now,
            updatedAt: now
        )
    }
}
