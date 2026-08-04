import Foundation
import GRDB
import SQLiteData
import Testing

@testable import InstaBlog

@Suite("App data reset")
struct AppDataResetServiceTests {
    @Test func localResetRemovesOnlyDatabaseMetadataAndMedia() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppDataResetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let databaseURLs = AppDatabase.liveDatabaseURLs(in: rootURL)
        for url in databaseURLs {
            try Data([0x01]).write(to: url)
        }
        let mediaURL = rootURL.appendingPathComponent("BlogItemMedia", isDirectory: true)
        try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try Data([0x02]).write(to: mediaURL.appendingPathComponent("photo.jpg"))
        let unrelatedURL = rootURL.appendingPathComponent("KeepMe.txt")
        try Data([0x03]).write(to: unrelatedURL)

        try AppDataResetService(fileManager: fileManager).eraseLocalData(in: rootURL)

        #expect(databaseURLs.allSatisfy { !fileManager.fileExists(atPath: $0.path) })
        #expect(!fileManager.fileExists(atPath: mediaURL.path))
        #expect(fileManager.fileExists(atPath: unrelatedURL.path))
    }

    @Test func closedDatabaseResetDoesNotLeakOldWorkspaceIntoReplacement() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("AppDataResetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let originalDatabase = try AppDatabase.makeLive(in: rootURL)
        let originalWorkspace = try BlogBootstrapService(database: originalDatabase).bootstrap()
        try originalDatabase.close()

        let resetService = AppDataResetService(fileManager: fileManager)
        try resetService.eraseLocalData(in: rootURL)

        let replacementDatabase = try AppDatabase.makeLive(in: rootURL)
        let replacementWorkspace = try BlogBootstrapService(database: replacementDatabase).bootstrap()
        let replacementState = try await replacementDatabase.read { db in
            (
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.all.fetchAll(db)
            )
        }
        try replacementDatabase.close()

        #expect(replacementWorkspace.blog.id != originalWorkspace.blog.id)
        #expect(replacementState.0.activeBlogID == replacementWorkspace.blog.id)
        #expect(replacementState.1 == [
            AppBlogIdentity(
                blogID: replacementWorkspace.blog.id,
                bloggerID: replacementWorkspace.blogger.id
            )
        ])
    }

    @Test func pausedSyncEngineTracksBootstrapRecordsBeforeSynchronization() async throws {
        let persistence = try AppPersistence.makeTesting()
        let database = persistence.database

        _ = try BlogBootstrapService(database: database).bootstrap()

        let trackedRecordTypes = try await database.read { db in
            try SyncMetadata.all.fetchAll(db).map(\.recordType).sorted()
        }
        persistence.syncEngine.stop()

        #expect(trackedRecordTypes == ["bloggers", "blogs", "mailingLists"])
    }
}
