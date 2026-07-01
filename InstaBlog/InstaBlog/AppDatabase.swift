import Foundation
import SQLiteData

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
        migrator.registerMigration("001 Create v1 persistence schema") { db in
            try createV1Schema(in: db)
        }
        migrator.registerMigration("002 Add sharing workspace and media data") { db in
            try addSharingWorkspaceAndMediaData(in: db)
        }
        migrator.registerMigration("003 Add private Blog identity mapping") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS appBlogIdentities (
                  blogID TEXT PRIMARY KEY NOT NULL,
                  bloggerID TEXT NOT NULL
                ) STRICT;
                """)
        }
        return migrator
    }()

    private static var configuration: Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.attachMetadatabase()
            db.add(function: $uuid)
        }
        return configuration
    }

    private static func createV1Schema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE blogs (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              title TEXT NOT NULL DEFAULT 'My Blog',
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              galleryIntervalSeconds INTEGER NOT NULL DEFAULT 900,
              galleryDistanceMeters REAL NOT NULL DEFAULT 500.0
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
              caption TEXT,
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
              photoAssetID TEXT,
              deletedAt TEXT,
              CHECK (
                photoAssetID IS NOT NULL
                OR length(trim(coalesce(caption, ''), char(9) || char(10) || char(11) || char(12) || char(13) || ' ')) > 0
              )
            ) STRICT;

            CREATE TABLE mediaAssets (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              kind TEXT NOT NULL DEFAULT 'photo' CHECK (kind = 'photo'),
              localOriginalPath TEXT,
              cloudAssetIdentifier TEXT,
              filename TEXT NOT NULL,
              mimeType TEXT NOT NULL,
              pixelWidth INTEGER,
              pixelHeight INTEGER,
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
              closedAt TEXT
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

            CREATE INDEX blogItems_blogID_localDay_itemDate
              ON blogItems (blogID, localDay, itemDate);
            CREATE INDEX blogItems_blogID_itemDate
              ON blogItems (blogID, itemDate);
            CREATE INDEX blogItems_authorID
              ON blogItems (authorID);
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

    private static func addSharingWorkspaceAndMediaData(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE mediaAssetData (
              mediaAssetID TEXT PRIMARY KEY NOT NULL REFERENCES mediaAssets(id) ON DELETE CASCADE,
              data BLOB NOT NULL
            ) STRICT;

            CREATE TABLE appWorkspaces (
              id TEXT PRIMARY KEY NOT NULL CHECK (id = 'default'),
              activeBlogID TEXT
            ) STRICT;

            INSERT INTO appWorkspaces (id, activeBlogID)
              SELECT 'default', id
              FROM blogs
              ORDER BY createdAt, id
              LIMIT 1;

            INSERT OR IGNORE INTO appWorkspaces (id, activeBlogID)
              VALUES ('default', NULL);
            """)
    }
}

nonisolated struct AppPersistence: Sendable {
    let database: any DatabaseWriter
    let syncEngine: SyncEngine

    init(database: any DatabaseWriter) throws {
        self.database = database
        self.syncEngine = try SyncEngine(
            for: database,
            tables: Blog.self,
            Blogger.self,
            BlogItem.self,
            MediaAsset.self,
            MediaAssetData.self,
            Trip.self,
            MailingList.self,
            Subscriber.self,
            PublishEvent.self,
            privateTables: AppWorkspace.self, AppBlogIdentity.self
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
