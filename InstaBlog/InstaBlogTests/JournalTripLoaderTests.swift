import Foundation
import Testing
@testable import InstaBlog

@MainActor
struct JournalTripLoaderTests {
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
