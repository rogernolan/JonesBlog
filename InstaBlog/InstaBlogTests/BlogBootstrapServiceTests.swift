import Foundation
import GRDB
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Blog bootstrap")
struct BlogBootstrapServiceTests {
    @Test func freshBootstrapEstablishesActiveIdentityAndAllowsNameSave() async throws {
        let fixture = try Fixture()

        let workspace = try fixture.service.bootstrap()
        try await BlogSharingService.updateDisplayName(
            "Rog",
            bloggerID: workspace.blogger.id,
            database: fixture.database
        )

        let state = try await fixture.database.read { db in
            (
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.find(db, key: workspace.blog.id),
                try Blogger.find(db, key: workspace.blogger.id)
            )
        }
        #expect(state.0.activeBlogID == workspace.blog.id)
        #expect(state.1.bloggerID == workspace.blogger.id)
        #expect(state.2.displayName == "Rog")
    }

    @Test func emptyStoreCreatesOneRelatedWorkspaceWithInjectedValues() throws {
        let fixture = try Fixture()

        let workspace = try fixture.service.bootstrap()

        #expect(workspace.blog.id == fixture.ids[0])
        #expect(workspace.blog.title == "My Blog")
        #expect(workspace.blog.createdAt == fixture.date)
        #expect(workspace.blog.updatedAt == fixture.date)
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
        #expect(try fixture.count(in: "appBlogIdentities") == 1)
    }

