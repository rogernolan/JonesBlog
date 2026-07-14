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

    @Test func seededJournalHasUniqueDurablePlacements() throws {
        let fixture = try JournalFixture()

        let result = try fixture.database.read { db in
            (
                items: try BlogItem.fetchCount(db),
                placements: try BlogItemPlacement.fetchCount(db),
                galleries: try Gallery.fetchCount(db),
                galleryDayItems: try DayItem
                    .where { $0.galleryID.isNot(nil) }
                    .fetchCount(db)
            )
        }

        #expect(result.items == 7)
        #expect(result.placements == 7)
        #expect(result.galleries == 1)
        #expect(result.galleryDayItems == 1)
    }

    @Test func loadTripsUsesPlacementTimezoneWhenItemTimezoneIsMissing() throws {
        let fixture = try JournalFixture()
        let item = try fixture.database.read { db in
            try #require(try BlogItem.fetchOne(db))
        }
        let placement = try fixture.database.read { db in
            try #require(try BlogItemPlacement.where { $0.blogItemID.eq(item.id) }.fetchOne(db))
        }

        try fixture.database.write { db in
            try BlogItem.find(item.id)
                .update { $0.itemTimeZoneIdentifier = #bind(String?.none) }
                .execute(db)
            try DayItem.find(placement.dayItemID)
                .update { $0.placementTimeZoneIdentifier = #bind("Europe/Paris") }
                .execute(db)
        }

        let displayedItem = try fixture.service.loadTrips()
            .flatMap(\.days)
            .flatMap(\.entries)
            .flatMap(\.blogItems)
            .first { $0.id == item.id }

        #expect(displayedItem?.timeZoneIdentifier == "Europe/Paris")
    }

    @Test func creatingNearbyItemsMaterializesAStableGallery() throws {
        let fixture = try JournalFixture()
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        let firstDate = Date(timeIntervalSince1970: 1_780_300_000)

        let firstID = try fixture.service.createPhotoBlogItem(
            caption: "First",
            date: firstDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1,
            latitude: 51.5,
            longitude: -0.1
        )
        let secondID = try fixture.service.createPhotoBlogItem(
            caption: "Second",
            date: firstDate.addingTimeInterval(60),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1,
            latitude: 51.5001,
            longitude: -0.1001
        )

        let placement = try fixture.database.read { db -> (Gallery.ID?, Set<BlogItem.ID>) in
            let firstPlacement = try #require(
                try BlogItemPlacement.where { $0.blogItemID.eq(firstID) }.fetchOne(db)
            )
            let secondPlacement = try #require(
                try BlogItemPlacement.where { $0.blogItemID.eq(secondID) }.fetchOne(db)
            )
            #expect(firstPlacement.dayItemID == secondPlacement.dayItemID)
            let dayItem = try DayItem.find(db, key: firstPlacement.dayItemID)
            let members = try BlogItemPlacement
                .where { $0.dayItemID.eq(dayItem.id) }
                .fetchAll(db)
            return (dayItem.galleryID, Set(members.map(\.blogItemID)))
        }

        #expect(placement.0 != nil)
        #expect(placement.1 == Set([firstID, secondID]))

        try fixture.service.updateGalleryDistance(meters: 1)
        let unchangedPlacement = try fixture.database.read { db in
            try #require(
                try BlogItemPlacement.where { $0.blogItemID.eq(secondID) }.fetchOne(db)
            ).dayItemID
        }
        let firstPlacement = try fixture.database.read { db in
            try #require(
                try BlogItemPlacement.where { $0.blogItemID.eq(firstID) }.fetchOne(db)
            ).dayItemID
        }
        #expect(unchangedPlacement == firstPlacement)
    }

    @Test func createBlankBlogItemPersistsEmptyItemAtRequestedDate() throws {
        let fixture = try JournalFixture()
        let trip = try #require(try fixture.service.loadCurrentTrip())
        let previousItem = try #require(trip.days.flatMap(\.entries).flatMap(\.blogItems).first)
        let date = previousItem.date.addingTimeInterval(1)

        let createdID = try fixture.service.createBlankBlogItem(
            date: date,
            timeZoneIdentifier: previousItem.timeZoneIdentifier
        )

        let createdItem = try fixture.database.read { db in
            try #require(try BlogItem.find(db, key: createdID))
        }
        #expect(createdItem.itemDate == date)
        #expect(createdItem.caption == nil)
        #expect(createdItem.locationName == nil)
        #expect(createdItem.weatherTemperatureCelsius == nil)
        #expect(createdItem.weatherConditionCode == nil)
        #expect(createdItem.photoAssetID == nil)

        let placement = try fixture.database.read { db in
            try #require(try BlogItemPlacement.where { $0.blogItemID.eq(createdID) }.fetchOne(db))
        }
        #expect(placement.position >= 0)
    }

    @Test func enrichmentRetryCreatesGalleryAfterInitialLocationMismatch() throws {
        let fixture = try JournalFixture()
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        let firstDate = Date(timeIntervalSince1970: 1_780_300_000)
        let firstID = try fixture.service.createPhotoBlogItem(
            caption: "First",
            date: firstDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        try fixture.database.write { db in
            try BlogItem.find(firstID)
                .update {
                    $0.latitude = #bind(51.06531)
                    $0.longitude = #bind(0.85432)
                    $0.locationName = #bind("Orlestone, Ashford")
                }
                .execute(db)
        }

        let secondID = try fixture.service.createPhotoBlogItem(
            caption: "Second",
            date: firstDate.addingTimeInterval(5),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        #expect(try fixture.service.galleryContaining(secondID) == nil)

        try fixture.database.write { db in
            try BlogItem.find(secondID)
                .update {
                    $0.latitude = #bind(51.06531)
                    $0.longitude = #bind(0.85432)
                    $0.locationName = #bind("Orlestone, Ashford")
                }
                .execute(db)
        }
        try fixture.service.retryAutomaticGalleryPlacement(for: secondID)

        let createdGalleryID = try fixture.service.galleryContaining(secondID)
        let galleryID = try #require(createdGalleryID)
        #expect(try fixture.service.galleryContaining(firstID) == galleryID)
    }

    @Test func loadTripsRendersAnItemOnlyOnceWhenSyncDeliversCompetingPlacements() throws {
        let fixture = try JournalFixture()
        let item = try fixture.database.read { db in
            try #require(try BlogItem.fetchOne(db))
        }
        try fixture.database.write { db in
            let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
            let duplicateDayItemID = UUID()
            try DayItem.insert {
                DayItem.Draft(
                    id: duplicateDayItemID,
                    blogID: item.blogID,
                    galleryID: nil,
                    placementDate: item.itemDate,
                    placementTimeZoneIdentifier: item.itemTimeZoneIdentifier,
                    localDay: item.localDay,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    deletedAt: nil
                )
            }
            .execute(db)
            try BlogItemPlacement.insert {
                BlogItemPlacement.Draft(
                    id: UUID(),
                    blogItemID: item.id,
                    dayItemID: duplicateDayItemID,
                    position: 0,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
            .execute(db)
        }

        let occurrences = try fixture.service.loadTrips()
            .flatMap(\.days)
            .flatMap(\.entries)
            .flatMap(\.blogItems)
            .count { $0.id == item.id }
        #expect(occurrences == 1)
    }

    @Test func dayRoutesStartAtPreviousDayAndNormalizeDuplicateTownNames() throws {
        let fixture = try JournalFixture()
        let trip = try #require(
            try fixture.service.loadTrips().first { $0.title == "Provence by Train" }
        )
        let firstDay = try #require(trip.days.first)
        let secondDay = try #require(trip.days.dropFirst().first)
        let firstDayItem = try #require(firstDay.entries.flatMap(\.blogItems).first)
        let secondDayItems = secondDay.entries.flatMap(\.blogItems)
        var noisyLocations = [
            "Orelstone",
            "orelstone, Ashford",
            " orelstone ",
            "London",
            "Orlestone, Ashford",
        ]
        try #require(secondDayItems.count >= noisyLocations.count)
        if secondDayItems.count > noisyLocations.count {
            noisyLocations.append(
                contentsOf: repeatElement(
                    "London",
                    count: secondDayItems.count - noisyLocations.count
                )
            )
        }

        try fixture.database.write { db in
            try BlogItem.find(firstDayItem.id)
                .update { $0.locationName = #bind("Orelstone") }
                .execute(db)
            for (item, location) in zip(secondDayItems, noisyLocations) {
                try BlogItem.find(item.id)
                    .update { $0.locationName = #bind(location) }
                    .execute(db)
            }
        }

        let reloadedTrip = try #require(
            try fixture.service.loadTrips().first { $0.title == "Provence by Train" }
        )
        let reloadedSecondDay = try #require(reloadedTrip.days.dropFirst().first)
        #expect(reloadedTrip.days.first?.route == ["Orelstone"])
        #expect(reloadedSecondDay.route == ["Orelstone", "The Old Harbour", "London", "Orlestone"])
    }

    @Test func dayRoutesIncludeGalleryLocation() throws {
        let fixture = try JournalFixture()
        let gallery = try fixture.database.read { db in
            try #require(try Gallery.fetchOne(db))
        }

        try fixture.database.write { db in
            try Gallery.find(gallery.id)
                .update { $0.locationName = #bind("Marseille") }
                .execute(db)
        }

        let trip = try #require(
            try fixture.service.loadTrips().first { trip in
                trip.days.contains { day in
                    day.entries.contains { entry in
                        if case .gallery(let entryGallery) = entry {
                            return entryGallery.id == gallery.id
                        }
                        return false
                    }
                }
            }
        )
        let route = try #require(trip.days.first { day in
            day.entries.contains { entry in
                if case .gallery(let entryGallery) = entry {
                    return entryGallery.id == gallery.id
                }
                return false
            }
        }?.route)

        #expect(route.contains("Marseille"))
    }

    @Test func isolatedNewEntryRemainsDirect() throws {
        let fixture = try JournalFixture()
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        let galleryCountBefore = try fixture.database.read { db in
            try Gallery.fetchCount(db)
        }
        let itemID = try fixture.service.createPhotoBlogItem(
            caption: "Much later",
            date: Date(timeIntervalSince1970: 1_900_000_000),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        #expect(try fixture.service.galleryContaining(itemID) == nil)
        let galleryCountAfter = try fixture.database.read { db in
            try Gallery.fetchCount(db)
        }
        #expect(galleryCountAfter == galleryCountBefore)
    }

    @Test func movingMemberOutCreatesDirectPlacementInGalleryDay() throws {
        let fixture = try JournalFixture()
        let gallery = try fixture.database.read { db in
            try #require(try Gallery.fetchOne(db))
        }
        let galleryDayItem = try fixture.database.read { db in
            try #require(
                try DayItem.where { $0.galleryID.eq(gallery.id) }.fetchOne(db)
            )
        }
        let member = try fixture.database.read { db in
            try #require(
                try BlogItemPlacement
                    .where { $0.dayItemID.eq(galleryDayItem.id) }
                    .order { $0.position }
                    .fetchOne(db)
            )
        }

        try fixture.service.moveBlogItemOutOfGallery(member.blogItemID)

        let result = try fixture.database.read { db in
            let fetchedPlacement = try BlogItemPlacement
                .where { $0.blogItemID.eq(member.blogItemID) }
                .fetchOne(db)
            let movedPlacement = try #require(fetchedPlacement)
            let movedDayItem = try DayItem.find(db, key: movedPlacement.dayItemID)
            let remainingCount = try BlogItemPlacement
                .where { $0.dayItemID.eq(galleryDayItem.id) }
                .fetchCount(db)
            return (movedDayItem, remainingCount)
        }
        #expect(result.0.galleryID == nil)
        #expect(result.0.localDay == galleryDayItem.localDay)
        #expect(result.1 == 3)
    }

    @Test func movingLastItemOutDeletesTextlessGallery() throws {
        let fixture = try JournalFixture()
        let sourceGallery = try fixture.database.read { db in
            try #require(try Gallery.fetchOne(db))
        }
        let itemID = try fixture.database.read { db in
            let dayItem = try #require(
                try DayItem.where { $0.galleryID.eq(sourceGallery.id) }.fetchOne(db)
            )
            return try #require(
                try BlogItemPlacement.where { $0.dayItemID.eq(dayItem.id) }.fetchOne(db)
            ).blogItemID
        }
        let emptyGalleryID = try fixture.service.createGallery(
            title: "Temporary",
            description: "",
            placementDate: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "Europe/London"
        )
        try fixture.service.moveBlogItems([itemID], toGallery: emptyGalleryID)
        try fixture.database.write { db in
            try db.execute(
                sql: "UPDATE galleries SET title = '', description = '  ' WHERE id = ?",
                arguments: [emptyGalleryID]
            )
        }

        try fixture.service.moveBlogItemOutOfGallery(itemID)

        try fixture.database.read { db in
            #expect(try Gallery.find(db, key: emptyGalleryID).deletedAt != nil)
            let dayItem = try DayItem
                .where { $0.galleryID.eq(emptyGalleryID) }
                .fetchOne(db)
            #expect(dayItem?.deletedAt != nil)
        }
    }

    @Test func movingLastItemOutDeletesGalleryWithMetadata() throws {
        let fixture = try JournalFixture()
        let sourceGallery = try fixture.database.read { db in
            try #require(try Gallery.fetchOne(db))
        }
        let itemID = try fixture.database.read { db in
            let dayItem = try #require(
                try DayItem.where { $0.galleryID.eq(sourceGallery.id) }.fetchOne(db)
            )
            return try #require(
                try BlogItemPlacement.where { $0.dayItemID.eq(dayItem.id) }.fetchOne(db)
            ).blogItemID
        }
        let destinationGalleryID = try fixture.service.createGallery(
            title: "Named Gallery",
            description: "A gallery that should be removed when emptied.",
            placementDate: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "Europe/London"
        )
        try fixture.service.moveBlogItems([itemID], toGallery: destinationGalleryID)

        try fixture.service.moveBlogItemOutOfGallery(itemID)

        try fixture.database.read { db in
            #expect(try Gallery.find(db, key: destinationGalleryID).deletedAt != nil)
            let dayItem = try DayItem
                .where { $0.galleryID.eq(destinationGalleryID) }
                .fetchOne(db)
            #expect(dayItem?.deletedAt != nil)
        }
    }

    @Test func deletingGalleryCanPromoteMembers() throws {
        let fixture = try JournalFixture()
        let gallery = try fixture.database.read { db in try #require(try Gallery.fetchOne(db)) }
        let memberIDs = try fixture.database.read { db in
            let dayItem = try #require(
                try DayItem.where { $0.galleryID.eq(gallery.id) }.fetchOne(db)
            )
            return try BlogItemPlacement
                .where { $0.dayItemID.eq(dayItem.id) }
                .fetchAll(db)
                .map(\.blogItemID)
        }

        try fixture.service.deleteGallery(id: gallery.id, deletingEntries: false)

        try fixture.database.read { db in
            #expect(try Gallery.find(db, key: gallery.id).deletedAt != nil)
            for memberID in memberIDs {
                #expect(try BlogItem.find(db, key: memberID).deletedAt == nil)
                let placement = try #require(
                    try BlogItemPlacement.where { $0.blogItemID.eq(memberID) }.fetchOne(db)
                )
                #expect(try DayItem.find(db, key: placement.dayItemID).galleryID == nil)
            }
        }
    }

    @Test func deletingGalleryCanDeleteMembers() throws {
        let fixture = try JournalFixture()
        let gallery = try fixture.database.read { db in try #require(try Gallery.fetchOne(db)) }
        let memberIDs = try fixture.database.read { db in
            let dayItem = try #require(
                try DayItem.where { $0.galleryID.eq(gallery.id) }.fetchOne(db)
            )
            return try BlogItemPlacement
                .where { $0.dayItemID.eq(dayItem.id) }
                .fetchAll(db)
                .map(\.blogItemID)
        }

        try fixture.service.deleteGallery(id: gallery.id, deletingEntries: true)

        try fixture.database.read { db in
            for memberID in memberIDs {
                let item = try BlogItem.find(db, key: memberID)
                let placement = try BlogItemPlacement
                    .where { $0.blogItemID.eq(memberID) }
                    .fetchOne(db)
                #expect(item.deletedAt != nil)
                #expect(placement == nil)
            }
        }
    }

    @Test func reorderGalleryPersistsManualOrder() throws {
        let fixture = try JournalFixture()
        let gallery = try fixture.database.read { db in try #require(try Gallery.fetchOne(db)) }
        let dayItem = try fixture.database.read { db in
            try #require(try DayItem.where { $0.galleryID.eq(gallery.id) }.fetchOne(db))
        }
        let originalIDs = try fixture.database.read { db in
            try BlogItemPlacement
                .where { $0.dayItemID.eq(dayItem.id) }
                .order { $0.position }
                .fetchAll(db)
                .map(\.blogItemID)
        }

        try fixture.service.reorderGallery(gallery.id, itemIDs: originalIDs.reversed())

        let result = try fixture.database.read { db in
            (
                try Gallery.find(db, key: gallery.id).sortMode,
                try BlogItemPlacement
                    .where { $0.dayItemID.eq(dayItem.id) }
                    .order { $0.position }
                    .fetchAll(db)
                    .map(\.blogItemID)
            )
        }
        #expect(result.0 == GallerySortMode.manual.rawValue)
        #expect(result.1 == Array(originalIDs.reversed()))
    }

    @Test func unplacedItemCanBeRecoveredWithoutDuplication() throws {
        let fixture = try JournalFixture()
        let direct = try fixture.database.read { db in
            try #require(
                try DayItem.where { $0.galleryID.is(nil) }.fetchOne(db)
            )
        }
        let itemID = try fixture.database.write { db -> BlogItem.ID in
            let placement = try #require(
                try BlogItemPlacement.where { $0.dayItemID.eq(direct.id) }.fetchOne(db)
            )
            try BlogItemPlacement.find(placement.id).delete().execute(db)
            try DayItem.find(direct.id).delete().execute(db)
            return placement.blogItemID
        }

        #expect(try fixture.service.loadUnplacedBlogItems().map(\.id).contains(itemID))
        try fixture.service.restoreUnplacedBlogItem(itemID)
        try fixture.service.restoreUnplacedBlogItem(itemID)

        let placements = try fixture.database.read { db in
            try BlogItemPlacement.where { $0.blogItemID.eq(itemID) }.fetchCount(db)
        }
        #expect(placements == 1)
        let remainingUnplacedIDs = try fixture.service.loadUnplacedBlogItems().map(\.id)
        #expect(!remainingUnplacedIDs.contains(itemID))
    }

    @Test func loadTripsKeepsCurrentTripFirst() throws {
        let fixture = try JournalFixture()
        try fixture.insertClosedTrip(title: "Future Closed Trip", startLocalDay: "2027-01-01")

        let trips = try fixture.service.loadTrips()

        #expect(trips.map(\.title) == ["Provence by Train", "Future Closed Trip"])
        #expect(trips.first?.isCurrent == true)
    }

    @Test func loadTripsIncludesUnassignedRowForItemsOutsideTripRanges() throws {
        let fixture = try JournalFixture()
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        let unassignedDate = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))
        )

        _ = try fixture.service.createPhotoBlogItem(
            caption: "Before the trip started",
            date: unassignedDate,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        let trips = try fixture.service.loadTrips()
        let unassigned = try #require(trips.first)
        let currentTrip = try #require(try fixture.service.loadCurrentTrip())

        #expect(unassigned.isUnassigned)
        #expect(unassigned.title == "Unassigned")
        #expect(
            unassigned.days
                .flatMap(\.entries)
                .flatMap(\.blogItems)
                .contains(where: { $0.caption == "Before the trip started" })
        )
        #expect(currentTrip.title == "Provence by Train")
        #expect(currentTrip.isUnassigned == false)
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

        let reloadedTrip = try #require(
            try fixture.service.loadTrips().first { $0.id == trip.id }
        )
        #expect(reloadedTrip.title == "Updated Trip")
        #expect(reloadedTrip.description == "Updated description")
        #expect(reloadedTrip.startLocalDay == "2026-06-18")
        #expect(reloadedTrip.endLocalDay == "2026-06-22")
    }

    @Test func updateGallerySettingsPersistsOnActiveBlog() throws {
        let fixture = try JournalFixture()
        let blogID = try #require(fixture.service.blogID)

        try fixture.service.updateGalleryInterval(seconds: 1_200)
        try fixture.service.updateGalleryDistance(meters: 750.5)

        let blog = try fixture.database.read { db in
            try Blog.find(db, key: blogID)
        }
        #expect(blog.galleryIntervalSeconds == 1_200)
        #expect(blog.galleryDistanceMeters == 750.5)
        #expect(blog.updatedAt == fixture.now)
    }

    @Test func gallerySettingsDoNotRegroupExistingGallery() throws {
        let fixture = try JournalFixture()
        let before = try fixture.database.read { db in
            let gallery = try #require(try Gallery.fetchOne(db))
            let dayItem = try #require(
                try DayItem.where { $0.galleryID.eq(gallery.id) }.fetchOne(db)
            )
            return try BlogItemPlacement
                .where { $0.dayItemID.eq(dayItem.id) }
                .order { $0.position }
                .fetchAll(db)
                .map(\.blogItemID)
        }

        try fixture.service.updateGalleryDistance(meters: 1)
        try fixture.service.updateGalleryInterval(seconds: 120)
        let after = try #require(try fixture.service.loadCurrentTrip())
            .days
            .flatMap(\.entries)
            .compactMap { entry -> GalleryDisplay? in
                guard case .gallery(let gallery) = entry else { return nil }
                return gallery
            }
            .first?
            .items
            .map(\.id)
        #expect(after == before)
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
            startLocalDay: "2027-01-16",
            endLocalDay: nil
        )

        let trip = try #require(try fixture.service.loadCurrentTrip())
        #expect(trip.id == id)
        #expect(trip.title == "new trip")
        #expect(trip.description.isEmpty)
        #expect(trip.startLocalDay == "2027-01-16")
        #expect(trip.endLocalDay == nil)
    }

    @Test func createTripRejectsSecondOpenTrip() throws {
        let fixture = try JournalFixture()

        #expect(throws: JournalServiceError.multipleOpenTrips) {
            try fixture.service.createTrip(
                title: "Another open trip",
                description: "",
                startLocalDay: "2026-07-01",
                endLocalDay: nil
            )
        }
    }

    @Test func createTripRejectsOverlappingDates() throws {
        let fixture = try JournalFixture()
        try fixture.service.endTrip(id: try #require(try fixture.service.loadCurrentTrip()).id)

        #expect(throws: JournalServiceError.overlapsAnotherTrip) {
            try fixture.service.createTrip(
                title: "Overlapping trip",
                description: "",
                startLocalDay: "2026-06-20",
                endLocalDay: "2026-06-21"
            )
        }
    }

    @Test func updateTripDetailsRejectsOverlappingDates() throws {
        let fixture = try JournalFixture()
        let currentTrip = try #require(try fixture.service.loadCurrentTrip())
        try fixture.service.endTrip(id: currentTrip.id)
        let otherTripID = try fixture.service.createTrip(
            title: "May trip",
            description: "",
            startLocalDay: "2026-05-01",
            endLocalDay: "2026-05-31"
        )

        #expect(throws: JournalServiceError.overlapsAnotherTrip) {
            try fixture.service.updateTripDetails(
                id: otherTripID,
                title: "May trip",
                description: "",
                startLocalDay: "2026-06-19",
                endLocalDay: "2026-06-20"
            )
        }
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

    @Test func updateBlogItemMovesDirectEntryOutsideTripRange() throws {
        let fixture = try JournalFixture()
        let directItem = try fixture.database.read { db in
            let dayItem = try #require(
                try DayItem.where { $0.galleryID.is(nil) }.fetchOne(db)
            )
            let placement = try #require(
                try BlogItemPlacement.where { $0.dayItemID.eq(dayItem.id) }.fetchOne(db)
            )
            return try BlogItem.find(db, key: placement.blogItemID)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        let dateBeforeTrip = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))
        )

        try fixture.service.updateBlogItem(
            id: directItem.id,
            caption: directItem.caption ?? "",
            date: dateBeforeTrip,
            location: directItem.locationName ?? "",
            temperatureCelsius: directItem.weatherTemperatureCelsius ?? 0,
            weatherCondition: directItem.weatherConditionCode ?? ""
        )

        let trips = try fixture.service.loadTrips()
        let unassigned = try #require(trips.first { $0.isUnassigned })
        let currentTrip = try #require(trips.first { $0.isCurrent })
        #expect(
            unassigned.days
                .flatMap(\.entries)
                .flatMap(\.blogItems)
                .contains(where: { $0.id == directItem.id })
        )
        #expect(
            !currentTrip.days
                .flatMap(\.entries)
                .flatMap(\.blogItems)
                .contains(where: { $0.id == directItem.id })
        )
        #expect(unassigned.days.contains(where: { $0.localDay == "2026-06-01" }))
    }

    @Test func updateBlogItemPersistsNormalizedTemperature() throws {
        let fixture = try JournalFixture()
        let originalTrip = try #require(try fixture.service.loadCurrentTrip())
        let originalItem = try #require(originalTrip.days.flatMap(\.entries).flatMap(\.blogItems).first)

        try fixture.service.updateBlogItem(
            id: originalItem.id,
            caption: originalItem.caption,
            date: originalItem.date,
            location: originalItem.location,
            temperatureCelsius: 18.26,
            weatherCondition: originalItem.weather.conditionCode ?? ""
        )

        let persistedItem = try fixture.database.read { db in
            try #require(try BlogItem.find(db, key: originalItem.id))
        }
        #expect(persistedItem.weatherTemperatureCelsius == 18.5)
    }

    @Test func updateBlogItemTimeReordersDirectEntriesWithinDay() throws {
        let fixture = try JournalFixture()
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        let morning = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 9))
        )
        let midday = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 12))
        )
        let afternoon = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 20, hour: 15))
        )
        let firstID = try fixture.service.createPhotoBlogItem(
            caption: "First direct item",
            date: morning,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )
        let secondID = try fixture.service.createPhotoBlogItem(
            caption: "Second direct item",
            date: midday,
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        try fixture.service.updateBlogItem(
            id: firstID,
            caption: "First direct item",
            date: afternoon,
            location: "",
            temperatureCelsius: 0,
            weatherCondition: ""
        )

        let day = try #require(
            try fixture.service.loadCurrentTrip()?
                .days
                .first(where: { $0.localDay == "2026-06-20" })
        )
        let editedIDs = day.entries
            .flatMap(\.blogItems)
            .map(\.id)
            .filter { $0 == firstID || $0 == secondID }
        #expect(editedIDs == [secondID, firstID])
    }

    @Test func updateBlogItemRefreshesHistoricalWeatherWhenDateChanges() async throws {
        let probe = HistoricalWeatherProbe()
        let fixture = try JournalFixture(
            weatherProvider: TrackingWeatherProvider(
                probe: probe,
                capture: WeatherCapture(
                    latitude: 51.5,
                    longitude: -0.12,
                    temperatureCelsius: 7,
                    conditionCode: "rain"
                )
            )
        )
        let originalTrip = try #require(try fixture.service.loadCurrentTrip())
        let originalItem = try #require(
            originalTrip.days.flatMap(\.entries).flatMap(\.blogItems).first {
                $0.latitude != nil && $0.longitude != nil
            }
        )
        let originalLatitude = try #require(originalItem.latitude)
        let originalLongitude = try #require(originalItem.longitude)
        let newDate = originalItem.date.addingTimeInterval(3_600)

        try fixture.service.updateBlogItem(
            BlogItemUpdateRequest(
                id: originalItem.id,
                caption: originalItem.caption,
                date: newDate,
                location: originalItem.location,
                temperatureCelsius: originalItem.weather.temperatureCelsius ?? 0,
                weatherCondition: originalItem.weather.conditionCode
            )
        )

        let request = await probe.waitForHistoricalWeatherRequest()
        #expect(request.date == newDate)
        #expect(request.location.latitude == originalLatitude)
        #expect(request.location.longitude == originalLongitude)

        let refreshedItem = try await fixture.waitForBlogItem(id: originalItem.id) {
            $0.weatherConditionCode == "rain"
        }
        #expect(refreshedItem.weatherTemperatureCelsius == 7)
        #expect(refreshedItem.locationName == originalItem.location)
    }

    @Test func updateBlogItemRefreshesHistoricalWeatherWhenLocationChanges() async throws {
        let probe = HistoricalWeatherProbe()
        let fixture = try JournalFixture(
            weatherProvider: TrackingWeatherProvider(
                probe: probe,
                capture: WeatherCapture(
                    latitude: 40.6892,
                    longitude: -74.0445,
                    temperatureCelsius: 12,
                    conditionCode: "cloudy"
                )
            )
        )
        let originalTrip = try #require(try fixture.service.loadCurrentTrip())
        let originalItem = try #require(originalTrip.days.flatMap(\.entries).flatMap(\.blogItems).first)
        let updatedLatitude = 40.6892
        let updatedLongitude = -74.0445
        let updatedLocation = "Liberty Island"

        try fixture.service.updateBlogItem(
            BlogItemUpdateRequest(
                id: originalItem.id,
                caption: originalItem.caption,
                date: originalItem.date,
                location: updatedLocation,
                latitude: updatedLatitude,
                longitude: updatedLongitude,
                temperatureCelsius: originalItem.weather.temperatureCelsius ?? 0,
                weatherCondition: originalItem.weather.conditionCode
            )
        )

        let request = await probe.waitForHistoricalWeatherRequest()
        #expect(request.date == originalItem.date)
        #expect(request.location == WeatherLocation(latitude: updatedLatitude, longitude: updatedLongitude))

        let refreshedItem = try await fixture.waitForBlogItem(id: originalItem.id) {
            $0.weatherConditionCode == "cloudy"
        }
        #expect(refreshedItem.weatherTemperatureCelsius == 12)
        #expect(refreshedItem.latitude == updatedLatitude)
        #expect(refreshedItem.longitude == updatedLongitude)
        #expect(refreshedItem.locationName == updatedLocation)
    }

    @Test func updateBlogItemCanReplaceAndRemovePhoto() throws {
        let fixture = try JournalFixture()
        let originalTrip = try #require(try fixture.service.loadCurrentTrip())
        let originalItem = try #require(
            originalTrip.days.flatMap(\.entries).flatMap(\.blogItems).first { $0.localImagePath != nil }
        )
        let replacementData = try #require(Data(base64Encoded: Self.onePixelPNGBase64))

        try fixture.service.updateBlogItem(
            BlogItemUpdateRequest(
                id: originalItem.id,
                caption: originalItem.caption,
                date: originalItem.date,
                location: originalItem.location,
                temperatureCelsius: originalItem.weather.temperatureCelsius ?? 0,
                weatherCondition: originalItem.weather.condition,
                photoChange: .replaced(
                    BlogItemPhotoAssetDraft(
                        imageData: replacementData,
                        mimeType: "image/png",
                        pixelWidth: 1,
                        pixelHeight: 1
                    )
                )
            )
        )

        let replacedState = try fixture.database.read { db in
            let item = try BlogItem.find(db, key: originalItem.id)
            let mediaID = try #require(item.photoAssetID)
            return (item, try MediaAsset.find(db, key: mediaID))
        }
        #expect(replacedState.1.mimeType == "image/png")
        #expect(replacedState.1.filename.hasSuffix(".png"))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.mediaURL.appendingPathComponent(replacedState.1.filename).path
            )
        )

        try fixture.service.updateBlogItem(
            BlogItemUpdateRequest(
                id: originalItem.id,
                caption: originalItem.caption,
                date: originalItem.date,
                location: originalItem.location,
                temperatureCelsius: originalItem.weather.temperatureCelsius ?? 0,
                weatherCondition: originalItem.weather.condition,
                photoChange: .removed
            )
        )

        let removedPhotoAssetID = try fixture.database.read { db in
            try BlogItem.find(db, key: originalItem.id).photoAssetID
        }
        #expect(removedPhotoAssetID == nil)
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

    @Test func deletingLastGalleryItemDeletesGallery() throws {
        let fixture = try JournalFixture()
        let sourceGallery = try fixture.database.read { db in
            try #require(try Gallery.fetchOne(db))
        }
        let itemID = try fixture.database.read { db in
            let dayItem = try #require(
                try DayItem.where { $0.galleryID.eq(sourceGallery.id) }.fetchOne(db)
            )
            return try #require(
                try BlogItemPlacement.where { $0.dayItemID.eq(dayItem.id) }.fetchOne(db)
            ).blogItemID
        }
        let destinationGalleryID = try fixture.service.createGallery(
            title: "Named Gallery",
            description: "A gallery that should be removed when its last item is deleted.",
            placementDate: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "Europe/London"
        )
        try fixture.service.moveBlogItems([itemID], toGallery: destinationGalleryID)

        try fixture.service.deleteBlogItem(id: itemID)

        try fixture.database.read { db in
            #expect(try BlogItem.find(db, key: itemID).deletedAt != nil)
            #expect(try Gallery.find(db, key: destinationGalleryID).deletedAt != nil)
            let dayItem = try DayItem
                .where { $0.galleryID.eq(destinationGalleryID) }
                .fetchOne(db)
            #expect(dayItem?.deletedAt != nil)
        }
    }

    @Test func deleteTripOnlySoftDeletesTripAndLeavesEntriesUnassigned() throws {
        let fixture = try JournalFixture()
        let trip = try #require(try fixture.service.loadCurrentTrip())
        let originalItems = trip.days.flatMap(\.entries).flatMap(\.blogItems)

        try fixture.service.deleteTrip(id: trip.id, includingEntries: false)

        #expect(try fixture.service.loadCurrentTrip() == nil)
        let trips = try fixture.service.loadTrips()
        let unassigned = try #require(trips.first)
        #expect(unassigned.isUnassigned)
        #expect(!trips.contains(where: { $0.id == trip.id }))
        let unassignedItems = unassigned.days.flatMap(\.entries).flatMap(\.blogItems)
        #expect(unassignedItems.map(\.id) == originalItems.map(\.id))
    }

    @Test func deleteTripAndEntriesSoftDeletesBoth() throws {
        let fixture = try JournalFixture()
        let trip = try #require(try fixture.service.loadCurrentTrip())
        let originalItems = trip.days.flatMap(\.entries).flatMap(\.blogItems)

        try fixture.service.deleteTrip(id: trip.id, includingEntries: true)

        #expect(try fixture.service.loadCurrentTrip() == nil)
        #expect(try fixture.service.loadTrips().isEmpty)
        try fixture.database.read { db in
            let deletedTrip = try Trip.find(db, key: trip.id)
            #expect(deletedTrip.deletedAt == fixture.now)
            for item in originalItems {
                let deletedItem = try BlogItem.find(db, key: item.id)
                #expect(deletedItem.deletedAt == fixture.now)
            }
        }
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
            photoLibraryAssetIdentifier: "A1B2C3",
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
            let item = try BlogItem.find(db, key: createdID)
            let mediaID = try #require(item.photoAssetID)
            return (try MediaAsset.find(db, key: mediaID), item.authorID)
        }
        #expect(storedMedia.0.photoLibraryAssetIdentifier == "A1B2C3")
        #expect(storedMedia.0.photoLibraryAssetUploaderID == storedMedia.1)
        #expect(storedMedia.0.contentHash != nil)
        #expect(storedMedia.0.localOriginalPath == storedMedia.0.filename)
        let expectedHash = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(storedMedia.0.contentHash == expectedHash)
        #expect(storedMedia.0.filename == "\(expectedHash).jpg")
    }

    @Test func createTextBlogItemPersistsWithoutMedia() throws {
        let fixture = try JournalFixture()
        let newDate = Date(timeIntervalSince1970: 1_782_300_000)

        let createdID = try fixture.service.createTextBlogItem(
            caption: "A new text-only post",
            date: newDate,
            timeZoneIdentifier: "Europe/London"
        )

        let reloadedTrip = try #require(try fixture.service.loadCurrentTrip())
        let latestEntry = try #require(reloadedTrip.days.last?.entries.last)
        let latestItem = try #require(latestEntry.blogItems.first)

        #expect(latestItem.id == createdID)
        #expect(latestItem.caption == "A new text-only post")
        #expect(latestItem.date == newDate)
        #expect(latestItem.hasPhoto == false)
        #expect(latestItem.localImagePath == nil)
        let storedPhotoAssetID = try fixture.database.read { db in
            try BlogItem.find(db, key: createdID).photoAssetID
        }
        #expect(storedPhotoAssetID == nil)
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
        let contentHash = try fixture.database.read { db in
            try #require(MediaAsset.find(db, key: mediaID).contentHash)
        }
        if let originalPath {
            try FileManager.default.removeItem(
                at: fixture.mediaURL.appendingPathComponent(originalPath)
            )
        }
        try fixture.database.write { db in
            try MediaAsset.find(mediaID).update {
                $0.localOriginalPath = #bind(nil)
                $0.cloudAssetIdentifier = #bind("remote-object")
                $0.cloudAssetHash = #bind(contentHash)
            }.execute(db)
        }

        let trip = try #require(try fixture.service.loadCurrentTrip())
        let item = try #require(trip.days.flatMap(\.entries).flatMap(\.blogItems).last)
        #expect(item.hasPhoto)
        #expect(item.photoAvailability == .downloading)
        #expect(item.localImagePath == nil)
        #expect(item.syncStatus == .pending)

        try FileManager.default.createDirectory(
            at: fixture.mediaURL,
            withIntermediateDirectories: true
        )
        try imageData.write(
            to: fixture.mediaURL.appendingPathComponent("\(contentHash).jpg")
        )

        let refreshedTrip = try #require(try fixture.service.loadCurrentTrip())
        let refreshedItem = try #require(
            refreshedTrip.days.flatMap(\.entries).flatMap(\.blogItems).last
        )
        #expect(refreshedItem.photoAvailability == .available)
        #expect(refreshedItem.localImagePath?.hasSuffix("\(contentHash).jpg") == true)
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
        #expect(item.hasPhoto)
        #expect(item.photoAvailability == .unavailable)
        #expect(item.localImagePath == nil)
        #expect(item.syncStatus == .failed)
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
        let stagedFilesBefore = try FileManager.default.contentsOfDirectory(
            at: fixture.mediaURL,
            includingPropertiesForKeys: nil
        )
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
        #expect(stagedFiles == stagedFilesBefore)
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

    @Test func loadTripsRecoversPhotoFromCurrentContainerWhenStoredPathIsStale() throws {
        let fixture = try JournalFixture(now: { Date(timeIntervalSince1970: 1_782_300_000) })
        let imageData = try #require(Data(base64Encoded: Self.onePixelJPEGBase64))
        let itemID = try fixture.service.createPhotoBlogItem(
            caption: "Migrated photo",
            date: Date(timeIntervalSince1970: 1_782_300_000),
            timeZoneIdentifier: "Europe/London",
            imageData: imageData,
            mimeType: "image/jpeg",
            pixelWidth: 1,
            pixelHeight: 1
        )

        let expectedPath = try fixture.database.write { db -> String in
            let item = try BlogItem.find(db, key: itemID)
            let mediaID = try #require(item.photoAssetID)
            let media = try MediaAsset.find(db, key: mediaID)
            let filename = try #require(media.localOriginalPath)
            try MediaAsset.find(mediaID)
                .update {
                    $0.localOriginalPath = #bind(
                        "/private/var/mobile/Containers/Data/Application/OLD/Library/Application Support/BlogItemMedia/\(filename)"
                    )
                }
                .execute(db)
            return fixture.mediaURL.appendingPathComponent(filename).path
        }

        let trip = try #require(try fixture.service.loadCurrentTrip())
        let migratedItem = try #require(
            trip.days
                .flatMap(\.entries)
                .flatMap(\.blogItems)
                .first { $0.id == itemID }
        )
        #expect(migratedItem.localImagePath == expectedPath)
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

    static let onePixelJPEGBase64 = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAkGBxAQEBUQEBAVFRUVFRUVFRUVFRUVFRUVFRUWFhUVFRUYHSggGBolHRUVITEhJSkrLi4uFx8zODMsNygtLisBCgoKDg0OGxAQGyslICYtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLf/AABEIAAEAAQMBIgACEQEDEQH/xAAXAAEBAQEAAAAAAAAAAAAAAAAAAQID/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEAMQAAAB6A//xAAWEAEBAQAAAAAAAAAAAAAAAAABABH/2gAIAQEAAT8Aqf/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQIBAT8Af//EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQMBAT8Af//Z"
    private static let onePixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0uoAAAAASUVORK5CYII="
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
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        let seededMedia = try database.read { db in
            try MediaAsset.fetchAll(db)
        }
        let seededImageData = try #require(
            Data(base64Encoded: JournalServiceTests.onePixelJPEGBase64)
        )
        for media in seededMedia {
            try seededImageData.write(
                to: mediaURL.appendingPathComponent(media.filename),
                options: Data.WritingOptions.atomic
            )
        }
        try database.write { db in
            let firstItem = try BlogItem.order { ($0.itemDate, $0.id) }.fetchOne(db)
            if let firstItem {
                try BlogItem.find(firstItem.id)
                    .update {
                        $0.latitude = #bind(43.9493)
                        $0.longitude = #bind(4.8055)
                    }
                    .execute(db)
            }
            for media in seededMedia {
                try MediaAsset.find(media.id)
                    .update {
                        $0.localOriginalPath = #bind(media.filename)
                        $0.pixelWidth = #bind(1)
                        $0.pixelHeight = #bind(1)
                    }
                    .execute(db)
            }
        }
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
                    heroImageAssetID: nil,
                    createdAt: now,
                    updatedAt: now,
                    closedAt: now,
                    deletedAt: nil
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

    func waitForBlogItem(
        id: BlogItem.ID,
        timeoutNanoseconds: UInt64 = 500_000_000,
        until predicate: @escaping (BlogItem) -> Bool
    ) async throws -> BlogItem {
        let clock = ContinuousClock()
        let deadline = clock.now + .nanoseconds(Int(timeoutNanoseconds))
        while clock.now < deadline {
            if let item = try await database.read({ db in try BlogItem.find(id).fetchOne(db) }),
               predicate(item) {
                return item
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        throw JournalFixtureError.timeout
    }
}

private enum JournalFixtureError: Error {
    case missingBlog
    case timeout
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

private actor HistoricalWeatherProbe {
    private var continuation: CheckedContinuation<(location: WeatherLocation, date: Date), Never>?
    private var latestRequest: (location: WeatherLocation, date: Date)?

    func record(location: WeatherLocation, date: Date) {
        latestRequest = (location, date)
        continuation?.resume(returning: (location, date))
        continuation = nil
    }

    func waitForHistoricalWeatherRequest() async -> (location: WeatherLocation, date: Date) {
        if let latestRequest {
            return latestRequest
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private struct TrackingWeatherProvider: WeatherProviding {
    let probe: HistoricalWeatherProbe
    let capture: WeatherCapture

    func currentWeather(for location: WeatherLocation) async throws -> WeatherCapture {
        capture
    }

    func weather(for location: WeatherLocation, near date: Date) async throws -> WeatherCapture? {
        await probe.record(location: location, date: date)
        return capture
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
