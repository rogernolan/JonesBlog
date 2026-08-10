import Foundation
import Network
import Observation
import SQLiteData

nonisolated enum ConnectivityMonitor {
    static func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "InstaBlog.ConnectivityMonitor"))
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }
}

nonisolated struct CloudJournalArrivalService {
    let database: any DatabaseWriter
    let syncEngine: SyncEngine

    /// Announces the first delivered root promptly, but does not select an adoption
    /// destination until the current fetch has settled. A private root may arrive
    /// before an accepted shared root in the same fetch.
    func synchronizeAndFindRoot(
        onFirstCachedRoot: @escaping @MainActor @Sendable () -> Void
    ) async throws -> Blog? {
        try await syncEngine.start()
        let completion = CloudSynchronizationCompletion()
        Task {
            do {
                try await syncEngine.syncChanges()
                await completion.finish(with: .success(()))
            } catch {
                await completion.finish(with: .failure(error))
            }
        }
        var announcedFirstRoot = false
        while !Task.isCancelled {
            if !announcedFirstRoot,
               try AppDatabase.hasValidCachedCloudRoot(in: database) {
                announcedFirstRoot = true
                await onFirstCachedRoot()
            }
            if let result = await completion.result {
                try result.get()
                return try AppDatabase.cachedCloudRoot(in: database)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

}

private actor CloudSynchronizationCompletion {
    private var storedResult: Result<Void, Error>?

    var result: Result<Void, Error>? { storedResult }

    func finish(with result: Result<Void, Error>) {
        storedResult = result
    }

}

@MainActor
@Observable
final class CloudJournalArrivalNotices {
    private(set) var notice: JournalNotice?
    private(set) var blockingFailure: JournalNotice?

    func present(_ notice: JournalNotice, telemetryData: [String: Any] = [:]) {
        var telemetryData = telemetryData
        telemetryData["notice_id"] = notice.id.uuidString
        telemetryData["notice_title"] = notice.title
        AppTelemetry.record(
            "Cloud journal toast presented",
            category: "cloud.adoption.notice",
            data: telemetryData
        )
        self.notice = notice
    }

    func dismissNotice(id: JournalNotice.ID) {
        guard notice?.id == id else { return }
        AppTelemetry.record(
            "Cloud journal toast dismissed",
            category: "cloud.adoption.notice",
            data: ["notice_id": id.uuidString]
        )
        notice = nil
    }

    func presentBlockingFailure(_ notice: JournalNotice) {
        AppTelemetry.record(
            "Cloud journal adoption failure presented",
            category: "cloud.adoption.notice",
            level: .error,
            data: [
                "notice_id": notice.id.uuidString,
                "notice_title": notice.title
            ]
        )
        blockingFailure = notice
    }
}
