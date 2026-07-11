import Foundation
import CryptoKit
import GRDB
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("App database schema", .serialized)
struct AppDatabaseTests {
    @Test func repairMigrationUpgradesAlreadyDeployedPlacementSchema() throws {
        let database = try AppDatabase.makeInMemory()
        try database.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [
                "007 Repair deployed Journal placement schema",
            ])
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.execute(sql: """
                ALTER TABLE blogItemPlacements RENAME TO currentPlacements;
                CREATE TABLE blogItemPlacements (
                  blogItemID TEXT PRIMARY KEY NOT NULL REFERENCES blogItems(id) ON DELETE CASCADE,
                  dayItemID TEXT NOT NULL REFERENCES dayItems(id) ON DELETE CASCADE,
                  position INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
                  createdAt TEXT NOT NULL,
                  updatedAt TEXT NOT NULL
                ) STRICT;
                INSERT INTO blogItemPlacements
                  (blogItemID, dayItemID, position, createdAt, updatedAt)
                SELECT blogItemID, dayItemID, position, createdAt, updatedAt
                FROM currentPlacements;
                DROP TABLE currentPlacements;
                """)
        }

        try AppDatabase.migrator.migrate(database)

        try database.read { db in
            let firstPlacementColumn = try db.columns(in: "blogItemPlacements").map(\.name).first
            let placementCount = try BlogItemPlacement.fetchCount(db)
            let itemCount = try BlogItem.fetchCount(db)
            #expect(firstPlacementColumn == "id")
            #expect(placementCount == itemCount)
        }
    }

    @Test func durablePlacementMigrationMaterializesVisibleLegacyGallery() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(
            database,
            upTo: "005 Add soft delete support for trips"
        )
        let blogID = UUID()
        let bloggerID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO blogs (id, title, createdAt, updatedAt)
                    VALUES (?, 'Legacy', ?, ?)
                    """,
                arguments: [blogID.uuidString, createdAt, createdAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO bloggers (id, blogID, displayName, createdAt, updatedAt)
                    VALUES (?, ?, 'Rog', ?, ?)
                    """,
                arguments: [bloggerID.uuidString, blogID.uuidString, createdAt, createdAt]
            )
            for (offset, itemID) in [firstID, secondID].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO blogItems
                          (id, blogID, authorID, caption, createdAt, updatedAt, itemDate,
                           itemTimeZoneIdentifier, localDay, locationName)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 'Europe/London', '2026-05-27', 'Harbour')
                        """,
                    arguments: [
                        itemID.uuidString,
                        blogID.uuidString,
                        bloggerID.uuidString,
                        "Entry \(offset)",
                        createdAt,
                        createdAt,
                        createdAt.addingTimeInterval(Double(offset * 60)),
                    ]
                )
            }
        }

        try AppDatabase.migrator.migrate(database)

        try database.read { db in
            let galleryCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM galleries")
            let dayItemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dayItems")
            let placementCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM blogItemPlacements"
            )
            #expect(galleryCount == 1)
            #expect(dayItemCount == 1)
            #expect(placementCount == 2)
        }
    }

    @Test func emptyTextlessGalleriesArePrunedByMigration() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(
            database,
            upTo: "008 Make Journal relationships shareable"
        )
        let blogID = UUID()
        let galleryID = UUID()
        let dayItemID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO blogs (id, title, createdAt, updatedAt) VALUES (?, 'Legacy', ?, ?)",
                arguments: [blogID.uuidString, createdAt, createdAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO galleries
                      (id, blogID, title, description, createdAt, updatedAt)
                    VALUES (?, ?, '', '  ', ?, ?)
                    """,
                arguments: [galleryID.uuidString, blogID.uuidString, createdAt, createdAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO dayItems
                      (id, blogID, galleryID, placementDate, localDay, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, '2026-05-27', ?, ?)
                    """,
                arguments: [dayItemID.uuidString, blogID.uuidString, galleryID.uuidString, createdAt, createdAt, createdAt]
            )
        }

        try AppDatabase.migrator.migrate(database)

        try database.read { db in
            let galleryDeletedAt = try String.fetchOne(
                db,
                sql: "SELECT deletedAt FROM galleries WHERE id = ?",
                arguments: [galleryID.uuidString]
            )
            let dayItemDeletedAt = try String.fetchOne(
                db,
                sql: "SELECT deletedAt FROM dayItems WHERE id = ?",
                arguments: [dayItemID.uuidString]
            )
            #expect(galleryDeletedAt != nil)
            #expect(dayItemDeletedAt != nil)
        }
    }

    @Test func placementMigrationKeepsNewestPlacementWithoutSyncUnsupportedConstraint() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(
            database,
            upTo: "009 Prune empty textless galleries"
        )
        let blogID = UUID()
        let bloggerID = UUID()
        let itemID = UUID()
        let firstDayItemID = UUID()
        let secondDayItemID = UUID()
        let firstPlacementID = UUID()
        let secondPlacementID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        let newerAt = createdAt.addingTimeInterval(60)

        try database.write { db in
            try db.execute(
                sql: "INSERT INTO blogs (id, title, createdAt, updatedAt) VALUES (?, 'Legacy', ?, ?)",
                arguments: [blogID.uuidString, createdAt, createdAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO bloggers (id, blogID, displayName, createdAt, updatedAt)
                    VALUES (?, ?, 'Rog', ?, ?)
                    """,
                arguments: [bloggerID.uuidString, blogID.uuidString, createdAt, createdAt]
            )
            try db.execute(
                sql: """
                    INSERT INTO blogItems
                      (id, blogID, authorID, caption, createdAt, updatedAt, itemDate, localDay)
                    VALUES (?, ?, ?, 'Entry', ?, ?, ?, '2026-07-05')
                    """,
                arguments: [itemID.uuidString, blogID.uuidString, bloggerID.uuidString, createdAt, createdAt, createdAt]
            )
            for dayItemID in [firstDayItemID, secondDayItemID] {
                try db.execute(
                    sql: """
                        INSERT INTO dayItems
                          (id, blogID, placementDate, localDay, createdAt, updatedAt)
                        VALUES (?, ?, ?, '2026-07-05', ?, ?)
                        """,
                    arguments: [dayItemID.uuidString, blogID.uuidString, createdAt, createdAt, createdAt]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO blogItemPlacements
                      (id, blogItemID, dayItemID, position, createdAt, updatedAt)
                    VALUES (?, ?, ?, 0, ?, ?), (?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    firstPlacementID.uuidString, itemID.uuidString, firstDayItemID.uuidString, createdAt, createdAt,
                    secondPlacementID.uuidString, itemID.uuidString, secondDayItemID.uuidString, createdAt, newerAt,
                ]
            )
        }

        try AppDatabase.migrator.migrate(database)

        try database.read { db in
            let placements = try BlogItemPlacement.fetchAll(db)
            #expect(placements.count == 1)
            #expect(placements.first?.id == secondPlacementID)
            #expect(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM blogItemPlacements WHERE blogItemID = ?",
                arguments: [itemID.uuidString]
            ) == 1)
        }

    }

    @Test func inMemoryDatabaseCreatesExpectedTablesAndColumns() throws {
        let database = try AppDatabase.makeInMemory()

        try database.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name"
            )
            #expect(tables == [
                "appBlogIdentities", "appPendingCloudKitDeletions", "appWorkspaces", "blogItemPlacements", "blogItems", "bloggers", "blogs",
                "dayItems", "galleries", "mailingLists", "mediaAssets",
                "publishEvents", "subscribers", "trips",
            ])

            let expectedColumns: [String: [String]] = [
                "blogs": ["id", "title", "createdAt", "updatedAt", "galleryIntervalSeconds", "galleryDistanceMeters"],
                "bloggers": ["id", "blogID", "displayName", "createdAt", "updatedAt", "cloudKitParticipantIdentifier"],
                "blogItems": ["id", "blogID", "authorID", "caption", "createdAt", "updatedAt", "itemDate", "itemTimeZoneIdentifier", "localDay", "latitude", "longitude", "locationName", "countryCode", "weatherTemperatureCelsius", "weatherConditionCode", "photoAssetID", "deletedAt"],
                "galleries": ["id", "blogID", "title", "description", "latitude", "longitude", "locationName", "countryCode", "weatherTemperatureCelsius", "weatherConditionCode", "sortMode", "createdAt", "updatedAt", "deletedAt"],
                "dayItems": ["id", "blogID", "galleryID", "placementDate", "placementTimeZoneIdentifier", "localDay", "createdAt", "updatedAt", "deletedAt"],
                "blogItemPlacements": ["id", "blogItemID", "dayItemID", "position", "createdAt", "updatedAt"],
                "mediaAssets": ["id", "blogID", "kind", "localOriginalPath", "photoLibraryAssetIdentifier", "photoLibraryAssetUploaderID", "cloudAssetIdentifier", "filename", "mimeType", "pixelWidth", "pixelHeight", "createdAt", "updatedAt", "contentHash", "cloudAssetHash", "cloudAssetSyncError"],
                "trips": ["id", "blogID", "title", "description", "startLocalDay", "endLocalDay", "heroImageAssetID", "createdAt", "updatedAt", "closedAt", "deletedAt"],
                "mailingLists": ["id", "blogID", "name", "createdAt", "updatedAt"],
                "subscribers": ["id", "blogID", "mailingListID", "emailAddress", "displayName", "createdAt", "updatedAt"],
                "publishEvents": ["id", "blogID", "tripID", "localDay", "mailingListID", "initiatedAt", "initiatedByBloggerID", "recipientCount"],
            ]

            for (table, expected) in expectedColumns {
                let columns = try db.columns(in: table)
                #expect(columns.map(\.name) == expected)
                let id = try #require(columns.first)
                #expect(id.type.uppercased() == "TEXT")
                #expect(id.isNotNull)
                #expect(id.primaryKeyIndex == 1)
                #expect(id.defaultValueSQL == "uuid()")
            }

            let tableSQL = try Row.fetchAll(
                db,
                sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name IN (" + expectedColumns.keys.map { _ in "?" }.joined(separator: ",") + ")",
                arguments: StatementArguments(expectedColumns.keys.sorted())
            )
            #expect(tableSQL.count == 11)
            #expect(tableSQL.allSatisfy { (($0["sql"] as String?) ?? "").hasSuffix("STRICT") })
        }
    }

    @Test func privateBlogIdentityMigrationCreatesConstrainedMappingTable() throws {
        let database = try AppDatabase.makeInMemory()
        try database.read { db in
            let columns = try db.columns(in: "appBlogIdentities")
            #expect(columns.map(\.name) == ["blogID", "bloggerID"])
            #expect(columns[0].primaryKeyIndex == 1)
            #expect(columns[0].isNotNull)
            #expect(columns[1].isNotNull)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(appBlogIdentities)").isEmpty)
        }
    }

    @Test func mediaMigrationRemovesBlobTableAndCreatesSingletonWorkspace() throws {
        let database = try AppDatabase.makeInMemory()

        try database.read { db in
            #expect(try db.tableExists("mediaAssetData") == false)
            let mediaColumns = try db.columns(in: "mediaAssets")
            #expect(mediaColumns.map(\.name).contains("contentHash"))
            #expect(mediaColumns.map(\.name).contains("cloudAssetHash"))

            let workspaceColumns = try db.columns(in: "appWorkspaces")
            #expect(workspaceColumns.map(\.name) == ["id", "activeBlogID"])
            let workspaceID = try #require(workspaceColumns.first)
            #expect(workspaceID.type.uppercased() == "TEXT")
            #expect(workspaceID.isNotNull)
            #expect(workspaceID.primaryKeyIndex == 1)
            #expect(workspaceColumns[1].type.uppercased() == "TEXT")
            #expect(!workspaceColumns[1].isNotNull)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(appWorkspaces)").isEmpty)

            let workspace = try #require(AppWorkspace.fetchAll(db).only)
            #expect(workspace.id == AppWorkspace.singletonID)
            #expect(workspace.activeBlogID == nil)
        }
    }

    @Test func sharingMigrationSelectsOldestBlogForWorkspace() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database, upTo: "001 Create v1 persistence schema")
        let oldestBlogID = UUID()
        let newestBlogID = UUID()

        try database.write { db in
            try db.execute(
                sql: "INSERT INTO blogs (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [newestBlogID.uuidString, "2027-01-16 08:00:00.000", Self.date]
            )
            try db.execute(
                sql: "INSERT INTO blogs (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [oldestBlogID.uuidString, Self.date, Self.date]
            )
        }

        try AppDatabase.migrator.migrate(database)

        let workspace = try database.read { db in
            try #require(AppWorkspace.fetchAll(db).only)
        }
        #expect(workspace.id == AppWorkspace.singletonID)
        #expect(workspace.activeBlogID == oldestBlogID)
    }

    @Test func appWorkspacesRejectsNonSingletonIDs() throws {
        let database = try AppDatabase.makeInMemory()

        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO appWorkspaces (id, activeBlogID) VALUES ('another', NULL)"
                )
            }
        }
    }

    @Test func fullSizeMediaDataCannotBeStoredInSQLite() throws {
        let database = try AppDatabase.makeInMemory()
        try database.read { db in
            let blobColumns = try Row.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('mediaAssets') WHERE upper(type) = 'BLOB'"
            )
            #expect(blobColumns.isEmpty)
        }
    }

    @Test func legacyMediaBlobMigratesToContentAddressedApplicationSupportFile() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMediaMigration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let database = try DatabaseQueue(path: rootURL.appendingPathComponent("InstaBlog.sqlite").path)
        try AppDatabase.migrator.migrate(database, upTo: "003 Add private Blog identity mapping")
        let blogID = UUID()
        let mediaID = UUID()
        let original = Data([0x01, 0x02, 0x03])
        let hash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()

        try database.write { db in
            try db.execute(
                sql: "INSERT INTO blogs (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [blogID.uuidString, Self.date, Self.date]
            )
            try db.execute(
                sql: """
                    INSERT INTO mediaAssets
                      (id, blogID, filename, mimeType, createdAt, updatedAt)
                    VALUES (?, ?, 'legacy.jpg', 'image/jpeg', ?, ?)
                    """,
                arguments: [mediaID.uuidString, blogID.uuidString, Self.date, Self.date]
            )
            try db.execute(
                sql: "INSERT INTO mediaAssetData (mediaAssetID, data) VALUES (?, ?)",
                arguments: [mediaID.uuidString, original]
            )
        }

        try AppDatabase.migrator.migrate(database)

        let migrated: Row = try database.read { db in
            #expect(try db.tableExists("mediaAssetData") == false)
            return try #require(
                try Row.fetchOne(
                    db,
                    sql: "SELECT contentHash, filename, localOriginalPath FROM mediaAssets WHERE id = ?",
                    arguments: [mediaID.uuidString]
                )
            )
        }
        #expect(migrated["contentHash"] as String? == hash)
        #expect(migrated["filename"] as String? == "\(hash).jpg")
        #expect(migrated["localOriginalPath"] as String? == migrated["filename"] as String?)
        let migratedURL = rootURL
            .appendingPathComponent("BlogItemMedia", isDirectory: true)
            .appendingPathComponent("\(hash).jpg")
        #expect(try Data(contentsOf: migratedURL) == original)
    }

    @Test func schemaCreatesExactIndexes() throws {
        let database = try AppDatabase.makeInMemory()

        try database.read { db in
            let indexes = try Row.fetchAll(
                db,
                sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name"
            )
            let actual = Dictionary(uniqueKeysWithValues: indexes.map { row in
                (row["name"] as String, ((row["sql"] as String?) ?? "").uppercased().contains("CREATE UNIQUE INDEX"))
            })
            #expect(actual == [
                "blogItems_blogID_itemDate": false,
                "blogItems_blogID_localDay_itemDate": false,
                "blogItems_authorID": false,
                "blogItemPlacements_dayItemID_position": false,
                "dayItems_blogID_localDay_placementDate": false,
                "galleries_blogID": false,
                "mailingLists_blogID": false,
                "mediaAssets_blogID": false,
                "publishEvents_blogID_localDay": false,
                "publishEvents_mailingListID_initiatedAt": false,
                "subscribers_mailingListID_emailAddress": false,
                "trips_blogID_startLocalDay_endLocalDay": false,
            ])
            #expect(actual.values.allSatisfy { !$0 })
        }
    }

    @Test func eachChildHasOnlyItsCascadingBlogForeignKey() throws {
        let database = try AppDatabase.makeInMemory()
        let childTables = ["bloggers", "blogItems", "mediaAssets", "trips", "mailingLists", "subscribers", "publishEvents"]

        try database.read { db in
            for table in childTables {
                let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
                let foreignKey = try #require(rows.only)
                #expect(foreignKey["from"] as String == "blogID")
                #expect(foreignKey["table"] as String == "blogs")
                #expect(foreignKey["to"] as String == "id")
                #expect(foreignKey["on_delete"] as String == "CASCADE")
            }
        }
    }

    @Test func foreignKeysRejectOrphansAndCascadeAllChildren() throws {
        let database = try AppDatabase.makeInMemory()
        let blogID = UUID().uuidString

        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO bloggers (blogID, createdAt, updatedAt) VALUES (?, ?, ?)",
                    arguments: [UUID().uuidString, Self.date, Self.date]
                )
            }
        }

        try database.write { db in
            try Self.insertBlog(id: blogID, into: db)
            try Self.insertMinimalChildRows(blogID: blogID, into: db)
            try db.execute(sql: "DELETE FROM blogs WHERE id = ?", arguments: [blogID])

            for table in ["bloggers", "blogItems", "mediaAssets", "trips", "mailingLists", "subscribers", "publishEvents"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0)
            }
        }
    }

    @Test func typedDraftInsertGeneratesUUIDAndAppliesDefaults() throws {
        let database = try AppDatabase.makeInMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let inserted = try database.write { db in
            try Blog.insert { Blog.Draft(createdAt: now, updatedAt: now) }
                .returning(\.self)
                .fetchOne(db)
        }
        let blog = try #require(inserted)
        let fetched = try database.read { db in try Blog.find(db, key: blog.id) }

        #expect(fetched == blog)
        #expect(blog.id.uuidString != "00000000-0000-0000-0000-000000000000")
        #expect(blog.title == BootstrapDefaults.blogTitle)
        #expect(blog.galleryIntervalSeconds == BootstrapDefaults.galleryIntervalSeconds)
        #expect(blog.galleryDistanceMeters == BootstrapDefaults.galleryDistanceMeters)
    }

    @Test func databaseRejectsContentlessBlogItem() throws {
        let database = try AppDatabase.makeInMemory()

        try database.write { db in
            try Self.insertBlog(id: Self.blogID, into: db)
        }

        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO blogItems
                      (id, blogID, authorID, caption, createdAt, updatedAt, itemDate, localDay, photoAssetID)
                    VALUES (?, ?, ?, ' \n\t ', ?, ?, ?, '2027-01-15', NULL)
                    """, arguments: [UUID().uuidString, Self.blogID, UUID().uuidString, Self.date, Self.date, Self.date])
            }
        }
    }

    @Test func databaseRejectsNonPhotoMediaAsset() throws {
        let database = try AppDatabase.makeInMemory()

        try database.write { db in
            try Self.insertBlog(id: Self.blogID, into: db)
        }

        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO mediaAssets
                      (id, blogID, kind, filename, mimeType, createdAt, updatedAt)
                    VALUES (?, ?, 'video', 'clip.mov', 'video/quicktime', ?, ?)
                    """, arguments: [UUID().uuidString, Self.blogID, Self.date, Self.date])
            }
        }
    }

    @Test func databaseAllowsDuplicateListsAndCaseVariantEmails() throws {
        let database = try AppDatabase.makeInMemory()
        let blogID = UUID().uuidString
        let listID = UUID().uuidString

        try database.write { db in
            try Self.insertBlog(id: blogID, into: db)
            try Self.insertMailingList(id: listID, blogID: blogID, into: db)
            try Self.insertMailingList(id: UUID().uuidString, blogID: blogID, into: db)
            try Self.insertSubscriber(email: "Reader@Example.com", blogID: blogID, listID: listID, into: db)
            try Self.insertSubscriber(email: "reader@example.COM", blogID: blogID, listID: listID, into: db)

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mailingLists") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM subscribers") == 2)
        }
    }

    @Test func sameSubscriberEmailIsAllowedAcrossDifferentLists() throws {
        let database = try AppDatabase.makeInMemory()
        let firstBlogID = UUID().uuidString
        let secondBlogID = UUID().uuidString
        let firstListID = UUID().uuidString
        let secondListID = UUID().uuidString

        try database.write { db in
            try Self.insertBlog(id: firstBlogID, into: db)
            try Self.insertBlog(id: secondBlogID, into: db)
            try Self.insertMailingList(id: firstListID, blogID: firstBlogID, into: db)
            try Self.insertMailingList(id: secondListID, blogID: secondBlogID, into: db)
            try Self.insertSubscriber(email: "reader@example.com", blogID: firstBlogID, listID: firstListID, into: db)
            try Self.insertSubscriber(email: "READER@example.com", blogID: secondBlogID, listID: secondListID, into: db)

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM subscribers")
            #expect(count == 2)
        }
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
        #expect(try database.read { db in try db.tableExists("blogs") })

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inserted = try database.write { db in
            try Blog.insert { Blog.Draft(createdAt: now, updatedAt: now) }
                .returning(\.self)
                .fetchOne(db)
        }
        let blog = try #require(inserted)
        let fetched = try database.read { db in try Blog.find(db, key: blog.id) }

        #expect(fetched == blog)
        #expect(blog.id.uuidString != "00000000-0000-0000-0000-000000000000")
        #expect(blog.title == BootstrapDefaults.blogTitle)
        #expect(blog.galleryIntervalSeconds == BootstrapDefaults.galleryIntervalSeconds)
        #expect(blog.galleryDistanceMeters == BootstrapDefaults.galleryDistanceMeters)
    }

    private static let date = "2027-01-15 08:00:00.000"
    private static let blogID = UUID().uuidString

    private static func insertBlog(id: String, into db: Database) throws {
        try db.execute(
            sql: "INSERT INTO blogs (id, createdAt, updatedAt) VALUES (?, ?, ?)",
            arguments: [id, date, date]
        )
    }

    private static func insertMailingList(id: String, blogID: String, into db: Database) throws {
        try db.execute(
            sql: "INSERT INTO mailingLists (id, blogID, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
            arguments: [id, blogID, date, date]
        )
    }

    private static func insertSubscriber(email: String, blogID: String, listID: String, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO subscribers
              (id, blogID, mailingListID, emailAddress, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [UUID().uuidString, blogID, listID, email, date, date])
    }

    private static func insertMinimalChildRows(blogID: String, into db: Database) throws {
        let bloggerID = UUID().uuidString
        let mailingListID = UUID().uuidString
        try db.execute(sql: "INSERT INTO bloggers (id, blogID, createdAt, updatedAt) VALUES (?, ?, ?, ?)", arguments: [bloggerID, blogID, date, date])
        try db.execute(sql: "INSERT INTO blogItems (id, blogID, authorID, caption, createdAt, updatedAt, itemDate, localDay) VALUES (?, ?, ?, 'caption', ?, ?, ?, '2027-01-15')", arguments: [UUID().uuidString, blogID, bloggerID, date, date, date])
        try db.execute(sql: "INSERT INTO mediaAssets (id, blogID, filename, mimeType, createdAt, updatedAt) VALUES (?, ?, 'photo.jpg', 'image/jpeg', ?, ?)", arguments: [UUID().uuidString, blogID, date, date])
        try db.execute(sql: "INSERT INTO trips (id, blogID, title, description, startLocalDay, createdAt, updatedAt) VALUES (?, ?, 'Trip', '', '2027-01-15', ?, ?)", arguments: [UUID().uuidString, blogID, date, date])
        try insertMailingList(id: mailingListID, blogID: blogID, into: db)
        try insertSubscriber(email: "reader@example.com", blogID: blogID, listID: mailingListID, into: db)
        try db.execute(sql: "INSERT INTO publishEvents (id, blogID, localDay, mailingListID, initiatedAt, initiatedByBloggerID, recipientCount) VALUES (?, ?, '2027-01-15', ?, ?, ?, 1)", arguments: [UUID().uuidString, blogID, mailingListID, date, bloggerID])
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
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
        #expect(directory == .applicationSupportDirectory)
        #expect(domain == .userDomainMask)
        #expect(url == nil)
        #expect(shouldCreate)
        if shouldCreate {
            try createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }
}
