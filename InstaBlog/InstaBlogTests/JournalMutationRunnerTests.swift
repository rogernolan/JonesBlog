import Foundation
import Testing
@testable import InstaBlog

struct JournalMutationRunnerTests {
    @Test
    func mutationOperationRunsAwayFromMainThread() async throws {
        let ranOnMainThread = ThreadSafeFlag()

        _ = try await JournalMutationRunner.run {
            ranOnMainThread.value = Thread.isMainThread
        }

        #expect(ranOnMainThread.value == false)
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
