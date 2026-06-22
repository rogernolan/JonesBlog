import Foundation
import GRDB
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("App database schema", .serialized)
struct AppDatabaseTests {
    @Test func inMemoryDatabaseCreatesExpectedTablesAndColumns() throws {
        let database = try AppDatabase.makeInMemory()

        try database.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name"
            )
            #expect(tables == [
                "blogItems", "bloggers", "blogs", "mailingLists",
                "mediaAssets", "publishEvents", "subscribers", "trips",
            ])

            let expectedColumns: [String: [String]] = [
                "blogs": ["id", "title", "createdAt", "updatedAt", "galleryIntervalSeconds", "galleryDistanceMeters"],
                "bloggers": ["id", "blogID", "displayName", "createdAt", "updatedAt", "cloudKitParticipantIdentifier"],
                "blogItems": ["id", "blogID", "authorID", "caption", "createdAt", "updatedAt", "itemDate", "itemTimeZoneIdentifier", "localDay", "latitude", "longitude", "locationName", "countryCode", "weatherTemperatureCelsius", "weatherConditionCode", "photoAssetID", "deletedAt"],
                "mediaAssets": ["id", "blogID", "kind", "localOriginalPath", "cloudAssetIdentifier", "filename", "mimeType", "pixelWidth", "pixelHeight", "createdAt", "updatedAt"],
                "trips": ["id", "blogID", "title", "description", "startLocalDay", "endLocalDay", "heroImageAssetID", "createdAt", "updatedAt", "closedAt"],
                "mailingLists": ["id", "blogID", "name", "createdAt", "updatedAt"],
                "subscribers": ["id", "blogID", "mailingListID", "emailAddress", "displayName", "createdAt", "updatedAt"],
                "publishEvents": ["id", "blogID", "tripID", "localDay", "mailingListID", "initiatedAt", "initiatedByBloggerID", "recipientCount"],
            ]

            for (table, expected) in expectedColumns {
                #expect(try db.columns(in: table).map(\.name) == expected)
            }

            let tableSQL = try Row.fetchAll(
                db,
                sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name IN (" + expectedColumns.keys.map { _ in "?" }.joined(separator: ",") + ")",
                arguments: StatementArguments(expectedColumns.keys.sorted())
            )
            #expect(tableSQL.count == 8)
            #expect(tableSQL.allSatisfy { (($0["sql"] as String?) ?? "").hasSuffix("STRICT") })
        }
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
                "mailingLists_blogID": false,
                "mailingLists_blogID_unique": true,
                "mediaAssets_blogID": false,
                "publishEvents_blogID_localDay": false,
                "publishEvents_mailingListID_initiatedAt": false,
                "subscribers_list_email_unique": true,
                "subscribers_mailingListID_emailAddress": false,
                "trips_blogID_startLocalDay_endLocalDay": false,
            ])
        }
    }

    @Test func databaseRejectsContentlessBlogItem() throws {
        let database = try AppDatabase.makeInMemory()

        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO blogItems
                      (id, blogID, authorID, caption, createdAt, updatedAt, itemDate, localDay, photoAssetID)
                    VALUES (?, ?, ?, ' \n\t ', ?, ?, ?, '2027-01-15', NULL)
                    """, arguments: [UUID().uuidString, UUID().uuidString, UUID().uuidString, Self.date, Self.date, Self.date])
            }
        }
    }

    @Test func databaseRejectsNonPhotoMediaAsset() throws {
        let database = try AppDatabase.makeInMemory()

        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO mediaAssets
                      (id, blogID, kind, filename, mimeType, createdAt, updatedAt)
                    VALUES (?, ?, 'video', 'clip.mov', 'video/quicktime', ?, ?)
                    """, arguments: [UUID().uuidString, UUID().uuidString, Self.date, Self.date])
            }
        }
    }

    @Test func databaseAllowsOnlyOneMailingListPerBlog() throws {
        let database = try AppDatabase.makeInMemory()
        let blogID = UUID().uuidString

        try database.write { db in
            try Self.insertBlog(id: blogID, into: db)
            try Self.insertMailingList(id: UUID().uuidString, blogID: blogID, into: db)
        }
        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try Self.insertMailingList(id: UUID().uuidString, blogID: blogID, into: db)
            }
        }
    }

    @Test func subscriberEmailIsUniqueIgnoringCaseWithinAList() throws {
        let database = try AppDatabase.makeInMemory()
        let blogID = UUID().uuidString
        let listID = UUID().uuidString

        try database.write { db in
            try Self.insertBlog(id: blogID, into: db)
            try Self.insertMailingList(id: listID, blogID: blogID, into: db)
            try Self.insertSubscriber(email: "Reader@Example.com", blogID: blogID, listID: listID, into: db)
        }
        #expect(throws: DatabaseError.self) {
            try database.write { db in
                try Self.insertSubscriber(email: "reader@example.COM", blogID: blogID, listID: listID, into: db)
            }
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
    }

    private static let date = "2027-01-15 08:00:00.000"

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
