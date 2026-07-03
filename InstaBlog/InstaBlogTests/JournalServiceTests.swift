import Foundation
import CryptoKit
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

    @Test func deleteBlogItemHidesItFromCurrentTrip() throws {
        let fixture = try JournalFixture()
        let originalTrip = try #require(try fixture.service.loadCurrentTrip())
        let originalItem = try #require(originalTrip.days.flatMap(\.entries).flatMap(\.blogItems).first)

        try fixture.service.deleteBlogItem(id: originalItem.id)

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        let remainingItems = reloadedTrip.days.flatMap(\.entries).flatMap(\.blogItems)
        #expect(!remainingItems.contains(where: { $0.id == originalItem.id }))
    }

    @Test func staleWorkspaceServiceCannotMutateHiddenBlogAfterActiveBlogSwitch() throws {
        let fixture = try JournalFixture()
        let originalTrip = try #require(try fixture.service.loadCurrentTrip())
        let originalItem = try #require(
            originalTrip.days.flatMap(\.entries).flatMap(\.blogItems).first
        )
        let originalTemperature = try #require(originalItem.weather.temperatureCelsius)
        let originalCondition = try #require(originalItem.weather.condition)
        let second = try fixture.insertAndActivateSecondWorkspace()

        #expect(throws: JournalServiceError.inactiveBlogMutation) {
            try fixture.service.updateTripDetails(
                id: originalTrip.id,
                title: "Hidden mutation",
                description: "",
                startLocalDay: originalTrip.startLocalDay,
                endLocalDay: originalTrip.endLocalDay
            )
        }
        #expect(throws: JournalServiceError.inactiveBlogMutation) {
            try fixture.service.endTrip(id: originalTrip.id)
        }
        #expect(throws: JournalServiceError.inactiveBlogMutation) {
            try fixture.service.updateBlogItem(
                id: originalItem.id,
                caption: "Hidden mutation",
                date: originalItem.date,
                location: originalItem.location,
                temperatureCelsius: originalTemperature,
                weatherCondition: originalCondition
            )
        }

        let unchanged = try fixture.database.read { db in
            (
                try Trip.find(db, key: originalTrip.id),
                try BlogItem.find(db, key: originalItem.id)
            )
        }
        #expect(unchanged.0.title == originalTrip.title)
        #expect(unchanged.0.closedAt == nil)
        #expect(unchanged.1.caption == originalItem.caption)

        let activeService = fixture.service(for: second.blog, blogger: second.blogger)
        try activeService.updateTripDetails(
            id: second.trip.id,
            title: "Active mutation",
            description: "",
            startLocalDay: second.trip.startLocalDay,
            endLocalDay: nil
        )
        let updatedTitle = try fixture.database.read {
            try Trip.find($0, key: second.trip.id).title
        }
        #expect(updatedTitle == "Active mutation")
    }

    @Test func createPhotoBlogItemPersistsAndAppearsAtLatestPosition() throws {
        let fixture = try JournalFixture()
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        let createdID = try fixture.service.createPhotoBlogItem(
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
        #expect(latestItem.author == "Rog")
        #expect(latestItem.date == newDate)
        #expect(latestItem.localImagePath?.hasSuffix(".jpg") == true)
        #expect(latestItem.syncStatus == .storedLocally)
        #expect(FileManager.default.fileExists(atPath: latestItem.localImagePath ?? ""))
        let storedMedia = try fixture.database.read { db in
            let mediaID = try #require(BlogItem.find(db, key: createdID).photoAssetID)
            return try MediaAsset.find(db, key: mediaID)
        }
        #expect(storedMedia.contentHash != nil)
        #expect(storedMedia.localOriginalPath == storedMedia.filename)
        let expectedHash = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(storedMedia.contentHash == expectedHash)
        #expect(storedMedia.filename == "\(expectedHash).jpg")
    }

    @Test func openCurrentTripLoadsItemsThroughNow() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        _ = try fixture.service.createPhotoBlogItem(
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

        _ = try fixture.service.createPhotoBlogItem(
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
        #expect(latestItem.localImagePath?.contains("/Cache/") == false)
        #expect(FileManager.default.fileExists(atPath: latestItem.localImagePath ?? ""))
    }

    @Test func captureWeatherPersistsWeatherAndCoordinates() async throws {
        let fixture = try JournalFixture(
            locationProvider: StubLocationProvider(
                location: WeatherLocation(latitude: 51.5074, longitude: -0.1278)
            ),
            weatherProvider: StubWeatherProvider(
                capture: WeatherCapture(
                    latitude: 51.5074,
                    longitude: -0.1278,
                    temperatureCelsius: 19,
                    conditionCode: "partlyCloudy"
                )
            )
        )
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        let id = try fixture.service.createPhotoBlogItem(
            caption: "Weather-enriched photo post",
            date: newDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        await fixture.service.captureWeather(for: id)

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        let latestEntry = try #require(reloadedTrip.days.last?.entries.last)
        let latestItem = try #require(latestEntry.blogItems.first)

        #expect(latestItem.weather.temperatureCelsius == 19)
        #expect(latestItem.weather.condition == "Partly cloudy")

        try await fixture.database.read { db in
            let item = try BlogItem.find(db, key: id)
            #expect(item.latitude == 51.5074)
            #expect(item.longitude == -0.1278)
            #expect(item.weatherConditionCode == "partlyCloudy")
            #expect(item.weatherTemperatureCelsius == 19)
        }
    }

    @Test func primedWeatherCaptureIsReusedWhenSaving() async throws {
        let counter = WeatherRequestCounter()
        let fixture = try JournalFixture(
            locationProvider: CountingLocationProvider(
                counter: counter,
                location: WeatherLocation(latitude: 51.5074, longitude: -0.1278)
            ),
            weatherProvider: CountingWeatherProvider(
                counter: counter,
                capture: WeatherCapture(
                    latitude: 51.5074,
                    longitude: -0.1278,
                    temperatureCelsius: 19,
                    conditionCode: "partlyCloudy"
                )
            )
        )
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        await fixture.service.primeWeatherCapture()

        let id = try fixture.service.createPhotoBlogItem(
            caption: "Warm weather capture",
            date: newDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        await fixture.service.captureWeather(for: id)

        let counts = await counter.snapshot()
        #expect(counts.locationRequests == 1)
        #expect(counts.weatherRequests == 1)
    }

    @Test func loadTripsOmitsPhotoUntilExternalAssetIsDownloaded() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        _ = try fixture.service.createPhotoBlogItem(
            caption: "Received shared photo",
            date: Date(timeIntervalSince1970: 1_782_300_000),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        let (mediaID, originalPath) = try fixture.database.read { db in
            let item = try BlogItem
                .where { $0.caption.eq("Received shared photo") }
                .fetchOne(db)
            let mediaID = try #require(item?.photoAssetID)
            return (mediaID, try MediaAsset.find(db, key: mediaID).localOriginalPath)
        }
        if let originalPath {
            try FileManager.default.removeItem(
                at: fixture.mediaURL.appendingPathComponent(originalPath)
            )
        }
        try fixture.database.write { db in
            try MediaAsset.find(mediaID).update {
                $0.localOriginalPath = #bind(nil)
            }.execute(db)
        }

        let trip = try #require(try fixture.service.loadCurrentTrip())
        let item = try #require(trip.days.flatMap(\.entries).flatMap(\.blogItems).last)
        #expect(item.localImagePath == nil)
    }

    @Test func loadTripsGracefullyOmitsPhotoWhenFileAndStoredDataAreMissing() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        _ = try fixture.service.createPhotoBlogItem(
            caption: "Missing photo",
            date: Date(timeIntervalSince1970: 1_782_300_000),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        try fixture.database.write { db in
            let item = try BlogItem
                .where { $0.caption.eq("Missing photo") }
                .fetchOne(db)
            let mediaID = try #require(item?.photoAssetID)
            let media = try MediaAsset.find(db, key: mediaID)
            if let path = media.localOriginalPath {
                try FileManager.default.removeItem(
                    at: fixture.mediaURL.appendingPathComponent(path)
                )
            }
            try MediaAsset.find(mediaID).update {
                $0.localOriginalPath = #bind(nil)
            }.execute(db)
        }

        let trip = try #require(try fixture.service.loadCurrentTrip())
        let item = try #require(trip.days.flatMap(\.entries).flatMap(\.blogItems).last)
        #expect(item.localImagePath == nil)
    }

    @Test func loadTripsRejectsDirectoryAtLocalOriginalPath() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        try fixture.service.createPhotoBlogItem(
            caption: "Directory is not an image",
            date: Date(timeIntervalSince1970: 1_782_300_000),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        let originalPath = try fixture.localOriginalPath(caption: "Directory is not an image")
        try FileManager.default.removeItem(atPath: originalPath)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: originalPath),
            withIntermediateDirectories: false
        )

        let trip = try #require(try fixture.service.loadCurrentTrip())
        let item = try #require(trip.days.flatMap(\.entries).flatMap(\.blogItems).last)
        #expect(item.localImagePath == nil)
    }

    @Test func createPhotoBlogItemRollsBackWhenMetadataInsertFails() throws {
        let fixture = try JournalFixture()
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        let countsBefore = try fixture.photoRecordCounts()
        try fixture.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_media_asset_insert
                BEFORE INSERT ON mediaAssets
                BEGIN
                    SELECT RAISE(ABORT, 'forced media data failure');
                END
                """)
        }

        var didThrow = false
        do {
            try fixture.service.createPhotoBlogItem(
                caption: "Must roll back",
                date: fixture.now,
                timeZoneIdentifier: "Europe/London",
                imageData: imageData,
                mimeType: "image/jpeg",
                pixelWidth: 1,
                pixelHeight: 1
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try fixture.photoRecordCounts() == countsBefore)
        let stagedFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.mediaURL,
            includingPropertiesForKeys: nil
        )
        #expect(stagedFiles.isEmpty)
    }

    @Test func loadTripsGracefullyOmitsPhotoWhenCacheCannotBeCreated() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))

        try fixture.service.createPhotoBlogItem(
            caption: "Blocked cache",
            date: Date(timeIntervalSince1970: 1_782_300_000),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        let originalPath = try fixture.localOriginalPath(caption: "Blocked cache")
        try FileManager.default.removeItem(atPath: originalPath)
        try Data([1]).write(to: fixture.cacheURL)

        let trip = try #require(try fixture.service.loadCurrentTrip())
        let item = try #require(trip.days.flatMap(\.entries).flatMap(\.blogItems).last)
        #expect(item.localImagePath == nil)
    }

    @Test func loadTripsDoesNotTrustSyncedPathsOrFilenames() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let firstData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        var secondData = firstData
        secondData.append(1)

        for (caption, data) in [("Hostile first", firstData), ("Hostile second", secondData)] {
            try fixture.service.createPhotoBlogItem(
                caption: caption,
                date: Date(timeIntervalSince1970: 1_782_300_000),
                timeZoneIdentifier: "Europe/London",
                imageData: data,
                mimeType: "image/jpeg",
                pixelWidth: 1,
                pixelHeight: 1
            )
        }

        let outsideURL = fixture.rootURL.appendingPathComponent("outside.jpg")
        try Data([9]).write(to: outsideURL)
        _ = try fixture.database.write { db in
            let items = try BlogItem.fetchAll(db).filter {
                ["Hostile first", "Hostile second"].contains($0.caption)
            }
            let mediaIDs = try items.map { try #require($0.photoAssetID) }
            for mediaID in mediaIDs {
                let media = try MediaAsset.find(db, key: mediaID)
                if let path = media.localOriginalPath {
                    try FileManager.default.removeItem(
                        at: fixture.mediaURL.appendingPathComponent(path)
                    )
                }
                try MediaAsset.find(mediaID).update {
                    $0.localOriginalPath = #bind(outsideURL.path)
                    $0.filename = #bind("../../same/name.jpg")
                }.execute(db)
            }
            return mediaIDs
        }

        let firstTrip = try #require(try fixture.service.loadCurrentTrip())
        let firstItems = firstTrip.days
            .flatMap(\.entries)
            .flatMap(\.blogItems)
            .filter { ["Hostile first", "Hostile second"].contains($0.caption) }
        #expect(firstItems.allSatisfy { $0.localImagePath == nil })
        #expect(!firstItems.contains { $0.localImagePath == outsideURL.path })
    }

    @Test func loadTripsDoesNotResolveMediaForDeletedItems() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        try fixture.service.createPhotoBlogItem(
            caption: "Deleted photo",
            date: Date(timeIntervalSince1970: 1_782_300_000),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        let originalPath = try fixture.localOriginalPath(caption: "Deleted photo")
        try FileManager.default.removeItem(atPath: originalPath)
        try fixture.database.write { db in
            try BlogItem
                .where { $0.caption.eq("Deleted photo") }
                .update { $0.deletedAt = #bind(fixture.now) }
                .execute(db)
        }

        _ = try fixture.service.loadTrips()

        #expect(!FileManager.default.fileExists(atPath: fixture.cacheURL.path))
    }

    private static let onePixelJPEGBase64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAkGBxAQEBUQEBAVFRUVFRUVFRUVFRUVFRUVFRUWFhUVFRUYHSggGBolHRUVITEhJSkrLi4uFx8zODMsNygtLisBCgoKDg0OGxAQGyslICYtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLf/AABEIAAEAAQMBIgACEQEDEQH/xAAXAAEBAQEAAAAAAAAAAAAAAAAAAQID/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEAMQAAAB6A//xAAWEAEBAQAAAAAAAAAAAAAAAAABABH/2gAIAQEAAT8Aqf/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8Af//Z"
}

private final class JournalFixture {
    let database: any DatabaseWriter
    let now: Date
    let service: JournalService
    let rootURL: URL
    let mediaURL: URL
    let cacheURL: URL

    init(
        now: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 1_800_000_000)
        },
        locationProvider: any CurrentLocationProviding = FailingLocationProvider(),
        weatherProvider: any WeatherProviding = FailingWeatherProvider(),
        weatherAttributionProvider: any WeatherAttributing = StubWeatherAttributionProvider()
    ) throws {
        self.now = now()
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("JournalFixture-\(UUID().uuidString)", isDirectory: true)
        mediaURL = rootURL.appendingPathComponent("Media", isDirectory: true)
        cacheURL = rootURL.appendingPathComponent("Cache", isDirectory: true)
        database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        service = JournalService(
            database: database,
            now: now,
            mediaDirectoryURL: mediaURL,
            locationProvider: locationProvider,
            weatherProvider: weatherProvider,
            weatherAttributionProvider: weatherAttributionProvider,
            mediaCacheDirectoryURL: cacheURL,
            blogID: workspace.blog.id,
            bloggerID: workspace.blogger.id
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

    func insertAndActivateSecondWorkspace() throws -> (blog: Blog, blogger: Blogger, trip: Trip) {
        let blog = Blog(
            id: UUID(),
            title: "Shared Blog",
            createdAt: now,
            updatedAt: now
        )
        let blogger = Blogger(
            id: UUID(),
            blogID: blog.id,
            displayName: "Shared Author",
            createdAt: now,
            updatedAt: now
        )
        let trip = Trip(
            id: UUID(),
            blogID: blog.id,
            title: "Shared Trip",
            description: "",
            startLocalDay: "2027-01-15",
            createdAt: now,
            updatedAt: now
        )
        try database.write { db in
            try Blog.insert { blog }.execute(db)
            try Blogger.insert { blogger }.execute(db)
            try Trip.insert { trip }.execute(db)
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(blog.id) }
                .execute(db)
        }
        return (blog, blogger, trip)
    }

    func service(for blog: Blog, blogger: Blogger) -> JournalService {
        JournalService(
            database: database,
            now: { [now] in now },
            mediaDirectoryURL: mediaURL,
            mediaCacheDirectoryURL: cacheURL,
            blogID: blog.id,
            bloggerID: blogger.id
        )
    }

    func localOriginalPath(caption: String) throws -> String {
        try database.read { db in
            let item = try BlogItem.where { $0.caption.eq(caption) }.fetchOne(db)
            let mediaID = try #require(item?.photoAssetID)
            let storedPath = try #require(MediaAsset.find(db, key: mediaID).localOriginalPath)
            return storedPath.hasPrefix("/")
                ? storedPath
                : mediaURL.appendingPathComponent(storedPath).path
        }
    }

    func photoRecordCounts() throws -> [Int] {
        try database.read { db in
            [
                try MediaAsset.fetchCount(db),
                try BlogItem.fetchCount(db),
            ]
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

private struct FailingLocationProvider: CurrentLocationProviding {
    @MainActor
    func requestPermissionIfNeeded() async {}

    @MainActor
    func currentLocation() async throws -> WeatherLocation {
        throw CurrentLocationError.authorizationDenied
    }
}

private struct StubLocationProvider: CurrentLocationProviding {
    let location: WeatherLocation

    @MainActor
    func requestPermissionIfNeeded() async {}

    @MainActor
    func currentLocation() async throws -> WeatherLocation {
        location
    }
}

private struct FailingWeatherProvider: WeatherProviding {
    func currentWeather(for location: WeatherLocation) async throws -> WeatherCapture {
        throw CurrentLocationError.unavailable
    }

    func weather(for location: WeatherLocation, near date: Date) async throws -> WeatherCapture? {
        throw CurrentLocationError.unavailable
    }
}

private struct StubWeatherProvider: WeatherProviding {
    let capture: WeatherCapture

    func currentWeather(for location: WeatherLocation) async throws -> WeatherCapture {
        capture
    }

    func weather(for location: WeatherLocation, near date: Date) async throws -> WeatherCapture? {
        capture
    }
}

private struct StubWeatherAttributionProvider: WeatherAttributing {
    func attribution() async throws -> WeatherAttributionDisplay {
        WeatherAttributionDisplay(
            combinedMarkLightURL: URL(string: "https://example.com/light.png")!,
            combinedMarkDarkURL: URL(string: "https://example.com/dark.png")!,
            legalPageURL: URL(string: "https://example.com/legal")!,
            legalAttributionText: "Weather"
        )
    }
}

private actor WeatherRequestCounter {
    private(set) var locationRequests = 0
    private(set) var weatherRequests = 0

    func didRequestLocation() {
        locationRequests += 1
    }

    func didRequestWeather() {
        weatherRequests += 1
    }

    func snapshot() -> (locationRequests: Int, weatherRequests: Int) {
        (locationRequests, weatherRequests)
    }
}

private struct CountingLocationProvider: CurrentLocationProviding {
    let counter: WeatherRequestCounter
    let location: WeatherLocation

    @MainActor
    func requestPermissionIfNeeded() async {}

    @MainActor
    func currentLocation() async throws -> WeatherLocation {
        await counter.didRequestLocation()
        return location
    }
}

private struct CountingWeatherProvider: WeatherProviding {
    let counter: WeatherRequestCounter
    let capture: WeatherCapture

    func currentWeather(for location: WeatherLocation) async throws -> WeatherCapture {
        await counter.didRequestWeather()
        return capture
    }

    func weather(for location: WeatherLocation, near date: Date) async throws -> WeatherCapture? {
        await counter.didRequestWeather()
        return capture
    }
}
