import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Blog sharing service")
struct BlogSharingServiceTests {
    @Test func unsharedMetadataMapsToNotShared() {
        let metadata = BlogShareMetadata(
            isShared: false,
            currentUserIsOwner: false,
            currentUserCanWrite: false
        )

        #expect(metadata.shareState == .notShared)
    }

    @Test func sharedOwnerMetadataMapsToSharedOwner() {
        let metadata = BlogShareMetadata(
            isShared: true,
            currentUserIsOwner: true,
            currentUserCanWrite: true
        )

        #expect(metadata.shareState == .sharedOwner)
    }

    @Test func writableParticipantMetadataMapsToSharedParticipant() {
        let metadata = BlogShareMetadata(
            isShared: true,
            currentUserIsOwner: false,
            currentUserCanWrite: true
        )

        #expect(metadata.shareState == .sharedParticipant)
    }

    @Test func nonWritableShareMapsToUnavailable() {
        let metadata = BlogShareMetadata(
            isShared: true,
            currentUserIsOwner: false,
            currentUserCanWrite: false
        )

        #expect(metadata.shareState == .unavailable(message: "This shared blog is read-only."))
    }

    @MainActor
    @Test func testingPersistenceInitializesSyncEngineAndQueriesMissingShare() async throws {
        let persistence = try AppPersistence.makeTesting()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inserted = try await persistence.database.write { db in
            try Blog.insert { Blog.Draft(createdAt: now, updatedAt: now) }
                .returning(\.self)
                .fetchOne(db)
        }
        let blog = try #require(inserted)
        let metadataShare = try await persistence.database.read { db in
            try SyncMetadata
                .find(blog.syncMetadataID)
                .select(\.share)
                .fetchOne(db)
                ?? nil
        }

        let state = await BlogSharingService(persistence: persistence).shareState(for: blog.id)

        #expect(metadataShare == nil)
        #expect(state == .notShared)
    }
}
