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
    static let filename = "InstaBlog.sqlite"

    static func makeLive(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        let applicationSupportDirectory = try applicationSupportDirectory(fileManager: fileManager)
        return try makeLive(in: applicationSupportDirectory)
    }

    static func makeLive(in applicationSupportDirectory: URL) throws -> any DatabaseWriter {
        let database = try DatabasePool(
            path: applicationSupportDirectory.appendingPathComponent(filename).path,
            configuration: configuration
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
        let databaseURL = applicationSupportDirectory.appendingPathComponent(filename)
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

    static func makeInMemory() throws -> any DatabaseWriter {
        let database = try DatabaseQueue(configuration: configuration)
        try migrator.migrate(database)
        return database
    }

    static func makeTesting(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("InstaBlogTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try DatabasePool(
            path: directory.appendingPathComponent("InstaBlog.sqlite").path,
            configuration: configuration
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
            let mediaDirectory = databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("BlogItemMedia", isDirectory: true)
            try repairUnorientedMediaDimensions(in: db, mediaDirectory: mediaDirectory)
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

    private static var configuration: Configuration {
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
