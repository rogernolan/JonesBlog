import Foundation
import GRDB
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("App database schema", .serialized)
struct AppDatabaseTests {
    @Test func createsOnlyTheFreshMultiPhotoSchema() throws {
        let database = try AppDatabase.makeInMemory()

        try database.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name"
            )
            #expect(tables == [
                "appBlogIdentities", "appWorkspaces", "blogItems", "bloggers", "blogs",
                "mailingLists", "mediaAssets", "photoItems", "publishEvents", "subscribers", "trips",
            ])
            #expect(!tables.contains("galleries"))
            #expect(!tables.contains("dayItems"))
            #expect(!tables.contains("blogItemPlacements"))

            let blogItemColumns = try db.columns(in: "blogItems").map(\.name)
            #expect(blogItemColumns.contains("blogText"))
            #expect(blogItemColumns.contains("lastEditorID"))
            #expect(blogItemColumns.contains("lastEditedAt"))
            #expect(!blogItemColumns.contains("caption"))
            #expect(!blogItemColumns.contains("photoAssetID"))

            #expect(try db.columns(in: "photoItems").map(\.name) == [
                "id", "blogID", "blogItemID", "mediaAssetID", "photoCaption",
                "photoDate", "createdAt", "updatedAt",
            ])
        }
    }

    @Test func schemaHasExpectedMigrations() throws {
        let database = try AppDatabase.makeInMemory()
        let migrations = try database.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(migrations == [
            "001 Create multi-photo persistence schema",
            "002 Add blog item edit metadata",
        ])
    }

    @Test func photoItemsCascadeWithTheirSharedBlogRoot() throws {
        let database = try AppDatabase.makeInMemory()
        let ids = try insertPhotoPost(into: database)

        try database.write { db in
            let item = try BlogItem.find(db, key: ids.blogItemID)
            try Blog.find(item.blogID).delete().execute(db)
        }

        try database.read { db in
            let photoCount = try PhotoItem.fetchCount(db)
            let assetCount = try MediaAsset.fetchCount(db)
            #expect(photoCount == 0)
            #expect(assetCount == 0)
        }
    }

    @Test func photoItemUsesOnlyTheBlogAsItsCloudKitParent() throws {
        let database = try AppDatabase.makeInMemory()
        let foreignKeys = try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(photoItems)")
        }
        #expect(foreignKeys.count == 1)
        #expect(foreignKeys[0]["table"] as String? == "blogs")
        #expect(foreignKeys[0]["from"] as String? == "blogID")
    }

    @Test func photoOrderingIndexMatchesTheDisplayRule() throws {
        let database = try AppDatabase.makeInMemory()
        let columns = try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_info(photoItems_blogItemID_photoDate_createdAt_id)")
                .compactMap { $0["name"] as String? }
        }
        #expect(columns == ["blogItemID", "photoDate", "createdAt", "id"])
    }

    @Test func liveDatabaseUsesApplicationSupportInstaBlogFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        let fileManager = TemporaryApplicationSupportFileManager(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try AppDatabase.makeLive(fileManager: fileManager)
        let expectedPath = root.appendingPathComponent("InstaBlog.sqlite").path

        #expect(database.path == expectedPath)
        #expect(FileManager.default.fileExists(atPath: expectedPath))
        #expect(try database.read { db in try db.tableExists("photoItems") })
    }

    @Test func successfulFirstLaunchThenDeletedMappedBloggerRequiresSelectionOnRelaunch() throws {
        let root = temporaryRoot(named: "DeletedMappedBlogger")
        let fileManager = TemporaryApplicationSupportFileManager(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstWorkspace: BootstrapWorkspace
        do {
            let database = try AppDatabase.makeLive(fileManager: fileManager)
            firstWorkspace = try BlogBootstrapService(database: database).bootstrap()
        }

        do {
            let database = try AppDatabase.makeLive(fileManager: fileManager)
            try database.write { db in
                try Blogger.find(firstWorkspace.blogger.id).delete().execute(db)
            }
        }

        do {
            let database = try AppDatabase.makeLive(fileManager: fileManager)
            let preparation = try BlogBootstrapService(database: database).prepare()
            guard case .bloggerSelectionRequired(let requirement) = preparation else {
                Issue.record("Expected relaunch to require selection after the mapped Blogger was deleted")
                return
            }
            #expect(requirement.blog.id == firstWorkspace.blog.id)
            #expect(requirement.bloggers.isEmpty)
            let identity = try database.read {
                try AppBlogIdentity.find($0, key: firstWorkspace.blog.id)
            }
            #expect(identity.bloggerID == firstWorkspace.blogger.id)
        }
    }

    @Test func createdTripSurvivesDatabaseCloseAndRelaunch() throws {
        let root = temporaryRoot(named: "TripRelaunch")
        let fileManager = TemporaryApplicationSupportFileManager(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let tripID: Trip.ID
        let firstWorkspace: BootstrapWorkspace
        do {
            let database = try AppDatabase.makeLive(fileManager: fileManager)
            firstWorkspace = try BlogBootstrapService(database: database, now: { now }).bootstrap()
            let service = journalService(
                database: database,
                workspace: firstWorkspace,
                root: root,
                now: now
            )
            tripID = try service.createTrip(
                title: "Persistent Trip",
                description: "Survives an app restart",
                startLocalDay: "2027-01-10",
                endLocalDay: "2027-01-20"
            )
            #expect(try service.loadTrips().contains { $0.id == tripID })
        }

        do {
            let database = try AppDatabase.makeLive(fileManager: fileManager)
            let reloadedWorkspace = try BlogBootstrapService(database: database, now: { now }).bootstrap()
            let service = journalService(
                database: database,
                workspace: reloadedWorkspace,
                root: root,
                now: now
            )
            let reloadedTrip = try #require(service.loadTrips().first { $0.id == tripID })

            #expect(reloadedWorkspace == firstWorkspace)
            #expect(reloadedTrip.title == "Persistent Trip")
            #expect(reloadedTrip.description == "Survives an app restart")
            #expect(reloadedTrip.startLocalDay == "2027-01-10")
            #expect(reloadedTrip.endLocalDay == "2027-01-20")
        }
    }

    private func temporaryRoot(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func journalService(
        database: any DatabaseWriter,
        workspace: BootstrapWorkspace,
        root: URL,
        now: Date
    ) -> JournalService {
        JournalService(
            database: database,
            now: { now },
            fileManager: FileManager.default,
            mediaDirectoryURL: root.appendingPathComponent("Media", isDirectory: true),
            mediaCacheDirectoryURL: root.appendingPathComponent("Cache", isDirectory: true),
            blogID: workspace.blog.id,
            bloggerID: workspace.blogger.id
        )
    }

    private func insertPhotoPost(
        into database: any DatabaseWriter
    ) throws -> (blogItemID: BlogItem.ID, mediaAssetID: MediaAsset.ID) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return try database.write { db in
            guard let blog = try (Blog.insert { Blog.Draft(createdAt: now, updatedAt: now) }
                .returning(\.self)
                .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            guard let blogger = try (Blogger.insert {
                    Blogger.Draft(blogID: blog.id, createdAt: now, updatedAt: now)
                }
                .returning(\.self)
                .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            guard let item = try (BlogItem.insert {
                    BlogItem.Draft(
                        blogID: blog.id,
                        authorID: blogger.id,
                        blogText: "Post",
                        createdAt: now,
                        updatedAt: now,
                        itemDate: now,
                        localDay: "2027-01-15"
                    )
                }
                .returning(\.self)
                .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            guard let asset = try (MediaAsset.insert {
                    MediaAsset.Draft(
                        blogID: blog.id,
                        filename: "photo.jpg",
                        mimeType: "image/jpeg",
                        createdAt: now,
                        updatedAt: now
                    )
                }
                .returning(\.self)
                .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            try PhotoItem.insert {
                PhotoItem.Draft(
                    blogID: blog.id,
                    blogItemID: item.id,
                    mediaAssetID: asset.id,
                    photoDate: now,
                    createdAt: now,
                    updatedAt: now
                )
            }
            .execute(db)
            return (item.id, asset.id)
        }
    }

}

private enum AppDatabaseTestError: Error {
    case missingInsertedRecord
}

private final class TemporaryApplicationSupportFileManager: FileManager, @unchecked Sendable {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func url(
        for directory: SearchPathDirectory,
        in domain: SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        if shouldCreate {
            try createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }
}
