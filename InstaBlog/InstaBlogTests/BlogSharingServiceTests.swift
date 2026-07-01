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
}
