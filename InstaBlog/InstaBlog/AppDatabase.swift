import Foundation
import CryptoKit
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
        migrator.registerMigration("004 Move media originals out of SQLite") { db in
            try db.alter(table: "mediaAssets") { table in
                table.add(column: "contentHash", .text)
                table.add(column: "cloudAssetHash", .text)
                table.add(column: "cloudAssetSyncError", .text)
            }
            try migrateLegacyMediaBlobs(in: db)
            try db.drop(table: "mediaAssetData")
        }
        migrator.registerMigration("005 Add soft delete support for trips") { db in
            let existingColumns = try db.columns(in: "trips").map(\.name)
            guard !existingColumns.contains("deletedAt") else { return }
            try db.alter(table: "trips") { table in
                table.add(column: "deletedAt", .text)
            }
        }
        migrator.registerMigration("006 Add durable Journal placement and galleries") { db in
            try addDurableJournalPlacement(in: db)
        }
        migrator.registerMigration("007 Repair deployed Journal placement schema") { db in
            try repairDeployedJournalPlacementSchema(in: db)
        }
        migrator.registerMigration("008 Make Journal relationships shareable") { db in
            try rebuildShareableJournalRelationshipSchema(in: db)
        }
        migrator.registerMigration("009 Prune empty textless galleries") { db in
            try db.execute(sql: """
                UPDATE galleries
                SET deletedAt = COALESCE(deletedAt, strftime('%Y-%m-%d %H:%M:%f', 'now')),
                    updatedAt = strftime('%Y-%m-%d %H:%M:%f', 'now')
                WHERE deletedAt IS NULL
                  AND TRIM(title) = ''
                  AND TRIM(description) = ''
                  AND NOT EXISTS (
                    SELECT 1
                    FROM dayItems
                    JOIN blogItemPlacements
                      ON blogItemPlacements.dayItemID = dayItems.id
                    WHERE dayItems.galleryID = galleries.id
                  );

                UPDATE dayItems
                SET deletedAt = COALESCE(deletedAt, strftime('%Y-%m-%d %H:%M:%f', 'now')),
                    updatedAt = strftime('%Y-%m-%d %H:%M:%f', 'now')
                WHERE deletedAt IS NULL
                  AND galleryID IN (
                    SELECT id
                    FROM galleries
                    WHERE deletedAt IS NOT NULL
                      AND TRIM(title) = ''
                      AND TRIM(description) = ''
                  )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM blogItemPlacements
                    WHERE blogItemPlacements.dayItemID = dayItems.id
                  );
                """)
        }
        migrator.registerMigration("010 Enforce one placement per BlogItem") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS appPendingCloudKitDeletions (
                  recordType TEXT NOT NULL,
                  recordID TEXT NOT NULL,
                  PRIMARY KEY (recordType, recordID)
                ) STRICT;

                INSERT OR IGNORE INTO appPendingCloudKitDeletions (recordType, recordID)
                SELECT 'blogItemPlacements', stale.id
                FROM blogItemPlacements AS stale
                WHERE EXISTS (
                    SELECT 1
                    FROM blogItemPlacements AS newer
                    WHERE newer.blogItemID = stale.blogItemID
                      AND (
                        newer.updatedAt > stale.updatedAt
                        OR (
                            newer.updatedAt = stale.updatedAt
                            AND newer.id > stale.id
                        )
                    )
                );

                DELETE FROM blogItemPlacements
                WHERE EXISTS (
                    SELECT 1
                    FROM blogItemPlacements AS newer
                    WHERE newer.blogItemID = blogItemPlacements.blogItemID
                      AND (
                        newer.updatedAt > blogItemPlacements.updatedAt
                        OR (
                            newer.updatedAt = blogItemPlacements.updatedAt
                            AND newer.id > blogItemPlacements.id
                        )
                    )
                );

                UPDATE dayItems
                SET deletedAt = COALESCE(deletedAt, strftime('%Y-%m-%d %H:%M:%f', 'now')),
                    updatedAt = strftime('%Y-%m-%d %H:%M:%f', 'now')
                WHERE deletedAt IS NULL
                  AND galleryID IS NOT NULL
                  AND NOT EXISTS (
                    SELECT 1
                    FROM blogItemPlacements
                    WHERE blogItemPlacements.dayItemID = dayItems.id
                  );

                UPDATE galleries
                SET deletedAt = COALESCE(deletedAt, strftime('%Y-%m-%d %H:%M:%f', 'now')),
                    updatedAt = strftime('%Y-%m-%d %H:%M:%f', 'now')
                WHERE deletedAt IS NULL
                  AND TRIM(title) = ''
                  AND TRIM(description) = ''
                  AND NOT EXISTS (
                    SELECT 1
                    FROM dayItems
                    JOIN blogItemPlacements
                      ON blogItemPlacements.dayItemID = dayItems.id
                    WHERE dayItems.galleryID = galleries.id
                      AND dayItems.deletedAt IS NULL
                  );

                """)
        }
        migrator.registerMigration("011 Preserve Photos asset ownership reference") { db in
            let existingColumns = try db.columns(in: "mediaAssets").map(\.name)
            try db.alter(table: "mediaAssets") { table in
                if !existingColumns.contains("photoLibraryAssetIdentifier") {
                    table.add(column: "photoLibraryAssetIdentifier", .text)
                }
                if !existingColumns.contains("photoLibraryAssetUploaderID") {
                    table.add(column: "photoLibraryAssetUploaderID", .text)
                }
            }
        }
        return migrator
    }()

    static func flushPendingCloudKitDeletions(
        in database: any DatabaseWriter
    ) throws {
        try database.write { db in
            guard try db.tableExists("appPendingCloudKitDeletions") else { return }
            try db.execute(sql: """
                UPDATE sqlitedata_icloud_metadata
                SET _isDeleted = 1
                WHERE _isDeleted = 0
                  AND EXISTS (
                    SELECT 1
                    FROM appPendingCloudKitDeletions
                    WHERE recordType = sqlitedata_icloud_metadata.recordType
                      AND recordID = sqlitedata_icloud_metadata.recordPrimaryKey
                  );

                DELETE FROM appPendingCloudKitDeletions;
                """)
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
              photoLibraryAssetIdentifier TEXT,
              photoLibraryAssetUploaderID TEXT,
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

    private static func addDurableJournalPlacement(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE galleries (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              title TEXT NOT NULL,
              description TEXT NOT NULL DEFAULT '',
              latitude REAL,
              longitude REAL,
              locationName TEXT,
              countryCode TEXT,
              weatherTemperatureCelsius REAL,
              weatherConditionCode TEXT,
              sortMode TEXT NOT NULL DEFAULT 'date' CHECK (sortMode IN ('date', 'manual')),
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              deletedAt TEXT
            ) STRICT;

            CREATE TABLE dayItems (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              galleryID TEXT,
              placementDate TEXT NOT NULL,
              placementTimeZoneIdentifier TEXT,
              localDay TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              deletedAt TEXT
            ) STRICT;

            CREATE TABLE blogItemPlacements (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogItemID TEXT NOT NULL,
              dayItemID TEXT NOT NULL REFERENCES dayItems(id) ON DELETE CASCADE,
              position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            ) STRICT;

            CREATE INDEX galleries_blogID ON galleries (blogID);
            CREATE INDEX dayItems_blogID_localDay_placementDate
              ON dayItems (blogID, localDay, placementDate);
            CREATE INDEX blogItemPlacements_dayItemID_position
              ON blogItemPlacements (dayItemID, position);
            """)

        let blogs = try Row.fetchAll(
            db,
            sql: "SELECT id, galleryIntervalSeconds, galleryDistanceMeters FROM blogs"
        )
        for blog in blogs {
            let blogID: String = blog["id"]
            let interval: Int = blog["galleryIntervalSeconds"]
            let distance: Double = blog["galleryDistanceMeters"]
            let items = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM blogItems
                    WHERE blogID = ? AND deletedAt IS NULL
                    ORDER BY localDay, itemDate, id
                    """,
                arguments: [blogID]
            )
            let itemsByDay = Dictionary(grouping: items) { row -> String in row["localDay"] }
            for localDay in itemsByDay.keys.sorted() {
                guard let dayItems = itemsByDay[localDay] else { continue }
                var index = dayItems.startIndex
                while index < dayItems.endIndex {
                    let anchor = dayItems[index]
                    var grouped = [anchor]
                    var nextIndex = dayItems.index(after: index)
                    while nextIndex < dayItems.endIndex,
                          migrationItemsMatch(
                            anchor,
                            dayItems[nextIndex],
                            interval: interval,
                            distance: distance
                          ) {
                        grouped.append(dayItems[nextIndex])
                        nextIndex = dayItems.index(after: nextIndex)
                    }
                    if grouped.count > 1 {
                        try insertMigratedGallery(
                            grouped,
                            blogID: blogID,
                            localDay: localDay,
                            in: db
                        )
                        index = nextIndex
                    } else {
                        try insertMigratedDirectItem(anchor, blogID: blogID, in: db)
                        index = dayItems.index(after: index)
                    }
                }
            }
        }
    }

    private static func rebuildShareableJournalRelationshipSchema(in db: Database) throws {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        try db.execute(sql: """
            CREATE TEMP TABLE journalRelationshipRepair (
              dayItemID TEXT NOT NULL,
              dayItemBlogID TEXT NOT NULL,
              dayItemGalleryID TEXT,
              placementDate TEXT NOT NULL,
              placementTimeZoneIdentifier TEXT,
              localDay TEXT NOT NULL,
              dayItemCreatedAt TEXT NOT NULL,
              dayItemUpdatedAt TEXT NOT NULL,
              dayItemDeletedAt TEXT,
              placementID TEXT,
              blogItemID TEXT,
              position INTEGER,
              placementCreatedAt TEXT,
              placementUpdatedAt TEXT
            ) STRICT;
            """)
        try db.execute(sql: """
            INSERT INTO journalRelationshipRepair
            SELECT dayItems.id, dayItems.blogID, dayItems.galleryID,
                   dayItems.placementDate, dayItems.placementTimeZoneIdentifier,
                   dayItems.localDay, dayItems.createdAt, dayItems.updatedAt, dayItems.deletedAt,
                   blogItemPlacements.id, blogItemPlacements.blogItemID,
                   blogItemPlacements.position, blogItemPlacements.createdAt,
                   blogItemPlacements.updatedAt
            FROM dayItems
            LEFT JOIN blogItemPlacements ON blogItemPlacements.dayItemID = dayItems.id;
            """)
        try db.execute(sql: "DROP TABLE blogItemPlacements")
        try db.execute(sql: "DROP TABLE dayItems")
        try db.execute(sql: """
            CREATE TABLE dayItems (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
              galleryID TEXT,
              placementDate TEXT NOT NULL,
              placementTimeZoneIdentifier TEXT,
              localDay TEXT NOT NULL,
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL,
              deletedAt TEXT
            ) STRICT;

            CREATE TABLE blogItemPlacements (
              id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
              blogItemID TEXT NOT NULL,
              dayItemID TEXT NOT NULL REFERENCES dayItems(id) ON DELETE CASCADE,
              position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
              createdAt TEXT NOT NULL,
              updatedAt TEXT NOT NULL
            ) STRICT;
            """)
        try db.execute(sql: """
            INSERT INTO dayItems
              (id, blogID, galleryID, placementDate, placementTimeZoneIdentifier,
               localDay, createdAt, updatedAt, deletedAt)
            SELECT DISTINCT dayItemID, dayItemBlogID, dayItemGalleryID, placementDate,
                   placementTimeZoneIdentifier, localDay, dayItemCreatedAt, dayItemUpdatedAt,
                   dayItemDeletedAt
            FROM journalRelationshipRepair
            WHERE placementID IS NOT NULL;

            INSERT INTO blogItemPlacements
              (id, blogItemID, dayItemID, position, createdAt, updatedAt)
            SELECT placementID, blogItemID, dayItemID, position, placementCreatedAt,
                   placementUpdatedAt
            FROM journalRelationshipRepair;

            DROP TABLE journalRelationshipRepair;
            CREATE INDEX dayItems_blogID_localDay_placementDate
              ON dayItems (blogID, localDay, placementDate);
            CREATE INDEX blogItemPlacements_dayItemID_position
              ON blogItemPlacements (dayItemID, position);
            """)
    }

    static func prepareShareableJournalRelationships(
        in database: any DatabaseWriter
    ) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE dayItems
                SET updatedAt = updatedAt
                WHERE id IN (
                  SELECT recordPrimaryKey
                  FROM sqlitedata_icloud_metadata
                  WHERE recordType = 'dayItems' AND parentRecordType IS NULL
                );

                UPDATE blogItemPlacements
                SET updatedAt = updatedAt
                WHERE id IN (
                  SELECT recordPrimaryKey
                  FROM sqlitedata_icloud_metadata
                  WHERE recordType = 'blogItemPlacements' AND parentRecordType IS NULL
                );
                """)
        }
    }

    private static func repairDeployedJournalPlacementSchema(in db: Database) throws {
        let placementColumns = try db.columns(in: "blogItemPlacements").map(\.name)
        let dayItemSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'dayItems'"
        ) ?? ""
        let needsPlacementIdentity = !placementColumns.contains("id")
        let needsDayItemRebuild = dayItemSQL.localizedCaseInsensitiveContains(
            "galleryID TEXT UNIQUE"
        )

        if needsPlacementIdentity || needsDayItemRebuild {
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.execute(sql: """
                CREATE TEMP TABLE journalPlacementRepair (
                  id TEXT NOT NULL,
                  blogItemID TEXT NOT NULL,
                  dayItemID TEXT NOT NULL,
                  position INTEGER NOT NULL,
                  createdAt TEXT NOT NULL,
                  updatedAt TEXT NOT NULL
                ) STRICT;
                """)
            if needsPlacementIdentity {
                let placements = try Row.fetchAll(db, sql: "SELECT * FROM blogItemPlacements")
                for placement in placements {
                    try db.execute(
                        sql: """
                            INSERT INTO journalPlacementRepair
                              (id, blogItemID, dayItemID, position, createdAt, updatedAt)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            UUID().uuidString,
                            placement["blogItemID"] as String,
                            placement["dayItemID"] as String,
                            placement["position"] as Int,
                            placement["createdAt"] as Date,
                            placement["updatedAt"] as Date,
                        ]
                    )
                }
            } else {
                try db.execute(sql: """
                    INSERT INTO journalPlacementRepair
                      (id, blogItemID, dayItemID, position, createdAt, updatedAt)
                    SELECT id, blogItemID, dayItemID, position, createdAt, updatedAt
                    FROM blogItemPlacements;
                    """)
            }

            try db.execute(sql: """
                CREATE TABLE dayItems_repaired (
                  id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                  blogID TEXT NOT NULL REFERENCES blogs(id) ON DELETE CASCADE,
                  galleryID TEXT,
                  placementDate TEXT NOT NULL,
                  placementTimeZoneIdentifier TEXT,
                  localDay TEXT NOT NULL,
                  createdAt TEXT NOT NULL,
                  updatedAt TEXT NOT NULL,
                  deletedAt TEXT
                ) STRICT;

                INSERT INTO dayItems_repaired
                SELECT id, blogID, galleryID, placementDate, placementTimeZoneIdentifier,
                       localDay, createdAt, updatedAt, deletedAt
                FROM dayItems;

                DROP TABLE blogItemPlacements;
                DROP TABLE dayItems;
                ALTER TABLE dayItems_repaired RENAME TO dayItems;

                CREATE TABLE blogItemPlacements (
                  id TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
                  blogItemID TEXT NOT NULL,
                  dayItemID TEXT NOT NULL REFERENCES dayItems(id) ON DELETE CASCADE,
                  position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
                  createdAt TEXT NOT NULL,
                  updatedAt TEXT NOT NULL
                ) STRICT;

                INSERT INTO blogItemPlacements
                SELECT id, blogItemID, dayItemID, position, createdAt, updatedAt
                FROM journalPlacementRepair;

                DROP TABLE journalPlacementRepair;

                CREATE INDEX dayItems_blogID_localDay_placementDate
                  ON dayItems (blogID, localDay, placementDate);
                CREATE INDEX blogItemPlacements_dayItemID_position
                  ON blogItemPlacements (dayItemID, position);
                """)
        }

        let unplacedItems = try Row.fetchAll(
            db,
            sql: """
                SELECT blogItems.*
                FROM blogItems
                LEFT JOIN blogItemPlacements
                  ON blogItemPlacements.blogItemID = blogItems.id
                WHERE blogItems.deletedAt IS NULL
                  AND blogItemPlacements.id IS NULL
                ORDER BY blogItems.itemDate, blogItems.id
                """
        )
        for item in unplacedItems {
            let blogID: String = item["blogID"]
            try insertMigratedDirectItem(item, blogID: blogID, in: db)
        }
    }

    private static func insertMigratedDirectItem(
        _ item: Row,
        blogID: String,
        in db: Database
    ) throws {
        let dayItemID = UUID().uuidString
        let itemID: String = item["id"]
        let itemDate: Date = item["itemDate"]
        let timeZone: String? = item["itemTimeZoneIdentifier"]
        let localDay: String = item["localDay"]
        let createdAt: Date = item["createdAt"]
        let updatedAt: Date = item["updatedAt"]
        try db.execute(
            sql: """
                INSERT INTO dayItems
                  (id, blogID, placementDate, placementTimeZoneIdentifier, localDay, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [dayItemID, blogID, itemDate, timeZone, localDay, createdAt, updatedAt]
        )
        try db.execute(
            sql: """
                INSERT INTO blogItemPlacements
                  (id, blogItemID, dayItemID, position, createdAt, updatedAt)
                VALUES (?, ?, ?, 0, ?, ?)
                """,
            arguments: [UUID().uuidString, itemID, dayItemID, createdAt, updatedAt]
        )
    }

    private static func insertMigratedGallery(
        _ items: [Row],
        blogID: String,
        localDay: String,
        in db: Database
    ) throws {
        guard let first = items.first else { return }
        let galleryID = UUID().uuidString
        let dayItemID = UUID().uuidString
        let itemDate: Date = first["itemDate"]
        let timeZone: String? = first["itemTimeZoneIdentifier"]
        let createdAt: Date = first["createdAt"]
        let updatedAt = items.compactMap { row -> Date? in row["updatedAt"] }.max() ?? createdAt
        let locationName: String? = first["locationName"]
        try db.execute(
            sql: """
                INSERT INTO galleries
                  (id, blogID, title, description, latitude, longitude, locationName, countryCode,
                   weatherTemperatureCelsius, weatherConditionCode, sortMode, createdAt, updatedAt)
                VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, ?, 'date', ?, ?)
                """,
            arguments: [
                galleryID,
                blogID,
                locationName?.isEmpty == false ? locationName : "Gallery",
                first["latitude"] as Double?,
                first["longitude"] as Double?,
                locationName,
                first["countryCode"] as String?,
                first["weatherTemperatureCelsius"] as Double?,
                first["weatherConditionCode"] as String?,
                createdAt,
                updatedAt,
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO dayItems
                  (id, blogID, galleryID, placementDate, placementTimeZoneIdentifier,
                   localDay, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                dayItemID, blogID, galleryID, itemDate, timeZone, localDay, createdAt, updatedAt,
            ]
        )
        for (position, item) in items.enumerated() {
            let itemID: String = item["id"]
            let itemCreatedAt: Date = item["createdAt"]
            let itemUpdatedAt: Date = item["updatedAt"]
            try db.execute(
                sql: """
                    INSERT INTO blogItemPlacements
                      (id, blogItemID, dayItemID, position, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, itemID, dayItemID, position, itemCreatedAt, itemUpdatedAt,
                ]
            )
        }
    }

    private static func migrationItemsMatch(
        _ anchor: Row,
        _ candidate: Row,
        interval: Int,
        distance: Double
    ) -> Bool {
        let anchorDate: Date = anchor["itemDate"]
        let candidateDate: Date = candidate["itemDate"]
        guard candidateDate.timeIntervalSince(anchorDate) <= Double(interval) else {
            return false
        }
        let anchorLatitude: Double? = anchor["latitude"]
        let anchorLongitude: Double? = anchor["longitude"]
        let candidateLatitude: Double? = candidate["latitude"]
        let candidateLongitude: Double? = candidate["longitude"]
        guard let anchorLatitude,
              let anchorLongitude,
              let candidateLatitude,
              let candidateLongitude else {
            let anchorLocation: String? = anchor["locationName"]
            let candidateLocation: String? = candidate["locationName"]
            return anchorLocation == candidateLocation
        }
        let earthRadius = 6_371_000.0
        let latitudeDelta = (candidateLatitude - anchorLatitude) * .pi / 180
        let longitudeDelta = (candidateLongitude - anchorLongitude) * .pi / 180
        let firstLatitude = anchorLatitude * .pi / 180
        let secondLatitude = candidateLatitude * .pi / 180
        let haversine = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadius * 2 * atan2(sqrt(haversine), sqrt(1 - haversine)) <= distance
    }

    private static func migrateLegacyMediaBlobs(in db: Database) throws {
        guard let databasePath = try String.fetchOne(
            db,
            sql: "SELECT file FROM pragma_database_list WHERE name = 'main'"
        ),
        !databasePath.isEmpty
        else { return }
        let mediaDirectory = URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent("BlogItemMedia", isDirectory: true)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT mediaAssets.id, mediaAssets.mimeType, mediaAssetData.data
                FROM mediaAssets
                JOIN mediaAssetData ON mediaAssetData.mediaAssetID = mediaAssets.id
                """
        )
        guard !rows.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: true
        )
        for row in rows {
            let id: String = row["id"]
            let mimeType: String = row["mimeType"]
            let data: Data = row["data"]
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let filename = "\(hash).\(MediaStoragePaths.preferredFileExtension(for: mimeType))"
            let fileURL = mediaDirectory.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
            }
            try db.execute(
                sql: """
                    UPDATE mediaAssets
                    SET localOriginalPath = ?, contentHash = ?, filename = ?
                    WHERE id = ?
                    """,
                arguments: [filename, hash, filename, id]
            )
        }
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
            Gallery.self,
            DayItem.self,
            BlogItemPlacement.self,
            MediaAsset.self,
            Trip.self,
            MailingList.self,
            Subscriber.self,
                PublishEvent.self,
                containerIdentifier: containerIdentifier
            )
            try AppDatabase.flushPendingCloudKitDeletions(in: database)
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
