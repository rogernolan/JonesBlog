import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Database-backed journal", .serialized)
struct JournalServiceTests {
    @Test func createsOnePostWithMultiplePhotosOrderedByPhotoDate() throws {
        let fixture = try JournalFixture()
        let later = fixture.photoDraft(
            byte: 0x22,
            date: fixture.date("2027-01-15T11:00:00Z"),
            caption: "Later"
        )
        let earlier = fixture.photoDraft(
            byte: 0x11,
            date: fixture.date("2027-01-15T09:00:00Z"),
            caption: "Earlier",
            timeZoneIdentifier: "Europe/Paris",
            latitude: 48.8566,
            longitude: 2.3522,
            locationName: "Paris",
            countryCode: "FR"
        )

        let id = try fixture.service.createBlogItem(
            blogText: "A two-photo post",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            photos: [later, earlier]
        )

        let item = try fixture.database.read { db in try BlogItem.find(db, key: id) }
        let photoItems = try fixture.database.read { db in
            try PhotoItem.where { $0.blogItemID.eq(id) }.fetchAll(db)
        }
        let displayed = try #require(fixture.service.loadTrips().first?.days.first?.blogItems.first)

        #expect(item.itemDate == earlier.photoDate)
        #expect(item.itemTimeZoneIdentifier == "Europe/Paris")
        #expect(item.locationName == "Paris")
        #expect(item.countryCode == "FR")
        #expect(photoItems.count == 2)
        #expect(displayed.id == id)
        #expect(displayed.photos.map(\.caption) == ["Earlier", "Later"])
    }

