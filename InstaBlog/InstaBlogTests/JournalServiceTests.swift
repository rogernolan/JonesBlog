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
}

private struct JournalFixture {
    let database: any DatabaseWriter
    let service: JournalService

    init() throws {
        database = try AppDatabase.makeInMemory()
        _ = try BlogBootstrapService(database: database).bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        service = JournalService(database: database)
    }
}

private extension DayPostEntry {
    var blogItems: [BlogItemDisplay] {
        switch self {
        case .blogItem(let item): [item]
        case .gallery(let gallery): gallery.items
        }
    }
}
