import Foundation
import Testing
@testable import InstaBlog

@Suite("Photo library import scheduling")
struct PhotoLibraryImportSchedulerTests {
    @Test func limitsConcurrentWorkAndPreservesSelectionOrder() async {
        let tracker = ImportWorkTracker()

        let batch = await PhotoLibraryImportScheduler.process(
            [0, 1, 2, 3, 4],
            maximumConcurrentOperations: 2
        ) { index in
            await tracker.started()
            try? await Task.sleep(for: .milliseconds(10 * (5 - index)))
            await tracker.finished()
            return index
        }

        #expect(await tracker.maximumInFlight == 2)
        #expect(batch.successes.map(\.value) == [0, 1, 2, 3, 4])
        #expect(batch.failures.isEmpty)
        #expect(!batch.wasCancelled)
    }

    @Test func reportsPartialFailuresWithoutDiscardingSuccessfulSelections() async {
        struct ExpectedFailure: Error {}

        let batch = await PhotoLibraryImportScheduler.process([0, 1, 2]) { index in
            if index == 1 { throw ExpectedFailure() }
            return index
        }

        #expect(batch.successes.map(\.value) == [0, 2])
        #expect(batch.failures.map(\.index) == [1])
        #expect(batch.failures.count == 1)
    }

    @Test func cancellationStopsSchedulingRetainedWork() async {
        let tracker = ImportWorkTracker()
        let task = Task {
            await PhotoLibraryImportScheduler.process(
                Array(0..<20),
                maximumConcurrentOperations: 2
            ) { index in
                await tracker.started()
                defer { Task { await tracker.finished() } }
                try await Task.sleep(for: .seconds(2))
                return index
            }
        }

        await tracker.waitUntilStarted(count: 2)
        task.cancel()
        let batch = await task.value

        #expect(batch.wasCancelled)
        #expect(await tracker.startedCount == 2)
    }
}

private actor ImportWorkTracker {
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var startedCount = 0

    func started() {
        inFlight += 1
        startedCount += 1
        maximumInFlight = max(maximumInFlight, inFlight)
    }

    func finished() {
        inFlight -= 1
    }

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await Task.yield()
        }
    }
}
