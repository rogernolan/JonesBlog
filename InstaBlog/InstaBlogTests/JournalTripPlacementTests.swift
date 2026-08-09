import Foundation
import Testing
@testable import InstaBlog

struct JournalTripPlacementTests {
    @Test
    func openTripContainsItsDayRange() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: nil,
            days: []
        )

        #expect(TripDisplay.tripContaining(localDay: "2027-06-01", in: [trip]) == trip)
        #expect(TripDisplay.tripContaining(localDay: "2027-12-31", in: [trip]) == trip)
    }

    @Test
    func closedTripContainsOnlyItsDayRange() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: "2027-06-14",
            days: []
        )

        #expect(TripDisplay.tripContaining(localDay: "2027-06-01", in: [trip]) == trip)
        #expect(TripDisplay.tripContaining(localDay: "2027-06-14", in: [trip]) == trip)
        #expect(TripDisplay.tripContaining(localDay: "2027-05-31", in: [trip]) == nil)
        #expect(TripDisplay.tripContaining(localDay: "2027-06-15", in: [trip]) == nil)
    }

    @Test
    func unassignedTripsDoNotMatchEntries() {
        let open = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: nil,
            days: []
        )
        let unassigned = TripDisplay.emptyUnassigned

        #expect(TripDisplay.tripContaining(localDay: "2027-05-01", in: [open, unassigned]) == nil)
        #expect(TripDisplay.tripContaining(localDay: "2027-06-02", in: [open, unassigned]) == open)
    }

    @Test
    func unassignedDisplayIsNeverTreatedAsAContainingTrip() {
        let unassigned = TripDisplay.emptyUnassigned

        #expect(TripDisplay.tripContaining(localDay: "2027-06-01", in: [unassigned]) == nil)
        #expect(JournalTripPlacement.resolve(localDay: "2027-06-01", in: [unassigned]) == .unassigned)
    }

    @Test
    func resolveUsesEarliestPhotoMetadataMatchingPersistence() {
        let closed = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: "2027-06-14",
            days: []
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let editedOutsideTrip = utc.date(
            from: DateComponents(year: 2027, month: 7, day: 1, hour: 2)
        )!
        let earliestPhotoInsideTrip = utc.date(
            from: DateComponents(year: 2027, month: 6, day: 10, hour: 2)
        )!
        let photo = BlogItemPhotoAssetDraft(
            imageData: Data(),
            mimeType: "image/jpeg",
            photoLibraryAssetIdentifier: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            photoDate: earliestPhotoInsideTrip,
            timeZoneIdentifier: "UTC"
        )

        #expect(
            JournalTripPlacement.resolve(
                date: editedOutsideTrip,
                timeZoneIdentifier: "UTC",
                photos: [photo],
                in: [closed]
            ) == .closedTrip(closed)
        )
    }

    @Test
    func resolveFallsBackToEditedDateWithoutPhotos() {
        let closed = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: "2027-06-14",
            days: []
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let outsideTrip = utc.date(from: DateComponents(year: 2027, month: 7, day: 1, hour: 2))!

        #expect(
            JournalTripPlacement.resolve(
                date: outsideTrip,
                timeZoneIdentifier: "UTC",
                photos: [],
                in: [closed]
            ) == .unassigned
        )
    }

    @Test
    func resolveClassifiesOpenTripDayAsOpen() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: nil,
            days: []
        )

        #expect(JournalTripPlacement.resolve(localDay: "2027-06-01", in: [trip]) == .openTrip(trip))
    }

    @Test
    func resolveClassifiesClosedTripDayAsClosed() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: "2027-06-14",
            days: []
        )

        #expect(JournalTripPlacement.resolve(localDay: "2027-06-10", in: [trip]) == .closedTrip(trip))
    }

    @Test
    func resolveClassifiesDaysOutsideAnyTripAsUnassigned() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: "2027-06-14",
            days: []
        )

        #expect(JournalTripPlacement.resolve(localDay: "2027-05-01", in: [trip]) == .unassigned)
        #expect(JournalTripPlacement.resolve(localDay: "2027-07-01", in: [trip]) == .unassigned)
        #expect(JournalTripPlacement.resolve(localDay: "2027-06-01", in: []) == .unassigned)
    }

    @Test
    func resolveUsesTheSuppliedTimeZoneForTheLocalDay() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-01-15",
            endLocalDay: "2027-01-15",
            days: []
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 2))!

        let inUtc = JournalTripPlacement.resolve(
            date: instant,
            timeZoneIdentifier: "UTC",
            in: [trip]
        )
        let inHonolulu = JournalTripPlacement.resolve(
            date: instant,
            timeZoneIdentifier: "Pacific/Honolulu",
            in: [trip]
        )

        #expect(inUtc == .closedTrip(trip))
        #expect(inHonolulu == .unassigned)
    }

    @Test
    func entrySavedNoticeUsesTripTitleOrUnassignedMessage() {
        let open = TripDisplay(
            title: "Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: nil,
            days: []
        )
        let closed = TripDisplay(
            title: "J&R Trip to Scotland",
            startLocalDay: "2027-06-01",
            endLocalDay: "2027-06-14",
            days: []
        )

        #expect(JournalNotice.entrySaved(placement: .openTrip(open)) == nil)
        #expect(
            JournalNotice.entrySaved(placement: .closedTrip(closed))
                == JournalNotice(title: "Entry Saved", message: "New entry saved to J&R Trip to Scotland")
        )
        #expect(
            JournalNotice.entrySaved(placement: .unassigned)
                == JournalNotice(title: "Entry Saved", message: "New entry not assigned to any trip")
        )
    }
}
