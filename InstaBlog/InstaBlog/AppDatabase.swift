import Foundation
import GRDB
import SQLiteData

nonisolated enum AppCloudKitConfiguration {
    static let containerIdentifier: String? = "iCloud.com.jonesthevan.blog.InstaBlog"
}

nonisolated enum SharingServiceAvailability {
    static func isEnabled(containerIdentifier: String?, isUITesting: Bool) -> Bool {
        !isUITesting && containerIdentifier != nil
    }
}

nonisolated enum AppDatabase {
    static func makeLive(fileManager: FileManager = .default) throws -> any DatabaseWriter {
        let applicationSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let database = try DatabasePool(
            path: applicationSupportDirectory.appendingPathComponent("InstaBlog.sqlite").path,
            configuration: configuration
        )
        try migrator.migrate(database)
        return database
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
        return migrator
    }()

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

    init(
        database: any DatabaseWriter,
        containerIdentifier: String? = AppCloudKitConfiguration.containerIdentifier
    ) throws {
        self.database = database
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
            containerIdentifier: containerIdentifier
        )
    }

    static func makeLive(fileManager: FileManager = .default) throws -> Self {
        try Self(database: AppDatabase.makeLive(fileManager: fileManager))
    }

    static func makeTesting(fileManager: FileManager = .default) throws -> Self {
        try Self(database: AppDatabase.makeTesting(fileManager: fileManager))
    }
}

@DatabaseFunction
nonisolated private func uuid() -> UUID {
    UUID()
}