    @Test func staleMappedBloggerRequiresExplicitSelectionFromAvailableBloggers() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "14000000-0000-0000-0000-000000000001")!
        let firstBloggerID = UUID(uuidString: "14000000-0000-0000-0000-000000000002")!
        let secondBloggerID = UUID(uuidString: "14000000-0000-0000-0000-000000000003")!
        let missingBloggerID = UUID(uuidString: "14000000-0000-0000-0000-000000000099")!
        try fixture.insertBlog(id: blogID)
        try fixture.insertBlogger(id: firstBloggerID, blogID: blogID)
        try fixture.insertBlogger(
            id: secondBloggerID,
            blogID: blogID,
            participantIdentifier: "participant"
        )
        try fixture.database.write { db in
            try AppBlogIdentity.insert {
                AppBlogIdentity.Draft(blogID: blogID, bloggerID: missingBloggerID)
            }.execute(db)
        }

        let preparation = try fixture.service.prepare()

        guard case .bloggerSelectionRequired(let requirement) = preparation else {
            Issue.record("Expected stale identity recovery to require a Blogger selection")
            return
        }
        #expect(requirement.blog.id == blogID)
        #expect(requirement.bloggers.map(\.id) == [firstBloggerID, secondBloggerID])
        let identity = try fixture.database.read {
            try AppBlogIdentity.find($0, key: blogID)
        }
        #expect(identity.bloggerID == missingBloggerID)
    }

    @Test func selectingAvailableBloggerRepairsStaleIdentity() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "14100000-0000-0000-0000-000000000001")!
        let availableBloggerID = UUID(uuidString: "14100000-0000-0000-0000-000000000002")!
        let missingBloggerID = UUID(uuidString: "14100000-0000-0000-0000-000000000099")!
        try fixture.insertBlog(id: blogID)
        try fixture.insertBlogger(id: availableBloggerID, blogID: blogID)
        try fixture.database.write { db in
            try AppBlogIdentity.insert {
                AppBlogIdentity.Draft(blogID: blogID, bloggerID: missingBloggerID)
            }.execute(db)
        }
        _ = try fixture.service.prepare()

        let workspace = try fixture.service.selectBlogger(
            blogID: blogID,
            bloggerID: availableBloggerID
        )

        #expect(workspace.blogger.id == availableBloggerID)
        let identity = try fixture.database.read {
            try AppBlogIdentity.find($0, key: blogID)
        }
        #expect(identity.bloggerID == availableBloggerID)
        #expect(try fixture.service.bootstrap().blogger.id == availableBloggerID)
    }

    @Test func creatingBloggerRepairsStaleIdentityWhenNoneRemain() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "14200000-0000-0000-0000-000000000001")!
        let missingBloggerID = UUID(uuidString: "14200000-0000-0000-0000-000000000099")!
        try fixture.insertBlog(id: blogID)
        try fixture.database.write { db in
            try AppBlogIdentity.insert {
                AppBlogIdentity.Draft(blogID: blogID, bloggerID: missingBloggerID)
            }.execute(db)
        }
        let preparation = try fixture.service.prepare()
        guard case .bloggerSelectionRequired(let requirement) = preparation else {
            Issue.record("Expected stale identity recovery to require a Blogger selection")
            return
        }
        #expect(requirement.bloggers.isEmpty)

        let workspace = try fixture.service.createAndSelectBlogger(
            blogID: blogID,
            displayName: "Jane"
        )

        #expect(workspace.blogger.displayName == "Jane")
        #expect(workspace.blogger.blogID == blogID)
        let identity = try fixture.database.read {
            try AppBlogIdentity.find($0, key: blogID)
        }
        #expect(identity.bloggerID == workspace.blogger.id)
    }

    @Test func legacyMultiBloggerWorkspaceMapsTheEarliestLocalOwner() throws {
        let fixture = try Fixture()
        let blogID = UUID(uuidString: "15000000-0000-0000-0000-000000000001")!
        let participantID = UUID(uuidString: "15000000-0000-0000-0000-000000000002")!
        let localOwnerID = UUID(uuidString: "15000000-0000-0000-0000-000000000003")!
        try fixture.insertBlog(id: blogID)
        try fixture.insertBlogger(
            id: participantID,
            blogID: blogID,
            participantIdentifier: "participant"
        )
        try fixture.insertBlogger(id: localOwnerID, blogID: blogID)

        let workspace = try fixture.service.bootstrap()

        let identity = try fixture.database.read {
            try AppBlogIdentity.find($0, key: blogID)
        }
        #expect(workspace.blogger.id == localOwnerID)
        #expect(identity.bloggerID == localOwnerID)
    }

    @Test func bootstrapPreservesAcceptedWorkspaceAndMappedParticipant() throws {
        let fixture = try Fixture()
        let localBlogID = UUID(uuidString: "16000000-0000-0000-0000-000000000001")!
        let localOwnerID = UUID(uuidString: "16000000-0000-0000-0000-000000000002")!
        let acceptedBlogID = UUID(uuidString: "16000000-0000-0000-0000-000000000010")!
        let mappedID = UUID(uuidString: "16000000-0000-0000-0000-000000000011")!
        try fixture.insertBlog(id: localBlogID)
        try fixture.insertBlogger(id: localOwnerID, blogID: localBlogID)
        try fixture.insertBlog(id: acceptedBlogID)
        try fixture.insertBlogger(
            id: mappedID,
            blogID: acceptedBlogID,
            participantIdentifier: "accepted-participant"
        )
        try fixture.database.write { db in
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(acceptedBlogID) }
                .execute(db)
            try AppBlogIdentity.insert {
                AppBlogIdentity.Draft(blogID: acceptedBlogID, bloggerID: mappedID)
            }.execute(db)
        }

        let workspace = try fixture.service.bootstrap()

        let state = try fixture.database.read { db in
            (
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.find(db, key: acceptedBlogID),
                try AppBlogIdentity.find(db, key: localBlogID)
            )
        }
        #expect(workspace.blog.id == localBlogID)
        #expect(workspace.blogger.id == localOwnerID)
        #expect(state.0.activeBlogID == acceptedBlogID)
        #expect(state.1.bloggerID == mappedID)
        #expect(state.2.bloggerID == localOwnerID)
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
        #expect(try fixture.count(in: "photoItems") == 7)
    }

    @Test func developmentSeedIsIdempotent() throws {
        let fixture = try Fixture()

        _ = try fixture.service.bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        _ = try fixture.service.bootstrap(seed: DevelopmentSampleData.firstRunSeed)

        #expect(try fixture.count(in: "bloggers") == 2)
        #expect(try fixture.count(in: "trips") == 1)
        #expect(try fixture.count(in: "mediaAssets") == 7)
        #expect(try fixture.count(in: "blogItems") == 7)
        #expect(try fixture.count(in: "photoItems") == 7)
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
    let ids = (1...32).map {
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

    func insertBlogger(
        id: UUID,
        blogID: UUID,
        participantIdentifier: String? = nil
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bloggers
                      (id, blogID, displayName, createdAt, updatedAt, cloudKitParticipantIdentifier)
                    VALUES (?, ?, 'Existing Blogger', ?, ?, ?)
                    """,
                arguments: [id.uuidString, blogID.uuidString, date, date, participantIdentifier]
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
