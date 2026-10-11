import Foundation
import Testing
@testable import InstaBlog

@MainActor
struct JournalTripLoaderTests {
    @Test
    func combinedJournalKeepsDaysInReverseOrderWithoutCrossTripRoutes() {
        let earlierDay = DayPostDisplay(
            date: Date(timeIntervalSince1970: 1_000),
            localDay: "2026-06-01",
            route: ["Paris"],
            blogItems: []
        )
        let laterDay = DayPostDisplay(
            date: Date(timeIntervalSince1970: 2_000),
            localDay: "2026-07-01",
            route: ["Tokyo"],
            blogItems: []
        )
        let earlierTrip = TripDisplay(
            title: "Europe",
            startLocalDay: "2026-06-01",
            endLocalDay: "2026-06-01",
            days: [earlierDay]
        )
        let laterTrip = TripDisplay(
            title: "Japan",
            startLocalDay: "2026-07-01",
            endLocalDay: "2026-07-01",
            days: [laterDay]
        )

        let journal = TripDisplay.allEntries(from: [earlierTrip, laterTrip])

        #expect(journal.days.map(\.localDay) == ["2026-07-01", "2026-06-01"])
        #expect(journal.days.map(\.route) == [["Tokyo"], ["Paris"]])
    }

    @Test
    func delayedLoadPublishesTripsWhenItCompletes() async {
        let loader = JournalTripLoader()
        let gate = BlockingTripLoad()
        let trip = TripDisplay(title: "Loaded", startLocalDay: "2027-01-15", days: [])

        async let load: Void = loader.load(blogID: UUID()) {
            gate.block()
            return [trip]
        }
        await gate.waitUntilStarted()
        #expect(loader.trips.isEmpty)

        gate.resume()
        await load

        #expect(loader.trips == [trip])
    }

    @Test
    func initialCurrentTripLoadPublishesOnlyTheCurrentTrip() async {
        let loader = JournalTripLoader()
        let blogID = UUID()
        let currentTrip = TripDisplay(title: "Current", startLocalDay: "2027-01-15", days: [])

        await loader.loadCurrentTrip(blogID: blogID) { currentTrip }

        #expect(loader.blogID == blogID)
        #expect(loader.trips == [currentTrip])
        #expect(loader.failure == nil)
    }

    @Test
    func historicalJournalRemainsVisibleUntilReloadCompletes() async {
        let loader = JournalTripLoader()
        let blogID = UUID()
        let gate = BlockingTripLoad()
        let original = historicalTrip(localDay: "2026-06-01")
        let updated = historicalTrip(localDay: "2026-06-02")
        await loader.load(blogID: blogID) { [original] }

        async let reload: Void = loader.loadJournal(
            blogID: blogID,
            loadsAllTrips: true,
            currentTrip: { nil },
            allTrips: {
                gate.block()
                return [updated]
            }
        )
        await gate.waitUntilStarted()
        #expect(loader.isLoading)
        #expect(loader.trips == [original])
        #expect(loader.blogID == blogID)

        gate.resume()
        await reload

        #expect(loader.trips == [updated])
        #expect(!loader.isLoading)
    }

    @Test
    func failedFullJournalReloadKeepsHistoricalEntries() async {
        let loader = JournalTripLoader()
        let blogID = UUID()
        let original = historicalTrip(localDay: "2026-06-01")
        await loader.load(blogID: blogID) { [original] }

        await loader.loadJournal(
            blogID: blogID,
            loadsAllTrips: true,
            currentTrip: { nil },
            allTrips: { throw TestError.expected }
        )

        #expect(loader.trips == [original])
        #expect(loader.failure != nil)
        #expect(!loader.isLoading)
    }

    @Test
    func currentTripOnlyLoadDoesNotFetchFullHistory() async {
        let loader = JournalTripLoader()
        let trip = TripDisplay(title: "Current", startLocalDay: "2027-01-15", days: [])

        await loader.loadJournal(
            blogID: UUID(),
            loadsAllTrips: false,
            currentTrip: { trip },
            allTrips: {
                Issue.record("Current-trip loading must not fetch full history")
                return []
            }
        )

        #expect(loader.trips == [trip])
        #expect(!loader.isLoading)
    }

    @Test
    func cancelledReloadCannotReplaceVisibleHistoryWithEmptyData() async {
        let loader = JournalTripLoader()
        let blogID = UUID()
        let gate = BlockingTripLoad()
        let original = historicalTrip(localDay: "2026-06-01")
        await loader.load(blogID: blogID) { [original] }

        let reload = Task {
            await loader.loadCurrentTrip(blogID: blogID) {
                gate.block()
                return nil
            }
        }
        await gate.waitUntilStarted()
        reload.cancel()
        gate.resume()
        await reload.value

        #expect(loader.trips == [original])
        #expect(!loader.isLoading)
        #expect(loader.failure == nil)
    }

    @Test
    func initialCurrentTripLoadCompletesWhenThereIsNoOpenTrip() async {
        let loader = JournalTripLoader()
        let blogID = UUID()

        await loader.loadCurrentTrip(blogID: blogID) { nil }

        #expect(loader.blogID == blogID)
        #expect(loader.trips.isEmpty)
        #expect(loader.failure == nil)
    }

