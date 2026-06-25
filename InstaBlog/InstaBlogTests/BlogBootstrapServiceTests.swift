import Foundation
import GRDB
import Testing
@testable import InstaBlog

@Suite("Blog bootstrap")
struct BlogBootstrapServiceTests {
    @Test func emptyStoreCreatesOneRelatedWorkspaceWithInjectedValues() throws {
        let fixture = try Fixture()

        let workspace = try fixture.service.bootstrap()

        #expect(workspace.blog.id == fixture.ids[0])
        #expect(workspace.blog.title == "My Blog")
        #expect(workspace.blog.createdAt == fixture.date)
        #expect(workspace.blog.updatedAt == fixture.date)
        #expect(workspace.blog.galleryIntervalSeconds == 900)
        #expect(workspace.blog.galleryDistanceMeters == 500)
        #expect(workspace.blogger.id == fixture.ids[1])
        #expect(workspace.blogger.blogID == workspace.blog.id)
        #expect(workspace.blogger.displayName == "Me")
        #expect(workspace.blogger.createdAt == fixture.date)
        #expect(workspace.blogger.updatedAt == fixture.date)
        #expect(workspace.blogger.cloudKitParticipantIdentifier == nil)
        #expect(workspace.mailingList.id == fixture.ids[2])
        #expect(workspace.mailingList.blogID == workspace.blog.id)
        #expect(workspace.mailingList.name == "Subscribers")
        #expect(workspace.mailingList.createdAt == fixture.date)
        #expect(workspace.mailingList.updatedAt == fixture.date)
        #expect(try fixture.counts() == [1, 1, 1])
    }

    @Test func secondBootstrapReturnsSameWorkspaceWithoutConsumingIDs() throws {
        let fixture = try Fixture()
        let first = try fixture.service.bootstrap()

        let second = try fixture.service.bootstrap()

        #expect(second == first)
        #expect(try fixture.counts() == [1, 1, 1])
    }

    @Test func blogOnlyStorePreservesBlogAndCreatesMissingChildren() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        try fixture.insertBlog(id: blogID)

        let workspace = try fixture.service.bootstrap()

        #expect(workspace.blog.id == blogID)
        #expect(workspace.blogger.id == fixture.ids[0])
        #expect(workspace.mailingList.id == fixture.ids[1])
        #expect(workspace.blogger.blogID == blogID)
        #expect(workspace.mailingList.blogID == blogID)
        #expect(try fixture.counts() == [1, 1, 1])
    }

    @Test func blogAndBloggerStorePreservesBothAndCreatesOnlyList() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let bloggerID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        try fixture.insertBlog(id: blogID)
        try fixture.insertBlogger(id: bloggerID, blogID: blogID)

        let workspace = try fixture.service.bootstrap()

        #expect(workspace.blog.id == blogID)
        #expect(workspace.blogger.id == bloggerID)
        #expect(workspace.mailingList.id == fixture.ids[0])
        #expect(try fixture.counts() == [1, 1, 1])
    }

    @Test func existingFullWorkspaceIsReturned() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let bloggerID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let listID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        try fixture.insertBlog(id: blogID)
        try fixture.insertBlogger(id: bloggerID, blogID: blogID)
        try fixture.insertMailingList(id: listID, blogID: blogID)

        let workspace = try fixture.service.bootstrap()

        #expect(workspace.blog.id == blogID)
        #expect(workspace.blogger.id == bloggerID)
        #expect(workspace.mailingList.id == listID)
        #expect(try fixture.counts() == [1, 1, 1])
    }

    @Test func failedChildInsertRollsBackEntireWorkspace() throws {
        let fixture = try Fixture()
        try fixture.database.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_bootstrap_blogger
                BEFORE INSERT ON bloggers
                BEGIN
                  SELECT RAISE(ABORT, 'reject bootstrap blogger');
                END
                """)
        }

        #expect(throws: (any Error).self) {
            try fixture.service.bootstrap()
        }
        #expect(try fixture.counts() == [0, 0, 0])
    }

    @Test func emptyStoreSeedsDevelopmentJournalOnFirstRun() throws {
        let fixture = try Fixture()

        let workspace = try fixture.service.bootstrap(seed: DevelopmentSampleData.firstRunSeed)

        #expect(workspace.blog.title == BootstrapDefaults.blogTitle)
        #expect(workspace.blogger.displayName == "Rog")
        #expect(try fixture.count(in: "bloggers") == 2)
        #expect(try fixture.count(in: "trips") == 1)
        #expect(try fixture.count(in: "mediaAssets") == 7)
        #expect(try fixture.count(in: "blogItems") == 7)
    }

    @Test func developmentSeedIsIdempotent() throws {
        let fixture = try Fixture()

        _ = try fixture.service.bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        _ = try fixture.service.bootstrap(seed: DevelopmentSampleData.firstRunSeed)

        #expect(try fixture.count(in: "bloggers") == 2)
        #expect(try fixture.count(in: "trips") == 1)
        #expect(try fixture.count(in: "mediaAssets") == 7)
        #expect(try fixture.count(in: "blogItems") == 7)
    }

    @Test func existingBlogDoesNotReceiveDevelopmentSeed() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        try fixture.insertBlog(id: blogID)

        _ = try fixture.service.bootstrap(seed: DevelopmentSampleData.firstRunSeed)

        #expect(try fixture.count(in: "bloggers") == 1)
        #expect(try fixture.count(in: "trips") == 0)
        #expect(try fixture.count(in: "mediaAssets") == 0)
        #expect(try fixture.count(in: "blogItems") == 0)
    }
}

private final class UUIDSequence: @unchecked Sendable {
    private var values: ArraySlice<UUID>

    init(_ values: [UUID]) {
        self.values = values[...]
    }

    func next() -> UUID {
        precondition(!values.isEmpty, "Bootstrap consumed an unexpected UUID")
        return values.removeFirst()
    }
}

private struct Fixture {
    let database: any DatabaseWriter
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let ids = (1...24).map {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
    }
    let sequence: UUIDSequence

    var service: BlogBootstrapService {
        BlogBootstrapService(database: database, now: { date }, uuid: sequence.next)
    }

    init() throws {
        database = try AppDatabase.makeInMemory()
        sequence = UUIDSequence(ids)
    }

    func counts() throws -> [Int] {
        try database.read { db in
            try ["blogs", "bloggers", "mailingLists"].map { table in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")!
            }
        }
    }

    func count(in table: String) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")!
        }
    }

    func insertBlog(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO blogs (id, title, createdAt, updatedAt) VALUES (?, 'Existing Blog', ?, ?)",
                arguments: [id.uuidString, date, date]
            )
        }
    }

    func insertBlogger(id: UUID, blogID: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO bloggers (id, blogID, displayName, createdAt, updatedAt) VALUES (?, ?, 'Existing Blogger', ?, ?)",
                arguments: [id.uuidString, blogID.uuidString, date, date]
            )
        }
    }

    func insertMailingList(id: UUID, blogID: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO mailingLists (id, blogID, name, createdAt, updatedAt) VALUES (?, ?, 'Existing List', ?, ?)",
                arguments: [id.uuidString, blogID.uuidString, date, date]
            )
        }
    }
}