    @Test func acceptsTextOnlyPostAndRejectsAContentlessPost() throws {
        let fixture = try JournalFixture()

        let id = try fixture.service.createBlogItem(
            blogText: "Text only",
            date: fixture.now,
            timeZoneIdentifier: "UTC"
        )
        let item = try fixture.database.read { db in try BlogItem.find(db, key: id) }

        #expect(item.blogText == "Text only")
        #expect(try fixture.database.read { db in try PhotoItem.fetchCount(db) } == 0)
        #expect(throws: JournalServiceError.emptyBlogItem) {
            try fixture.service.createBlogItem(
                blogText: "  ",
                date: fixture.now,
                timeZoneIdentifier: "UTC"
            )
        }
    }

    @Test func blankDraftUsesCurrentBloggerInsteadOfSourceAuthor() throws {
        let fixture = try JournalFixture(currentBloggerName: "Rog")
        let source = BlogItemDisplay(
            id: UUID(),
            author: "Jane",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            blogText: "Existing entry",
            location: "",
            weather: WeatherDisplay(),
            photos: [],
            syncStatus: .synced
        )

        let draft = try fixture.service.makeBlankBlogItemDraft(after: source)

        #expect(draft.author == "Rog")
    }

    @Test func tripsDeriveMembershipFromBlogItemDates() throws {
        let fixture = try JournalFixture()
        _ = try fixture.service.createBlogItem(
            blogText: "Inside",
            date: fixture.date("2027-01-15T10:00:00Z"),
            timeZoneIdentifier: "UTC"
        )
        let outsideID = try fixture.service.createBlogItem(
            blogText: "Outside",
            date: fixture.date("2026-12-01T10:00:00Z"),
            timeZoneIdentifier: "UTC"
        )

        let trips = try fixture.service.loadTrips()
        let trip = try #require(trips.first { !$0.isUnassigned })
        let unassigned = try #require(trips.first { $0.isUnassigned })

        #expect(trip.days.flatMap(\.blogItems).map(\.blogText) == ["Inside"])
        #expect(unassigned.days.flatMap(\.blogItems).map(\.id) == [outsideID])
    }

    @Test func deletingTripLeavesItsPostsUnassigned() throws {
        let fixture = try JournalFixture()
        let itemID = try fixture.service.createBlogItem(
            blogText: "Remains",
            date: fixture.now,
            timeZoneIdentifier: "UTC"
        )

        try fixture.service.deleteTrip(id: fixture.tripID)

        let trips = try fixture.service.loadTrips()
        #expect(trips.count == 1)
        #expect(trips[0].isUnassigned)
        #expect(trips[0].days.flatMap(\.blogItems).map(\.id) == [itemID])
        let stored = try fixture.database.read { db in try BlogItem.find(db, key: itemID) }
        #expect(stored.deletedAt == nil)
    }

    @Test func removingPhotoHardDeletesItsPhotoItemAndOrphanedAsset() throws {
        let fixture = try JournalFixture()
        let id = try fixture.service.createBlogItem(
            blogText: "Keep one",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            photos: [
                fixture.photoDraft(byte: 0x31, date: fixture.now, caption: "Keep"),
                fixture.photoDraft(byte: 0x32, date: fixture.now.addingTimeInterval(1), caption: "Remove"),
            ]
        )
        let display = try fixture.displayItem(id: id)
        let retained = try #require(display.photos.first { $0.caption == "Keep" })
        let removed = try #require(display.photos.first { $0.caption == "Remove" })
        let removedPath = try #require(removed.localImagePath)

        try fixture.service.updateBlogItem(
            fixture.updateRequest(for: display, photos: [.existing(retained)])
        )

        #expect(try fixture.database.read { db in try PhotoItem.fetchCount(db) } == 1)
        #expect(try fixture.database.read { db in try MediaAsset.fetchCount(db) } == 1)
        #expect(!FileManager.default.fileExists(atPath: removedPath))
    }

    @Test func deletingPostKeepsContentFileUsedByAnotherMediaAsset() throws {
        let fixture = try JournalFixture()
        let sharedDraft = fixture.photoDraft(byte: 0x33, date: fixture.now)
        let firstID = try fixture.service.createBlogItem(
            blogText: "First",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            photos: [sharedDraft]
        )
        let secondID = try fixture.service.createBlogItem(
            blogText: "Second",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            photos: [sharedDraft]
        )
        let sharedPath = try #require(fixture.displayItem(id: secondID).photos.first?.localImagePath)

        try fixture.service.deleteBlogItem(id: firstID)

        #expect(FileManager.default.fileExists(atPath: sharedPath))
        #expect(try fixture.displayItem(id: secondID).photos.first?.availability == .available)
    }

    @Test func replacingOnlyPhotoAdoptsReplacementMetadata() throws {
        let fixture = try JournalFixture()
        let id = try fixture.service.createBlogItem(
            blogText: "Replacement",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            photos: [fixture.photoDraft(byte: 0x41, date: fixture.now)]
        )
        let display = try fixture.displayItem(id: id)
        let replacementDate = fixture.date("2026-11-05T08:30:00Z")
        let replacement = fixture.photoDraft(
            byte: 0x42,
            date: replacementDate,
            caption: "New",
            timeZoneIdentifier: "America/New_York",
            latitude: 40.7128,
            longitude: -74.006,
            locationName: "New York",
            countryCode: "US"
        )

        try fixture.service.updateBlogItem(
            fixture.updateRequest(for: display, photos: [.added(replacement)])
        )

        let stored = try fixture.database.read { db in try BlogItem.find(db, key: id) }
        #expect(stored.itemDate == replacementDate)
        #expect(stored.itemTimeZoneIdentifier == "America/New_York")
        #expect(stored.locationName == "New York")
        #expect(stored.latitude == 40.7128)
        #expect(stored.countryCode == "US")
    }

    @Test func deletingPostPreservesPhotosAndRecoveryRestoresPost() throws {
        let fixture = try JournalFixture()
        let id = try fixture.service.createBlogItem(
            blogText: "Recover me",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            photos: [fixture.photoDraft(byte: 0x50, date: fixture.now)]
        )
        let path = try #require(fixture.displayItem(id: id).photos.first?.localImagePath)

        try fixture.service.deleteBlogItem(id: id)

        #expect(try fixture.service.loadTrips().flatMap(\.days).flatMap(\.blogItems).contains { $0.id == id } == false)
        let deleted = try #require(fixture.service.loadDeletedBlogItems().first)
        #expect(deleted.id == id)
        #expect(deleted.photos.count == 1)
        #expect(FileManager.default.fileExists(atPath: path))

        try fixture.service.recoverBlogItem(id: id)

        #expect(try fixture.service.loadDeletedBlogItems().isEmpty)
        #expect(try fixture.displayItem(id: id).photos.count == 1)
    }

    @Test func deletingPostForeverHardDeletesPhotosButKeepsTripReferencedMedia() throws {
        let fixture = try JournalFixture()
        let id = try fixture.service.createBlogItem(
            blogText: "Hero",
            date: fixture.now,
            timeZoneIdentifier: "UTC",
            photos: [fixture.photoDraft(byte: 0x51, date: fixture.now)]
        )
        let asset = try fixture.database.read { db -> MediaAsset in
            let photo = try #require(try PhotoItem.where { $0.blogItemID.eq(id) }.fetchOne(db))
            return try MediaAsset.find(db, key: photo.mediaAssetID)
        }
        let path = fixture.mediaURL.appendingPathComponent(asset.filename).path
        try fixture.database.write { db in
            try Trip.find(fixture.tripID).update { $0.heroImageAssetID = #bind(asset.id) }.execute(db)
        }

        try fixture.service.deleteBlogItem(id: id)

        let stored = try fixture.database.read { db in try BlogItem.find(db, key: id) }
        #expect(stored.deletedAt != nil)
        #expect(try fixture.database.read { db in try PhotoItem.fetchCount(db) } == 1)

        try fixture.service.permanentlyDeleteBlogItem(id: id)

        #expect(try fixture.database.read { db in try BlogItem.find(id).fetchOne(db) } == nil)
        #expect(try fixture.database.read { db in try PhotoItem.fetchCount(db) } == 0)
        #expect(try fixture.database.read { db in try MediaAsset.fetchCount(db) } == 1)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

private final class JournalFixture {
    let database: any DatabaseWriter
    let now: Date
    let service: JournalService
    let rootURL: URL
    let mediaURL: URL
    let tripID: Trip.ID

    init(currentBloggerName: String? = nil) throws {
        let now = ISO8601DateFormatter().date(from: "2027-01-15T12:00:00Z")!
        let database = try AppDatabase.makeInMemory()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalFixture-\(UUID().uuidString)", isDirectory: true)
        let mediaURL = rootURL.appendingPathComponent("Media", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("Cache", isDirectory: true)
        self.database = database
        self.now = now
        self.rootURL = rootURL
        self.mediaURL = mediaURL
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        let workspace = try BlogBootstrapService(database: database, now: { [now] in now }).bootstrap()
        let tripID = UUID()
        self.tripID = tripID
        try database.write { db in
            try Trip.insert {
                Trip.Draft(
                    id: tripID,
                    blogID: workspace.blog.id,
                    title: "January",
                    description: "",
                    startLocalDay: "2027-01-01",
                    endLocalDay: "2027-01-31",
                    createdAt: now,
                    updatedAt: now,
                    closedAt: now
                )
            }
            .execute(db)
        }
        let currentBloggerID: Blogger.ID
        if let currentBloggerName {
            currentBloggerID = UUID()
            try database.write { db in
                try Blogger.insert {
                    Blogger.Draft(
                        id: currentBloggerID,
                        blogID: workspace.blog.id,
                        displayName: currentBloggerName,
                        createdAt: now.addingTimeInterval(1),
                        updatedAt: now.addingTimeInterval(1)
                    )
                }.execute(db)
            }
        } else {
            currentBloggerID = workspace.blogger.id
        }
        service = JournalService(
            database: database,
            now: { [now] in now },
            mediaDirectoryURL: mediaURL,
            mediaCacheDirectoryURL: cacheURL,
            blogID: workspace.blog.id,
            bloggerID: currentBloggerID
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func photoDraft(
        byte: UInt8,
        date: Date,
        caption: String = "",
        timeZoneIdentifier: String? = "UTC",
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        countryCode: String? = nil
    ) -> BlogItemPhotoAssetDraft {
        BlogItemPhotoAssetDraft(
            imageData: Data([byte]),
            mimeType: "image/jpeg",
            photoLibraryAssetIdentifier: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            photoDate: date,
            photoCaption: caption,
            timeZoneIdentifier: timeZoneIdentifier,
            latitude: latitude,
            longitude: longitude,
            locationName: locationName,
            countryCode: countryCode
        )
    }

    func displayItem(id: BlogItem.ID) throws -> BlogItemDisplay {
        try #require(
            service.loadTrips()
                .flatMap(\.days)
                .flatMap(\.blogItems)
                .first { $0.id == id }
        )
    }

    func updateRequest(
        for item: BlogItemDisplay,
        photos: [BlogItemPhotoUpdate]
    ) -> BlogItemUpdateRequest {
        BlogItemUpdateRequest(
            id: item.id,
            blogText: item.blogText,
            date: item.date,
            location: item.location,
            latitude: item.latitude,
            longitude: item.longitude,
            temperatureCelsius: item.weather.temperatureCelsius ?? 0,
            weatherCondition: item.weather.conditionCode,
            photos: photos
        )
    }
}