    @Test
    func staleWorkspaceCompletionCannotReplaceNewWorkspaceTrips() async {
        let loader = JournalTripLoader()
        let gate = BlockingTripLoad()
        let oldTrip = TripDisplay(title: "Old", startLocalDay: "2027-01-15", days: [])
        let newTrip = TripDisplay(title: "New", startLocalDay: "2027-01-16", days: [])

        async let oldLoad: Void = loader.load(blogID: UUID()) {
            gate.block()
            return [oldTrip]
        }
        await gate.waitUntilStarted()
        await loader.load(blogID: UUID()) { [newTrip] }

        gate.resume()
        await oldLoad

        #expect(loader.trips == [newTrip])
    }

    @Test
    func failedReloadPreservesPreviouslyLoadedTrips() async {
        let loader = JournalTripLoader()
        let trip = TripDisplay(title: "Loaded", startLocalDay: "2027-01-15", days: [])

        await loader.load(blogID: UUID()) { [trip] }
        await loader.load(blogID: UUID()) {
            throw TestError.expected
        }

        #expect(loader.trips == [trip])
    }

    @Test
    func failedInitialLoadPublishesFailureAndStopsLoading() async {
        var logs: [String] = []
        let loader = JournalTripLoader(logFailure: { logs.append($0) })
        let blogID = UUID()

        await loader.load(blogID: blogID) {
            throw TestError.expected
        }

        #expect(loader.isLoading == false)
        #expect(loader.failure?.title == "Could Not Load Journal")
        #expect(loader.blogID == nil)
        #expect(logs.count == 1)
    }

    @Test
    func successfulRetryClearsFailure() async {
        let loader = JournalTripLoader(logFailure: { _ in })
        let blogID = UUID()
        let trip = TripDisplay(title: "Recovered", startLocalDay: "2027-01-15", days: [])

        await loader.load(blogID: blogID) {
            throw TestError.expected
        }
        await loader.load(blogID: blogID) { [trip] }

        #expect(loader.failure == nil)
        #expect(loader.blogID == blogID)
        #expect(loader.trips == [trip])
    }

    @Test
    func unassignedLoadReplacesOnlyTheUnassignedTrip() async {
        let loader = JournalTripLoader()
        let formalTrip = TripDisplay(title: "Formal", startLocalDay: "2027-01-15", days: [])
        let oldUnassigned = TripDisplay.emptyUnassigned
        let refreshedUnassigned = TripDisplay(
            title: "Unassigned",
            startLocalDay: "2027-01-14",
            endLocalDay: "2027-01-14",
            days: []
        )
        await loader.load(blogID: UUID()) { [formalTrip, oldUnassigned] }

        await loader.loadUnassigned(blogID: UUID()) { refreshedUnassigned }

        #expect(loader.trips == [refreshedUnassigned, formalTrip])
        #expect(loader.isLoadingUnassigned == false)
    }

    @Test
    func fullAndUnassignedLoadsDoNotInvalidateEachOther() async {
        let loader = JournalTripLoader()
        let fullGate = BlockingTripLoad()
        let formalTrip = TripDisplay(title: "Formal", startLocalDay: "2027-01-15", days: [])
        let unassignedTrip = TripDisplay(
            title: "Unassigned",
            startLocalDay: "2027-01-14",
            endLocalDay: "2027-01-14",
            days: []
        )

        async let fullLoad: Void = loader.load(blogID: UUID()) {
            fullGate.block()
            return [formalTrip]
        }
        await fullGate.waitUntilStarted()

        await loader.loadUnassigned(blogID: UUID()) { unassignedTrip }
        fullGate.resume()
        await fullLoad

        #expect(loader.trips == [formalTrip])
        #expect(loader.isLoading == false)
        #expect(loader.isLoadingUnassigned == false)
    }

    @Test
    func failedUnassignedLoadPublishesFailureAndStopsLoading() async {
        var logs: [String] = []
        let loader = JournalTripLoader(logFailure: { logs.append($0) })

        await loader.loadUnassigned(blogID: UUID()) {
            throw TestError.expected
        }

        #expect(loader.isLoadingUnassigned == false)
        #expect(loader.unassignedFailure?.title == "Could Not Refresh Journal")
        #expect(logs.count == 1)
    }

    private func historicalTrip(localDay: String) -> TripDisplay {
        let date = Date(timeIntervalSince1970: 1_780_272_000)
        let item = BlogItemDisplay(
            author: "Rog",
            date: date,
            timeZoneIdentifier: "UTC",
            blogText: "An existing entry",
            location: "",
            weather: WeatherDisplay(),
            photos: []
        )
        return TripDisplay(
            title: "Historical",
            startLocalDay: localDay,
            endLocalDay: localDay,
            days: [DayPostDisplay(date: date, localDay: localDay, route: [], blogItems: [item])]
        )
    }
}

private enum TestError: Error {
    case expected
}

private final class BlockingTripLoad: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)

    func block() {
        started.signal()
        resumed.wait()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [started] in
                started.wait()
                continuation.resume()
            }
        }
    }

    func resume() {
        resumed.signal()
    }
}
