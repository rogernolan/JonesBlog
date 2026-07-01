import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Database-backed journal")
struct JournalServiceTests {
    @Test func loadsSeededTripAndDerivesGallery() throws {
        let fixture = try JournalFixture()

        let trip = try #require(try fixture.service.loadCurrentTrip())
        let galleries: [GalleryDisplay] = trip.days.flatMap(\.entries).compactMap { entry in
            guard case .gallery(let gallery) = entry else { return nil }
            return gallery
        }

        #expect(trip.title == "Provence by Train")
        #expect(trip.days.count == 2)
        #expect(trip.days.flatMap(\.entries).count == 4)
        #expect(galleries.first?.items.count == 4)
        #expect(trip.days.flatMap(\.entries).flatMap(\.blogItems).count == 7)
    }

    @Test func loadTripsKeepsCurrentTripFirst() throws {
        let fixture = try JournalFixture()
        try fixture.insertClosedTrip(title: "Future Closed Trip", startLocalDay: "2027-01-01")

        let trips = try fixture.service.loadTrips()

        #expect(trips.map(\.title) == ["Provence by Train", "Future Closed Trip"])
        #expect(trips.first?.isCurrent == true)
    }

    @Test func updateTripDetailsPersistsMetadata() throws {
        let fixture = try JournalFixture()
        let trip = try #require(try fixture.service.loadCurrentTrip())

        try fixture.service.updateTripDetails(
            id: trip.id,
            title: "Updated Trip",
            description: "Updated description",
            startLocalDay: "2026-06-18",
            endLocalDay: "2026-06-22"
        )

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        #expect(reloadedTrip.title == "Updated Trip")
        #expect(reloadedTrip.description == "Updated description")
        #expect(reloadedTrip.startLocalDay == "2026-06-18")
        #expect(reloadedTrip.endLocalDay == "2026-06-22")
    }

