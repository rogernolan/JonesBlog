import CloudKit
import Foundation
import GRDB
import SQLiteData

nonisolated enum AppCloudKitConfiguration {
    static let containerIdentifier: String? = "iCloud.com.jonesthevan.blog.InstaBlog"
    static let defaultZoneName = "co.pointfree.SQLiteData.defaultZone"
    static var defaultZone: CKRecordZone { CKRecordZone(zoneName: defaultZoneName) }
}

nonisolated enum SharingServiceAvailability {
    static func isEnabled(containerIdentifier: String?, isUITesting: Bool) -> Bool {
        !isUITesting && containerIdentifier != nil
    }
}

nonisolated enum AppDatabase {
    static let cloudFilename = "InstaBlog.sqlite"
    static let localFilename = "LocalInstaBlog.sqlite"

    static func makeLive(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        try makeCloudLive(fileManager: fileManager)
    }

    static func makeLive(in applicationSupportDirectory: URL) throws -> any DatabaseWriter {
        try makeCloudLive(in: applicationSupportDirectory)
    }

    static func makeCloudLive(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        let applicationSupportDirectory = try applicationSupportDirectory(fileManager: fileManager)
        return try makeCloudLive(in: applicationSupportDirectory)
    }

    static func makeCloudLive(in applicationSupportDirectory: URL) throws -> any DatabaseWriter {
        let database = try DatabasePool(
            path: applicationSupportDirectory.appendingPathComponent(cloudFilename).path,
            configuration: cloudConfiguration
        )
        try migrator.migrate(database)
        return database
    }

    static func makeLocalLive(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        let applicationSupportDirectory = try applicationSupportDirectory(fileManager: fileManager)
        return try makeLocalLive(in: applicationSupportDirectory)
    }

    static func makeLocalLive(in applicationSupportDirectory: URL) throws -> any DatabaseWriter {
        let database = try DatabasePool(
            path: applicationSupportDirectory.appendingPathComponent(localFilename).path,
            configuration: localConfiguration
        )
        try migrator.migrate(database)
        return database
    }

    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func liveDatabaseURLs(in applicationSupportDirectory: URL) -> [URL] {
        let databaseURL = applicationSupportDirectory.appendingPathComponent(cloudFilename)
        let metadataURL = applicationSupportDirectory
            .appendingPathComponent(".InstaBlog")
            .appendingPathExtension(
                "metadata-"
                    + (AppCloudKitConfiguration.containerIdentifier ?? "container")
                    + ".sqlite"
            )
        return [databaseURL, metadataURL].flatMap { url in
            [url, URL(fileURLWithPath: url.path + "-shm"), URL(fileURLWithPath: url.path + "-wal")]
        }
    }

    static func discardCloudCache(in applicationSupportDirectory: URL, fileManager: FileManager = .default) throws {
        for url in liveDatabaseURLs(in: applicationSupportDirectory) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    static func makeInMemory() throws -> any DatabaseWriter {
        let database = try DatabaseQueue(configuration: cloudConfiguration)
        try migrator.migrate(database)
        return database
    }

    static func makeLocalInMemory() throws -> any DatabaseWriter {
        let database = try DatabaseQueue(configuration: localConfiguration)
        try migrator.migrate(database)
        return database
    }

    static func makeTesting(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("InstaBlogTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(
            path: directory.appendingPathComponent("InstaBlog.sqlite").path,
            configuration: cloudConfiguration
        )
        try migrator.migrate(database)
        return database
    }

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("001 Create multi-photo persistence schema") { db in
            try createSchema(in: db)
        }
        migrator.registerMigration("002 Add blog item edit metadata") { db in
            try db.execute(sql: "ALTER TABLE blogItems ADD COLUMN lastEditorID TEXT")
            try db.execute(sql: "ALTER TABLE blogItems ADD COLUMN lastEditedAt TEXT")
        }
        migrator.registerMigration("003 Repair photo dimensions for EXIF orientation") { db in
            let mainDatabasePath = try Row.fetchAll(db, sql: "PRAGMA database_list")
                .first { $0["name"] as String? == "main" }
                .flatMap { $0["file"] as String? }
            guard let mainDatabasePath, !mainDatabasePath.isEmpty else { return }
            let databaseURL = URL(fileURLWithPath: mainDatabasePath)
            let mediaDirectoryName = databaseURL.lastPathComponent == localFilename
                ? "LocalBlogItemMedia"
                : "BlogItemMedia"
            let mediaDirectory = databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent(mediaDirectoryName, isDirectory: true)
            try repairUnorientedMediaDimensions(in: db, mediaDirectory: mediaDirectory)
        }
        migrator.registerMigration("004 Add local journal adoption ledger") { db in
            try db.execute(sql: """
                CREATE TABLE localJournalAdoptions (
                  destinationBlogID TEXT PRIMARY KEY NOT NULL,
                  adoptedAt TEXT NOT NULL
                ) STRICT;
                CREATE TABLE localJournalBloggerMappings (
                  sourceBloggerID TEXT PRIMARY KEY NOT NULL,
                  destinationBloggerID TEXT NOT NULL
                ) STRICT;
                CREATE TABLE localJournalItemMappings (
                  sourceItemID TEXT PRIMARY KEY NOT NULL,
                  destinationItemID TEXT NOT NULL
                ) STRICT;
                CREATE TABLE localJournalMediaMappings (
                  sourceMediaID TEXT PRIMARY KEY NOT NULL,
                  destinationMediaID TEXT NOT NULL
                ) STRICT;
                CREATE TABLE localJournalPhotoMappings (
                  sourcePhotoID TEXT PRIMARY KEY NOT NULL,
                  destinationPhotoID TEXT NOT NULL
                ) STRICT;
                """)
        }
        return migrator
    }()

    /// Rewrites persisted photo dimensions so they describe the image once its
    /// EXIF orientation is applied, matching how the app decodes and displays
    /// photos. Earlier versions stored the raw sensor dimensions, so portrait
    /// camera shots were recorded as landscape and given landscape filmstrip
    /// frames.
    static func repairUnorientedMediaDimensions(in db: Database, mediaDirectory: URL) throws {
        for asset in try MediaAsset.fetchAll(db) {
            let url = MediaStoragePaths.canonicalURL(for: asset, in: mediaDirectory)
            guard let oriented = OrientedImageDimensions.orientedDimensions(of: url),
                  oriented.width != asset.pixelWidth || oriented.height != asset.pixelHeight
            else { continue }
            try MediaAsset.find(asset.id).update {
                $0.pixelWidth = #bind(oriented.width)
                $0.pixelHeight = #bind(oriented.height)
                $0.updatedAt = #bind(Date())
            }.execute(db)
        }
    }

    static func hasValidCachedCloudRoot(
        in database: any DatabaseReader,
        wasDelivered: (Blog, Database) throws -> Bool = wasDeliveredByCloudKit,
        isShared: (Blog, Database) throws -> Bool = isSharedCloudKitBlog
    ) throws -> Bool {
        try cachedCloudRoot(
            in: database,
            wasDelivered: wasDelivered,
            isShared: isShared
        ) != nil
    }

    static func cachedCloudRoot(
        in database: any DatabaseReader,
        wasDelivered: (Blog, Database) throws -> Bool = wasDeliveredByCloudKit,
        isShared: (Blog, Database) throws -> Bool = isSharedCloudKitBlog
    ) throws -> Blog? {
        try database.read { db in
            let deliveredBlogs = try Blog.order(by: { ($0.createdAt, $0.id) })
                .fetchAll(db)
                .filter { try wasDelivered($0, db) }
            return try deliveredBlogs.first { try isShared($0, db) } ?? deliveredBlogs.first
        }
    }

    private static func wasDeliveredByCloudKit(_ blog: Blog, db: Database) throws -> Bool {
        try SyncMetadata
            .find(blog.syncMetadataID)
            .select(\.hasLastKnownServerRecord)
            .fetchOne(db) ?? false
    }

    private static func isSharedCloudKitBlog(_ blog: Blog, db: Database) throws -> Bool {
        try SyncMetadata.find(blog.syncMetadataID).select(\.share).fetchOne(db) != nil
    }

    static func localMediaDirectory(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent("LocalBlogItemMedia", isDirectory: true)
    }

    static func cloudMediaDirectory(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent("BlogItemMedia", isDirectory: true)
    }

    private static var cloudConfiguration: Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.attachMetadatabase(
                containerIdentifier: AppCloudKitConfiguration.containerIdentifier
            )
            db.add(function: $uuid)
        }
        return configuration
    }

    private static var localConfiguration: Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: $uuid)
        }
        return configuration
    }

    private static func createSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE blogs (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              title TEXT NOT NULL DEFAULT 'My Blog',
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            ) STRICT;

            CREATE TABLE bloggers (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              displayName TEXT NOT NULL DEFAULT 'Me',
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              cloudKitParticipantIdentifier TEXT
            ) STRICT;

            CREATE TABLE blogItems (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              authorID TEXT NOT NULL,
              blogText TEXT,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              itemDate TEXT NOT NULL,
              itemTimeZoneIdentifier TEXT,
              localDay TEXT NOT NULL,
              latitude REAL,
              longitude REAL,
              locationName TEXT,
              countryCode TEXT,
              weatherTemperatureCelsius REAL,
              weatherConditionCode TEXT,
              deletedAt TEXT
            ) STRICT;

            CREATE TABLE mediaAssets (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              kind TEXT NOT NULL DEFAULT 'photo' CHECK (kind = 'photo'),
              localOriginalPath TEXT,
              photoLibraryAssetIdentifier TEXT,
              photoLibraryAssetUploaderID TEXT,
              cloudAssetIdentifier TEXT,
              contentHash TEXT,
              cloudAssetHash TEXT,
              cloudAssetSyncError TEXT,
              filename TEXT NOT NULL,
              mimeType TEXT NOT NULL,
              pixelWidth INTEGER,
              pixelHeight INTEGER,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            ) STRICT;

            CREATE TABLE photoItems (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              blogItemID TEXT NOT NULL,
              mediaAssetID TEXT NOT NULL,
              photoCaption TEXT,
              photoDate TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            ) STRICT;

            CREATE TABLE trips (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              title TEXT NOT NULL,
              description TEXT NOT NULL,
              startLocalDay TEXT NOT NULL,
              endLocalDay TEXT,
              heroImageAssetID TEXT,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              closedAt TEXT,
              deletedAt TEXT
            ) STRICT;

            CREATE TABLE mailingLists (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              name TEXT NOT NULL DEFAULT 'Subscribers',
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            ) STRICT;

            CREATE TABLE subscribers (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              mailingListID TEXT NOT NULL,
              emailAddress TEXT NOT NULL,
              displayName TEXT,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            ) STRICT;

            CREATE TABLE publishEvents (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              tripID TEXT,
              localDay TEXT NOT NULL,
              mailingListID TEXT NOT NULL,
              initiatedAt TEXT NOT NULL,
              initiatedByBloggerID TEXT NOT NULL,
              recipientCount INTEGER NOT NULL
            ) STRICT;

            CREATE TABLE appWorkspaces (
              id TEXT PRIMARY KEY NOT NULL CHECK (id = 'default'),
              activeBlogID TEXT
            ) STRICT;

            CREATE TABLE appBlogIdentities (
              blogID TEXT PRIMARY KEY NOT NULL,
              bloggerID TEXT NOT NULL
            ) STRICT;

            INSERT INTO appWorkspaces (id, activeBlogID)
              VALUES ('default', NULL);

            CREATE INDEX blogItems_blogID_localDay_itemDate
              ON blogItems (blogID, localDay, itemDate);
            CREATE INDEX blogItems_blogID_itemDate
              ON blogItems (blogID, itemDate);
            CREATE INDEX blogItems_authorID
              ON blogItems (authorID);
            CREATE INDEX photoItems_blogItemID_photoDate_createdAt_id
              ON photoItems (blogItemID, photoDate, createdAt, id);
            CREATE INDEX photoItems_mediaAssetID
              ON photoItems (mediaAssetID);
            CREATE INDEX photoItems_blogID
              ON photoItems (blogID);
            CREATE INDEX trips_blogID_startLocalDay_endLocalDay
              ON trips (blogID, startLocalDay, endLocalDay);
            CREATE INDEX mailingLists_blogID
              ON mailingLists (blogID);
            CREATE INDEX subscribers_mailingListID_emailAddress
              ON subscribers (mailingListID, emailAddress);
            CREATE INDEX publishEvents_blogID_localDay
              ON publishEvents (blogID, localDay);
            CREATE INDEX publishEvents_mailingListID_initiatedAt
              ON publishEvents (mailingListID, initiatedAt);
            CREATE INDEX mediaAssets_blogID
              ON mediaAssets (blogID);
            """)
    }

}

nonisolated struct AppPersistence: Sendable {
    let database: any DatabaseWriter
    let syncEngine: SyncEngine
    let synchronizationGate: CloudSynchronizationGate

    init(
        database: any DatabaseWriter,
        containerIdentifier: String? = AppCloudKitConfiguration.containerIdentifier,
        defaultZone: CKRecordZone = AppCloudKitConfiguration.defaultZone,
        startImmediately: Bool? = nil
    ) throws {
        self.database = database
        self.synchronizationGate = CloudSynchronizationGate()
        self.syncEngine = try SyncEngine(
            for: database,
            tables: Blog.self,
            Blogger.self,
            BlogItem.self,
            PhotoItem.self,
            MediaAsset.self,
            Trip.self,
            MailingList.self,
            Subscriber.self,
            PublishEvent.self,
            containerIdentifier: containerIdentifier,
            defaultZone: defaultZone,
            startImmediately: startImmediately
        )
    }

    static func makeLive(fileManager: FileManager = .default) throws -> Self {
        try Self(database: AppDatabase.makeLive(fileManager: fileManager))
    }

    static func makeTesting(fileManager: FileManager = .default) throws -> Self {
        try Self(database: AppDatabase.makeTesting(fileManager: fileManager))
    }
}

nonisolated struct AppWorkspaceStore: Sendable {
    enum Kind: Sendable, Equatable {
        case local
        case cloud
    }

    let kind: Kind
    let database: any DatabaseWriter
    let mediaDirectoryURL: URL?

    var supportsCloudSynchronization: Bool {
        kind == .cloud
    }

    static func openLive(fileManager: FileManager = .default) throws -> Self {
        try openLive(
            fileManager: fileManager,
            cloudCacheIsValid: { try AppDatabase.hasValidCachedCloudRoot(in: $0) }
        )
    }

    static func openLive(
        fileManager: FileManager = .default,
        cloudCacheIsValid: (any DatabaseReader) throws -> Bool
    ) throws -> Self {
        try openLive(
            fileManager: fileManager,
            cloudCacheIsValid: cloudCacheIsValid,
            localJournalNeedsAdoption: localJournalNeedsAdoption
        )
    }

    static func openLive(
        fileManager: FileManager = .default,
        cloudCacheIsValid: (any DatabaseReader) throws -> Bool,
        localJournalNeedsAdoption: (any DatabaseReader, URL, FileManager) throws -> Bool
    ) throws -> Self {
        let applicationSupportDirectory = try AppDatabase.applicationSupportDirectory(fileManager: fileManager)
        let cloudDatabase = try AppDatabase.makeCloudLive(in: applicationSupportDirectory)
        var closesCloudDatabase = true
        defer {
            if closesCloudDatabase {
                try? cloudDatabase.close()
            }
        }
        if try cloudCacheIsValid(cloudDatabase) {
            if try localJournalNeedsAdoption(cloudDatabase, applicationSupportDirectory, fileManager) {
                try cloudDatabase.close()
                closesCloudDatabase = false
                return Self(
                    kind: .local,
                    database: try AppDatabase.makeLocalLive(in: applicationSupportDirectory),
                    mediaDirectoryURL: AppDatabase.localMediaDirectory(in: applicationSupportDirectory)
                )
            }
            closesCloudDatabase = false
            return Self(
                kind: .cloud,
                database: cloudDatabase,
                mediaDirectoryURL: AppDatabase.cloudMediaDirectory(in: applicationSupportDirectory)
            )
        }
        try AppDatabase.discardCloudCache(in: applicationSupportDirectory, fileManager: fileManager)
        return Self(
            kind: .local,
            database: try AppDatabase.makeLocalLive(in: applicationSupportDirectory),
            mediaDirectoryURL: AppDatabase.localMediaDirectory(in: applicationSupportDirectory)
        )
    }

    static func makeTesting() throws -> Self {
        Self(kind: .local, database: try AppDatabase.makeLocalInMemory(), mediaDirectoryURL: nil)
    }

    private static func localJournalNeedsAdoption(
        cloudDatabase: any DatabaseReader,
        applicationSupportDirectory: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let localDatabaseURL = applicationSupportDirectory.appendingPathComponent(AppDatabase.localFilename)
        guard fileManager.fileExists(atPath: localDatabaseURL.path) else { return false }
        let cloudRootID = try AppDatabase.cachedCloudRoot(in: cloudDatabase)?.id
        guard let cloudRootID else { return false }

        let localDatabase = try AppDatabase.makeLocalLive(in: applicationSupportDirectory)
        defer { try? localDatabase.close() }
        return try localDatabase.read { db in
            guard try BlogItem.fetchCount(db) > 0 else { return false }
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM localJournalAdoptions WHERE destinationBlogID = ?)",
                arguments: [cloudRootID.uuidString]
            ) == false
        }
    }
}

actor CloudSynchronizationGate {
    private var tail: (id: UUID, completion: Task<Void, Never>)?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let predecessor = tail?.completion
        let operationTask = Task {
            if let predecessor {
                await predecessor.value
            }
            try await operation()
        }
        let operationID = UUID()
        let completion = Task {
            _ = try? await operationTask.value
        }
        tail = (operationID, completion)

        do {
            try await operationTask.value
            clearTail(ifMatching: operationID)
        } catch {
            clearTail(ifMatching: operationID)
            throw error
        }
    }

    private func clearTail(ifMatching operationID: UUID) {
        if tail?.id == operationID {
            tail = nil
        }
    }
}

@DatabaseFunction
nonisolated private func uuid() -> UUID {
    UUID()
}
