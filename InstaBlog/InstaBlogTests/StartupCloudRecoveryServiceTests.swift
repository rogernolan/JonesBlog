import GRDB
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Startup CloudKit recovery")
struct StartupCloudRecoveryServiceTests {
    @Test func emptyDatabaseRecoversCloudDataBeforeBootstrap() async throws {
        let database = try AppDatabase.makeInMemory()
        let calls = StartupRecoveryCallRecorder()
        let operations = StartupCloudRecoveryOperations(
            start: {
                await calls.recordStart()
            },
            synchronize: {
                await calls.recordSynchronization()
                _ = try BlogBootstrapService(database: database).bootstrap()
                try await database.write { db in
                    try AppBlogIdentity.all.delete().execute(db)
                    try AppWorkspace.find(AppWorkspace.singletonID)
                        .update { $0.activeBlogID = #bind(nil) }
                        .execute(db)
                }
            },
            stop: {
                await calls.recordStop()
            }
        )

        let recovered = try await StartupCloudRecoveryService(
            database: database,
            operations: operations
        ).recoverIfNeeded()
        let workspace = try BlogBootstrapService(database: database).bootstrap()

        #expect(recovered)
        #expect(try await database.read(Blog.fetchCount) == 1)
        #expect(try await database.read(Blogger.fetchCount) == 1)
        #expect(try await database.read(MailingList.fetchCount) == 1)
        #expect(try await database.read { db in
            try AppWorkspace.find(AppWorkspace.singletonID).fetchOne(db)?.activeBlogID
        } == workspace.blog.id)
        #expect(await calls.values() == (starts: 1, synchronizations: 1, stops: 1))
    }

    @Test func existingLocalBlogSkipsCloudRecovery() async throws {
        let database = try AppDatabase.makeInMemory()
        _ = try BlogBootstrapService(database: database).bootstrap()
        let calls = StartupRecoveryCallRecorder()
        let operations = StartupCloudRecoveryOperations(
            start: { await calls.recordStart() },
            synchronize: { await calls.recordSynchronization() },
            stop: { await calls.recordStop() }
        )

        let recovered = try await StartupCloudRecoveryService(
            database: database,
            operations: operations
        ).recoverIfNeeded()

        #expect(!recovered)
        #expect(await calls.values() == (starts: 0, synchronizations: 0, stops: 0))
    }
}

private actor StartupRecoveryCallRecorder {
    private var starts = 0
    private var synchronizations = 0
    private var stops = 0

    func recordStart() {
        starts += 1
    }

    func recordSynchronization() {
        synchronizations += 1
    }

    func recordStop() {
        stops += 1
    }

    func values() -> (starts: Int, synchronizations: Int, stops: Int) {
        (starts, synchronizations, stops)
    }
}