    @Test func endTripPersistsClosureMetadata() throws {
        let fixture = try JournalFixture()
        let trip = try #require(try fixture.service.loadCurrentTrip())

        try fixture.service.endTrip(id: trip.id)

        #expect(try fixture.service.loadCurrentTrip() == nil)
        let reloadedTrip = try #require(
            try fixture.service.loadTrips().first { $0.id == trip.id }
        )
        #expect(reloadedTrip.isCurrent == false)
        #expect(reloadedTrip.endLocalDay == "2027-01-15")
        #expect(reloadedTrip.closedAt == fixture.now)
    }

    @Test func createTripPersistsANewCurrentTrip() throws {
        let fixture = try JournalFixture()
        let oldTrip = try #require(try fixture.service.loadCurrentTrip())
        try fixture.service.endTrip(id: oldTrip.id)

        let id = try fixture.service.createTrip(
            title: "new trip",
            description: "",
            startLocalDay: "2027-01-15",
            endLocalDay: nil
        )

        let trip = try #require(try fixture.service.loadCurrentTrip())
        #expect(trip.id == id)
        #expect(trip.title == "new trip")
        #expect(trip.description.isEmpty)
        #expect(trip.startLocalDay == "2027-01-15")
        #expect(trip.endLocalDay == nil)
    }

    @Test func updatePersistsAndReloadsBlogItem() throws {
        let fixture = try JournalFixture()
        let originalTrip = try #require(try fixture.service.loadCurrentTrip())
        let originalItem = try #require(originalTrip.days.flatMap(\.entries).flatMap(\.blogItems).first)
        let newDate = originalItem.date.addingTimeInterval(60)

        try fixture.service.updateBlogItem(
            id: originalItem.id,
            caption: "Updated from the detail screen",
            date: newDate,
            location: "Updated location",
            temperatureCelsius: 18,
            weatherCondition: "Cloudy"
        )

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        let reloadedItem = try #require(
            reloadedTrip.days.flatMap(\.entries).flatMap(\.blogItems).first { $0.id == originalItem.id }
        )
        #expect(reloadedItem.caption == "Updated from the detail screen")
        #expect(reloadedItem.date == newDate)
        #expect(reloadedItem.location == "Updated location")
        #expect(reloadedItem.weather.temperatureCelsius == 18)
        #expect(reloadedItem.weather.condition == "Cloudy")
    }

    @Test func createPhotoBlogItemPersistsAndAppearsAtLatestPosition() throws {
        let fixture = try JournalFixture()
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        try fixture.service.createPhotoBlogItem(
            caption: "A brand new photo post",
            date: newDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        let latestEntry = try #require(reloadedTrip.days.last?.entries.last)
        let latestItem = try #require(latestEntry.blogItems.first)

        #expect(latestItem.caption == "A brand new photo post")
        #expect(latestItem.date == newDate)
        #expect(latestItem.localImagePath?.hasSuffix(".jpg") == true)
        #expect(latestItem.syncStatus == .pending)
        #expect(FileManager.default.fileExists(atPath: latestItem.localImagePath ?? ""))
    }

    @Test func openCurrentTripLoadsItemsThroughNow() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        try fixture.service.createPhotoBlogItem(
            caption: "Visible in the current trip",
            date: newDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        let latestDay = try #require(reloadedTrip.days.last)
        let latestEntry = try #require(latestDay.entries.last)
        let latestItem = try #require(latestEntry.blogItems.first)

        #expect(latestDay.date == newDate)
        #expect(latestItem.caption == "Visible in the current trip")
    }

    @Test func createPhotoBlogItemResolvesPhotoFromCurrentMediaDirectory() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        try fixture.service.createPhotoBlogItem(
            caption: "Keeps its photo after a container path change",
            date: newDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        try fixture.database.write { db in
            try MediaAsset
                .update {
                    $0.localOriginalPath = #bind("/stale/container/BlogItemMedia/missing.jpg")
                }
                .execute(db)
        }

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        let latestEntry = try #require(reloadedTrip.days.last?.entries.last)
        let latestItem = try #require(latestEntry.blogItems.first)

        #expect(latestItem.localImagePath?.hasSuffix(".jpg") == true)
        #expect(FileManager.default.fileExists(atPath: latestItem.localImagePath ?? ""))
    }

    private static let onePixelJPEGBase64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAkGBxAQEBUQEBAVFRUVFRUVFRUVFRUVFRUVFRUWFhUVFRUYHSggGBolHRUVITEhJSkrLi4uFx8zODMsNygtLisBCgoKDg0OGxAQGyslICYtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLf/AABEIAAEAAQMBIgACEQEDEQH/xAAXAAEBAQEAAAAAAAAAAAAAAAAAAQID/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEAMQAAAB6A//xAAWEAEBAQAAAAAAAAAAAAAAAAABABH/2gAIAQEAAT8Aqf/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8Af//Z"
}

private final class JournalFixture {
    let database: any DatabaseWriter
    let now: Date
    let service: JournalService
    let rootURL: URL

    init(
        now: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_800_000_000)
        }
    ) throws {
        self.now = now()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("JournalFixture-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase.makeInMemory()
        _ = try BlogBootstrapService(database: database).bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        service = JournalService(
            database: database,
            now: now,
            mediaDirectoryURL: rootURL.appendingPathComponent("Media", isDirectory: true)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func insertClosedTrip(title: String, startLocalDay: String) throws {
        try database.write { db in
            guard let blog = try Blog.order(by: { ($0.createdAt, $0.id) }).fetchOne(db) else {
                throw JournalFixtureError.missingBlog
            }
            try Trip.insert {
                Trip.Draft(
                    id: UUID(),
                    blogID: blog.id,
                    title: title,
                    description: "",
                    startLocalDay: startLocalDay,
                    endLocalDay: startLocalDay,
                    createdAt: now,
                    updatedAt: now,
                    closedAt: now
                )
            }
            .execute(db)
        }
    }
}

private enum JournalFixtureError: Error {
    case missingBlog
}

private extension DayPostEntry {
    var blogItems: [BlogItemDisplay] {
        switch self {
        case .blogItem(let item): [item]
        case .gallery(let gallery): gallery.items
        }
    }
}
