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
        await Task.detached { [started] in
            started.wait()
        }.value
    }

    func resume() {
        resumed.signal()
    }
}
