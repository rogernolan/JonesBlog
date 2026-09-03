import Foundation
import GRDB
import ImageIO
import SQLiteData
import Testing
import UniformTypeIdentifiers
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
                "localJournalAdoptions", "localJournalBloggerMappings", "localJournalItemMappings",
                "localJournalMediaMappings", "localJournalPhotoMappings",
                "mailingLists", "mediaAssets", "photoItems", "publishEvents", "subscribers", "trips",
            ])
            #expect(!tables.contains("galleries"))
            #expect(!tables.contains("dayItems"))
            #expect(!tables.contains("blogItemPlacements"))

            let blogItemColumns = try db.columns(in: "blogItems").map(\.name)
            #expect(blogItemColumns.contains("blogText"))
            #expect(blogItemColumns.contains("lastEditorID"))
            #expect(blogItemColumns.contains("lastEditedAt"))
            #expect(blogItemColumns.contains("altitude"))
            #expect(blogItemColumns.contains("showElevation"))
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
            "003 Repair photo dimensions for EXIF orientation",
            "004 Add local journal adoption ledger",
            "005 Add blog item altitude",
            "006 Add blog item elevation visibility",
            "007 Repair missing media transfer state",
            "008 Repair empty active workspace",
        ])
    }

    @Test func emptyActiveWorkspaceSelectsPopulatedBlog() throws {
        let database = try AppDatabase.makeInMemory()
        let populatedBlogID = UUID()
        let emptyBlogID = UUID()
        let authorID = UUID()

        try database.write { db in
            try Blog.insert {
                Blog.Draft(id: populatedBlogID, createdAt: .now, updatedAt: .now)
            }.execute(db)
            try Blog.insert {
                Blog.Draft(id: emptyBlogID, createdAt: .now, updatedAt: .now)
            }.execute(db)
            try Blogger.insert {
                Blogger.Draft(
                    id: authorID,
                    blogID: populatedBlogID,
                    displayName: "Jane",
                    createdAt: .now,
                    updatedAt: .now
                )
            }.execute(db)
            try BlogItem.insert {
                BlogItem.Draft(
                    id: UUID(),
                    blogID: populatedBlogID,
                    authorID: authorID,
                    blogText: "Recovered post",
                    createdAt: .now,
                    updatedAt: .now,
                    itemDate: .now,
                    localDay: "2026-09-03"
                )
            }.execute(db)
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(emptyBlogID) }
                .execute(db)

            try AppDatabase.repairEmptyActiveWorkspace(in: db)

            let workspace = try AppWorkspace.find(AppWorkspace.singletonID).fetchOne(db)
            #expect(workspace?.activeBlogID == populatedBlogID)
        }
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

    @Test func localDatabaseIsPhysicallySeparateAndHasNoCloudKitMetadatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let database = try AppDatabase.makeLocalLive(in: root)
        #expect(database.path == root.appendingPathComponent(AppDatabase.localFilename).path)
        #expect(try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA database_list")
                .contains { $0["name"] as String? == "sqlitedata_icloud_metadata" } == false
        })
        #expect(AppDatabase.localMediaDirectory(in: root) != AppDatabase.cloudMediaDirectory(in: root))
    }

    @Test func deliveredCloudRootQualifiesForCachedCloudSelection() throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()

        #expect(try AppDatabase.hasValidCachedCloudRoot(
            in: database,
            wasDelivered: { blog, _ in blog.id == workspace.blog.id },
            isShared: { _, _ in false }
        ))
    }

    @Test func localOrIncompleteCloudRootsDoNotQualifyAsCachedCloudJournal() throws {
        let database = try AppDatabase.makeInMemory()
        _ = try BlogBootstrapService(database: database).bootstrap()

        #expect(try !AppDatabase.hasValidCachedCloudRoot(
            in: database,
            wasDelivered: { _, _ in false },
            isShared: { _, _ in false }
        ))
    }

    @Test func cachedCloudRootPrefersAnAcceptedSharedBlogAfterCloudFetch() throws {
        let database = try AppDatabase.makeInMemory()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let privateBlogID = UUID()
        let sharedBlogID = UUID()
        try database.write { db in
            try Blog.insert {
                Blog.Draft(id: privateBlogID, title: "Private", createdAt: date, updatedAt: date)
            }.execute(db)
            try Blog.insert {
                Blog.Draft(
                    id: sharedBlogID,
                    title: "Shared",
                    createdAt: date.addingTimeInterval(1),
                    updatedAt: date.addingTimeInterval(1)
                )
            }.execute(db)
        }

        let root = try AppDatabase.cachedCloudRoot(
            in: database,
            wasDelivered: { _, _ in true },
            isShared: { blog, _ in blog.id == sharedBlogID }
        )
        #expect(root?.id == sharedBlogID)
    }

    @Test func storeSelectionUsesLocalJournalUnlessCloudCacheIsValid() throws {
        let root = temporaryRoot(named: "StoreSelection")
        let fileManager = TemporaryApplicationSupportFileManager(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let localStore = try AppWorkspaceStore.openLive(fileManager: fileManager)
        #expect(localStore.kind == .local)
        #expect(localStore.database.path == root.appendingPathComponent(AppDatabase.localFilename).path)
        try localStore.database.close()

        let cloudStore = try AppWorkspaceStore.openLive(
            fileManager: fileManager,
            cloudCacheIsValid: { _ in true }
        )
        #expect(cloudStore.kind == .cloud)
        #expect(cloudStore.database.path == root.appendingPathComponent(AppDatabase.cloudFilename).path)
        try cloudStore.database.close()
    }

    @Test func unadoptedLocalEntriesKeepTheLocalJournalSelected() throws {
        let root = temporaryRoot(named: "UnadoptedLocalJournal")
        let fileManager = TemporaryApplicationSupportFileManager(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let localDatabase = try AppDatabase.makeLocalLive(in: root)
        let localWorkspace = try BlogBootstrapService(database: localDatabase).bootstrap()
        try localDatabase.write { db in
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: localWorkspace.blog.id,
                    authorID: localWorkspace.blogger.id,
                    blogText: "Keep this local post visible",
                    createdAt: .now,
                    updatedAt: .now,
                    itemDate: .now,
                    localDay: "2026-08-10"
                )
            }.execute(db)
        }
        try localDatabase.close()

        let store = try AppWorkspaceStore.openLive(
            fileManager: fileManager,
            cloudCacheIsValid: { _ in true },
            localJournalNeedsAdoption: { _, _, _ in true }
        )
        #expect(store.kind == .local)
        #expect(store.database.path == root.appendingPathComponent(AppDatabase.localFilename).path)
        try store.database.close()
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

    @Test func bootstrapPreparesTheSelectedWorkspaceInsteadOfTheOldestCachedBlog() throws {
        let database = try AppDatabase.makeInMemory()
        let first = try BlogBootstrapService(database: database).bootstrap()
        let selectedBlogID = UUID()
        let selectedBloggerID = UUID()
        let selectedMailingListID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try database.write { db in
            try Blog.insert {
                Blog.Draft(id: selectedBlogID, title: "Received journal", createdAt: date, updatedAt: date)
            }.execute(db)
            try Blogger.insert {
                Blogger.Draft(
                    id: selectedBloggerID,
                    blogID: selectedBlogID,
                    displayName: "Received Blogger",
                    createdAt: date,
                    updatedAt: date
                )
            }.execute(db)
            try MailingList.insert {
                MailingList.Draft(
                    id: selectedMailingListID,
                    blogID: selectedBlogID,
                    createdAt: date,
                    updatedAt: date
                )
            }.execute(db)
            try AppBlogIdentity.insert {
                AppBlogIdentity.Draft(blogID: selectedBlogID, bloggerID: selectedBloggerID)
            }.execute(db)
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(selectedBlogID) }
                .execute(db)
        }

        guard case .ready(let prepared) = try BlogBootstrapService(database: database).prepare() else {
            Issue.record("Expected selected workspace to be ready")
            return
        }
        #expect(prepared.blog.id == selectedBlogID)
        #expect(prepared.blogger.id == selectedBloggerID)
        #expect(prepared.mailingList.id == selectedMailingListID)
        #expect(prepared.blog.id != first.blog.id)
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

    @Test func photoDimensionRepairMigrationReorientsRawCameraDims() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-OrientationRepair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let database = try DatabaseQueue(path: root.appendingPathComponent("InstaBlog.sqlite").path)
        try AppDatabase.migrator.migrate(database, upTo: "002 Add blog item edit metadata")

        let mediaDirectory = root.appendingPathComponent("BlogItemMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let imageURL = mediaDirectory.appendingPathComponent("photo.jpg")
        try makeOrientedJPEG(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 6)
            .write(to: imageURL)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let assetID: MediaAsset.ID = try database.write { db in
            guard let blog = try (Blog.insert { Blog.Draft(createdAt: now, updatedAt: now) }
                .returning(\.self)
                .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            guard let asset = try (MediaAsset.insert {
                    MediaAsset.Draft(
                        blogID: blog.id,
                        filename: "photo.jpg",
                        mimeType: "image/jpeg",
                        pixelWidth: 4_032,
                        pixelHeight: 3_024,
                        createdAt: now,
                        updatedAt: now
                    )
                }
                .returning(\.self)
                .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            return asset.id
        }

        try AppDatabase.migrator.migrate(database)

        try database.read { db in
            let asset = try MediaAsset.find(db, key: assetID)
            #expect(asset.pixelWidth == 3_024)
            #expect(asset.pixelHeight == 4_032)
        }
    }

    @Test func mediaTransferRepairMigrationRequeuesMissingRemoteOriginal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-MediaRepair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let database = try DatabaseQueue(path: root.appendingPathComponent("InstaBlog.sqlite").path)
        try AppDatabase.migrator.migrate(database, upTo: "006 Add blog item elevation visibility")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let assetID: MediaAsset.ID = try database.write { db in
            guard let blog = try (Blog.insert { Blog.Draft(createdAt: now, updatedAt: now) }
                .returning(\.self)
                .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            guard let asset = try (MediaAsset.insert {
                MediaAsset.Draft(
                    blogID: blog.id,
                    localOriginalPath: "old.jpg",
                    cloudAssetIdentifier: "remote-object",
                    contentHash: "content-hash",
                    cloudAssetHash: "content-hash",
                    filename: "content-hash.jpg",
                    mimeType: "image/jpeg",
                    createdAt: now,
                    updatedAt: now
                )
            }
            .returning(\.self)
            .fetchOne(db))
            else { throw AppDatabaseTestError.missingInsertedRecord }
            return asset.id
        }

        try AppDatabase.migrator.migrate(database)

        try database.read { db in
            let asset = try MediaAsset.find(db, key: assetID)
            #expect(asset.localOriginalPath == nil)
            #expect(asset.cloudAssetIdentifier == "remote-object")
            #expect(asset.contentHash == "content-hash")
            #expect(asset.cloudAssetHash == nil)
            #expect(asset.cloudAssetSyncError == nil)
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

    private func makeOrientedJPEG(rawWidth: Int, rawHeight: Int, exifOrientation: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: rawWidth,
                  height: rawHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage()
        else { throw AppDatabaseTestError.failedToEncodeJPEG }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw AppDatabaseTestError.failedToEncodeJPEG }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: exifOrientation]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppDatabaseTestError.failedToEncodeJPEG }
        return encoded as Data
    }
}

private enum AppDatabaseTestError: Error {
    case missingInsertedRecord
    case failedToEncodeJPEG
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
