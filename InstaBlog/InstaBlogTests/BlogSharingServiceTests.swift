import CloudKit
import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Blog sharing service")
struct BlogSharingServiceTests {
    @MainActor
    private final class ShareCallCounter {
        var count = 0
    }

    private enum StubError: Error {
        case unexpectedShare
    }

    private final class ReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var readCount = 0
        private(set) var readOccurredOnMainThread = false

        func recordRead() {
            lock.withLock {
                readCount += 1
                readOccurredOnMainThread = readOccurredOnMainThread || Thread.isMainThread
            }
        }
    }

    @Test(arguments: [
        (CKShare.ParticipantPermission.readWrite, CKShare.ParticipantPermission.none, true),
        (.readOnly, .readWrite, true),
        (.readOnly, .none, false),
        (.none, .none, false),
        (.unknown, .none, false),
    ])
    func invitationPermissionRequiresEffectiveReadWrite(
        participant: CKShare.ParticipantPermission,
        publicPermission: CKShare.ParticipantPermission,
        expected: Bool
    ) {
        #expect(
            BlogSharingService.invitationAllowsWriting(
                participantPermission: participant,
                publicPermission: publicPermission
            ) == expected
        )
    }

    @Test(arguments: [
        (CKAccountStatus.available, nil),
        (.noAccount, "Sign in to iCloud"),
        (.restricted, "restricted"),
        (.couldNotDetermine, "could not be confirmed"),
        (.temporarilyUnavailable, "temporarily unavailable"),
    ])
    func accountAvailabilityMessagesAreActionable(
        status: CKAccountStatus,
        expectedFragment: String?
    ) {
        let message = BlogSharingService.accountUnavailableMessage(for: status)
        if let expectedFragment {
            #expect(message?.localizedCaseInsensitiveContains(expectedFragment) == true)
        } else {
            #expect(message == nil)
        }
    }

    @MainActor
    @Test func existingPhotoFileIsValidatedWithoutCreatingBlobRows() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        let mediaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharingBackfill-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let photoData = Data([1, 2, 3])
        let photoURL = mediaDirectory.appendingPathComponent("prior.jpg")
        try photoData.write(to: photoURL)
        _ = try await Self.insertReferencedPhoto(
            in: persistence.database,
            workspace: workspace,
            path: photoURL.path
        )
        let service = BlogSharingService(
            persistence: persistence,
            mediaDirectoryURL: mediaDirectory
        )

        try await service.backfillReferencedMediaData(for: workspace.blog.id)
        try await service.backfillReferencedMediaData(for: workspace.blog.id)

        let hasBlobTable = try await persistence.database.read {
            try $0.tableExists("mediaAssetData")
        }
        #expect(!hasBlobTable)
    }

    @MainActor
    @Test func manyPhotosAreValidatedWithoutReadingBytesIntoMemory() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        let mediaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharingBackfill-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let photoCount = 24
        for index in 0..<photoCount {
            let photoURL = mediaDirectory.appendingPathComponent("photo-\(index).jpg")
            try Data(repeating: UInt8(index), count: 1_024).write(to: photoURL)
            _ = try await Self.insertReferencedPhoto(
                in: persistence.database,
                workspace: workspace,
                path: photoURL.path
            )
        }
        let probe = ReadProbe()
        let service = BlogSharingService(
            persistence: persistence,
            mediaDirectoryURL: mediaDirectory,
            mediaDataReader: { url in
                probe.recordRead()
                return try Data(contentsOf: url)
            }
        )

        try await service.backfillReferencedMediaData(for: workspace.blog.id)

        #expect(probe.readCount == 0)
    }

    @MainActor
    @Test func unsafeOrMissingPhotoFailsWithoutPartialBackfill() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        let mediaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharingBackfill-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let validURL = mediaDirectory.appendingPathComponent("valid.jpg")
        try Data([1]).write(to: validURL)
        _ = try await Self.insertReferencedPhoto(
            in: persistence.database,
            workspace: workspace,
            path: validURL.path
        )
        _ = try await Self.insertReferencedPhoto(
            in: persistence.database,
            workspace: workspace,
            path: mediaDirectory.deletingLastPathComponent().appendingPathComponent("outside.jpg").path
        )
        let shareCalls = ShareCallCounter()
        let service = BlogSharingService(
            persistence: persistence,
            mediaDirectoryURL: mediaDirectory,
            accountStatus: { .available },
            createShare: { _, _ in
                shareCalls.count += 1
                throw StubError.unexpectedShare
            }
        )

        await #expect(throws: BlogSharingServiceError.self) {
            _ = try await service.prepareShare(for: workspace.blog.id, title: "Trip")
        }
        #expect(shareCalls.count == 0)
    }

    @MainActor
    @Test func canonicalCurrentPhotoAllowsSharingWhenStoredLegacyPathIsStale() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        let mediaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharingBackfill-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDirectory) }
        let mediaID = try await Self.insertReferencedPhoto(
            in: persistence.database,
            workspace: workspace,
            path: "/stale/container/BlogItemMedia/photo.jpg"
        )
        let photoData = Data([4, 5, 6])
        try photoData.write(
            to: mediaDirectory.appendingPathComponent("\(mediaID.uuidString).jpg")
        )
        let shareCalls = ShareCallCounter()
        let service = BlogSharingService(
            persistence: persistence,
            mediaDirectoryURL: mediaDirectory,
            accountStatus: { .available },
            createShare: { _, _ in
                shareCalls.count += 1
                throw StubError.unexpectedShare
            }
        )

        await #expect(throws: StubError.self) {
            _ = try await service.prepareShare(for: workspace.blog.id, title: "Trip")
        }

        #expect(shareCalls.count == 1)
    }

    @Test @MainActor func unavailableSharingStillPersistsIdentityLocally() async throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        try await Self.activate(workspace.blog.id, in: database)
        let service = UnavailableBlogSharingService(database: database)

        try await service.updateDisplayName("  Jane  ", bloggerID: workspace.blogger.id)

        let persistedName = try await database.read { db in
            try Blogger.find(db, key: workspace.blogger.id).displayName
        }
        #expect(persistedName == "Jane")
    }

    @Test @MainActor func firstActiveBlogNameUpdatePinsTheSoleBloggerIdentity() async throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        try await Self.activate(workspace.blog.id, in: database)

        try await BlogSharingService.updateDisplayName(
            "Jane",
            bloggerID: workspace.blogger.id,
            database: database
        )

        let identity = try await database.read {
            try AppBlogIdentity.find($0, key: workspace.blog.id)
        }
        #expect(identity.bloggerID == workspace.blogger.id)
    }

    @Test @MainActor func unmappedActiveBlogRejectsAnAmbiguousBlogger() async throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        try await Self.activate(workspace.blog.id, in: database)
        let otherID = UUID()
        try await database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    id: otherID,
                    blogID: workspace.blog.id,
                    displayName: "Other",
                    createdAt: .now,
                    updatedAt: .now
                )
            }.execute(db)
        }

        await #expect(throws: BlogSharingServiceError.self) {
            try await BlogSharingService.updateDisplayName(
                "Wrong",
                bloggerID: otherID,
                database: database
            )
        }
    }

    @Test @MainActor func mappedActiveBloggerCanUpdateButAnotherBloggerCannot() async throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        try await Self.activate(workspace.blog.id, in: database)
        try await BlogSharingService.updateDisplayName(
            "Jane",
            bloggerID: workspace.blogger.id,
            database: database
        )
        let otherID = UUID()
        try await database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    id: otherID,
                    blogID: workspace.blog.id,
                    displayName: "Other",
                    createdAt: .now,
                    updatedAt: .now
                )
            }.execute(db)
        }

        try await BlogSharingService.updateDisplayName(
            "Janet",
            bloggerID: workspace.blogger.id,
            database: database
        )
        await #expect(throws: BlogSharingServiceError.self) {
            try await BlogSharingService.updateDisplayName(
                "Wrong",
                bloggerID: otherID,
                database: database
            )
        }
    }

    @Test @MainActor func staleNameSaveAfterWorkspaceSwitchIsRejected() async throws {
        let database = try AppDatabase.makeInMemory()
        let original = try BlogBootstrapService(database: database).bootstrap()
        let currentBlog = try await Self.insertBlog(in: database, title: "Current")
        try await database.write { db in
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(currentBlog.id) }
                .execute(db)
        }

        await #expect(throws: BlogSharingServiceError.self) {
            try await BlogSharingService.updateDisplayName(
                "Stale",
                bloggerID: original.blogger.id,
                database: database
            )
        }
    }

    @Test @MainActor func unavailableSharingChecksMeaningfulBlogLocally() async throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        let service = UnavailableBlogSharingService(database: database)

        #expect(try await !service.isMeaningfulBlog(workspace.blog.id))
        try await database.write { db in
            try Blog.find(workspace.blog.id)
                .update { $0.title = "Edited" }
                .execute(db)
        }
        #expect(try await service.isMeaningfulBlog(workspace.blog.id))
    }

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

        let state = await BlogSharingService(
            persistence: persistence,
            accountStatus: { .available }
        ).shareState(for: blog.id)

        #expect(metadataShare == nil)
        #expect(state == .notShared)
    }

    @MainActor
    @Test func unavailableAccountIsReportedBeforeReadingShareMetadata() async throws {
        let persistence = try AppPersistence.makeTesting()
        let missingBlogID = UUID()
        let service = BlogSharingService(
            persistence: persistence,
            accountStatus: { .noAccount }
        )

        let state = await service.shareState(for: missingBlogID)

        guard case let .unavailable(message) = state else {
            Issue.record("Expected unavailable account state")
            return
        }
        #expect(message.contains("Sign in to iCloud"))
    }

    @MainActor
    @Test func bootstrapDefaultsAreNotMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()

        #expect(try await !BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func blogItemMakesBlogMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await persistence.database.write { db in
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: workspace.blog.id,
                    authorID: workspace.blogger.id,
                    caption: "A real entry",
                    createdAt: now,
                    updatedAt: now,
                    itemDate: now,
                    localDay: "2027-01-15"
                )
            }.execute(db)
        }

        #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func developmentSeedAloneIsNotMeaningfulButAnEditedSeedIs() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        let service = BlogSharingService(persistence: persistence)

        #expect(try await !service.isMeaningfulBlog(workspace.blog.id))
        try await persistence.database.write { db in
            let fetchedTrip = try Trip.where { $0.blogID.eq(workspace.blog.id) }.fetchOne(db)
            let trip = try #require(fetchedTrip)
            try Trip.find(trip.id).update { $0.title = "Our Provence Trip" }.execute(db)
        }
        #expect(try await service.isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func duplicateSeedBloggerMakesDevelopmentWorkspaceMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        try await persistence.database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    blogID: workspace.blog.id,
                    displayName: "Jane",
                    createdAt: workspace.blog.createdAt,
                    updatedAt: workspace.blog.updatedAt
                )
            }.execute(db)
        }

        #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func duplicateSeedItemMakesDevelopmentWorkspaceMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        try await persistence.database.write { db in
            let fetchedItem = try BlogItem.where { $0.blogID.eq(workspace.blog.id) }.fetchOne(db)
            let item = try #require(fetchedItem)
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: item.blogID,
                    authorID: item.authorID,
                    caption: item.caption,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    itemDate: item.itemDate,
                    itemTimeZoneIdentifier: item.itemTimeZoneIdentifier,
                    localDay: item.localDay,
                    latitude: item.latitude,
                    longitude: item.longitude,
                    locationName: item.locationName,
                    countryCode: item.countryCode,
                    weatherTemperatureCelsius: item.weatherTemperatureCelsius,
                    weatherConditionCode: item.weatherConditionCode,
                    photoAssetID: item.photoAssetID,
                    deletedAt: item.deletedAt
                )
            }.execute(db)
        }

        #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func extraNilCaptionPhotoItemMakesDevelopmentWorkspaceMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        let mediaID = UUID()
        try await persistence.database.write { db in
            try MediaAsset.insert {
                MediaAsset.Draft(
                    id: mediaID,
                    blogID: workspace.blog.id,
                    filename: "extra.jpg",
                    mimeType: "image/jpeg",
                    createdAt: workspace.blog.createdAt,
                    updatedAt: workspace.blog.updatedAt
                )
            }.execute(db)
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: workspace.blog.id,
                    authorID: workspace.blogger.id,
                    createdAt: workspace.blog.createdAt,
                    updatedAt: workspace.blog.updatedAt,
                    itemDate: workspace.blog.createdAt,
                    localDay: "2026-06-19",
                    photoAssetID: mediaID
                )
            }.execute(db)
        }

        #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func editingPreviouslyIgnoredItemFieldMakesDevelopmentWorkspaceMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        try await persistence.database.write { db in
            let fetchedItem = try BlogItem.where { $0.blogID.eq(workspace.blog.id) }.fetchOne(db)
            let item = try #require(fetchedItem)
            try BlogItem.find(item.id).update { $0.latitude = #bind(48.8566) }.execute(db)
        }

        #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func editingTripHeroOrClosedStateMakesDevelopmentWorkspaceMeaningful() async throws {
        for editHero in [true, false] {
            let persistence = try AppPersistence.makeTesting()
            let workspace = try BlogBootstrapService(database: persistence.database)
                .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
            try await persistence.database.write { db in
                let fetchedTrip = try Trip.where { $0.blogID.eq(workspace.blog.id) }.fetchOne(db)
                let trip = try #require(fetchedTrip)
                if editHero {
                    let heroID = UUID()
                    try Trip.find(trip.id).update { $0.heroImageAssetID = #bind(heroID) }.execute(db)
                } else {
                    try Trip.find(trip.id).update { $0.closedAt = #bind(Date.distantPast) }.execute(db)
                }
            }
            #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
        }
    }

    @MainActor
    @Test func tripSubscriberAndPublishEventEachMakeABlogMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        let service = BlogSharingService(persistence: persistence)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await persistence.database.write { db in
            try Trip.insert {
                Trip.Draft(
                    blogID: workspace.blog.id,
                    title: "Scotland",
                    description: "",
                    startLocalDay: "2027-01-01",
                    heroImageAssetID: nil,
                    createdAt: now,
                    updatedAt: now,
                    closedAt: nil,
                    deletedAt: nil
                )
            }.execute(db)
        }
        #expect(try await service.isMeaningfulBlog(workspace.blog.id))

        try await persistence.database.write { db in
            try Trip.where { $0.blogID.eq(workspace.blog.id) }.delete().execute(db)
            try Subscriber.insert {
                Subscriber.Draft(
                    blogID: workspace.blog.id,
                    mailingListID: workspace.mailingList.id,
                    emailAddress: "reader@example.com",
                    createdAt: now,
                    updatedAt: now
                )
            }.execute(db)
        }
        #expect(try await service.isMeaningfulBlog(workspace.blog.id))

        try await persistence.database.write { db in
            try Subscriber.where { $0.blogID.eq(workspace.blog.id) }.delete().execute(db)
            try PublishEvent.insert {
                PublishEvent.Draft(
                    blogID: workspace.blog.id,
                    localDay: "2027-01-01",
                    mailingListID: workspace.mailingList.id,
                    initiatedAt: now,
                    initiatedByBloggerID: workspace.blogger.id,
                    recipientCount: 0
                )
            }.execute(db)
        }
        #expect(try await service.isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test(arguments: ["title", "interval", "distance", "blogger"])
    func editedBootstrapPropertiesMakeBlogMeaningful(_ edit: String) async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        try await persistence.database.write { db in
            switch edit {
            case "title":
                try Blog.find(workspace.blog.id).update { $0.title = "Our Travels" }.execute(db)
            case "interval":
                try Blog.find(workspace.blog.id).update { $0.galleryIntervalSeconds = 600 }.execute(db)
            case "distance":
                try Blog.find(workspace.blog.id).update { $0.galleryDistanceMeters = 250 }.execute(db)
            default:
                try Blogger.find(workspace.blogger.id).update { $0.displayName = "Rog" }.execute(db)
            }
        }

        #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func participantAcceptanceIsIdempotentAndUpdatesTheWorkspace() async throws {
        let persistence = try AppPersistence.makeTesting()
        let original = try BlogBootstrapService(database: persistence.database).bootstrap()
        let sharedBlog = try await Self.insertBlog(in: persistence.database, title: "Shared")
        let service = BlogSharingService(persistence: persistence)

        let first = try await service.acceptSharedBlog(
            sharedBlog,
            participant: ParticipantIdentity(identifier: "participant-1", displayName: "Jane")
        )
        let second = try await service.acceptSharedBlog(
            sharedBlog,
            participant: ParticipantIdentity(identifier: "participant-1", displayName: "Janet")
        )
        let third = try await service.acceptSharedBlog(
            sharedBlog,
            participant: ParticipantIdentity(identifier: nil, displayName: nil)
        )
        let snapshot = try await persistence.database.read { db in
            (
                try Blogger.where { $0.blogID.eq(sharedBlog.id) }.fetchAll(db),
                try AppWorkspace.find(db, key: AppWorkspace.singletonID)
            )
        }

        #expect(first.bloggerID == second.bloggerID)
        #expect(second.bloggerID == third.bloggerID)
        #expect(snapshot.0.count == 1)
        #expect(snapshot.0[0].displayName == "Janet")
        #expect(snapshot.0[0].cloudKitParticipantIdentifier == "participant-1")
        #expect(snapshot.1.activeBlogID == sharedBlog.id)
        #expect(snapshot.1.activeBlogID != original.blog.id)
    }

    @Test func freshPlaceholderIsReplacedBySyncedOwnerBlog() async throws {
        let persistence = try AppPersistence.makeTesting()
        let placeholder = try BlogBootstrapService(database: persistence.database).bootstrap()
        let ownerBlog = try await Self.insertBlog(
            in: persistence.database,
            title: "Jones the Van"
        )
        let ownerBloggerID = UUID()
        try await persistence.database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    id: ownerBloggerID,
                    blogID: ownerBlog.id,
                    displayName: "Rog",
                    createdAt: .now,
                    updatedAt: .now
                )
            }.execute(db)
        }

        try await BlogSharingService.restoreOwnedBlogIfNeeded(
            database: persistence.database,
            restorableBlogs: [(ownerBlog.id, nil)]
        )

        let state = try await persistence.database.read { db in
            (
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.find(db, key: ownerBlog.id)
            )
        }
        #expect(state.0.activeBlogID == ownerBlog.id)
        #expect(state.0.activeBlogID != placeholder.blog.id)
        #expect(state.1.bloggerID == ownerBloggerID)
    }

    @Test func freshPlaceholderIsReplacedBySameAccountPrivateBlog() async throws {
        let persistence = try AppPersistence.makeTesting()
        let placeholder = try BlogBootstrapService(database: persistence.database).bootstrap()
        let privateBlog = try await Self.insertBlog(
            in: persistence.database,
            title: "Jones the Van"
        )
        let privateBloggerID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await persistence.database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    id: privateBloggerID,
                    blogID: privateBlog.id,
                    displayName: "Rog",
                    createdAt: now,
                    updatedAt: now
                )
            }.execute(db)
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: privateBlog.id,
                    authorID: privateBloggerID,
                    caption: "Synced from phone",
                    createdAt: now,
                    updatedAt: now,
                    itemDate: now,
                    localDay: "2026-07-09"
                )
            }.execute(db)
        }

        try await BlogSharingService.restoreOwnedBlogIfNeeded(
            database: persistence.database,
            restorableBlogs: [(placeholder.blog.id, nil), (privateBlog.id, nil)]
        )

        let state = try await persistence.database.read { db in
            (
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.find(db, key: privateBlog.id)
            )
        }
        #expect(state.0.activeBlogID == privateBlog.id)
        #expect(state.1.bloggerID == privateBloggerID)
    }

    @Test func freshPlaceholderIsNotReplacedByAnotherPlaceholder() async throws {
        let persistence = try AppPersistence.makeTesting()
        let active = try BlogBootstrapService(database: persistence.database).bootstrap()
        let emptyBlog = try await Self.insertBlog(
            in: persistence.database,
            title: BootstrapDefaults.blogTitle
        )
        try await persistence.database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    blogID: emptyBlog.id,
                    displayName: BootstrapDefaults.bloggerDisplayName,
                    createdAt: emptyBlog.createdAt,
                    updatedAt: emptyBlog.updatedAt
                )
            }.execute(db)
            try MailingList.insert {
                MailingList.Draft(
                    blogID: emptyBlog.id,
                    createdAt: emptyBlog.createdAt,
                    updatedAt: emptyBlog.updatedAt
                )
            }.execute(db)
        }

        try await BlogSharingService.restoreOwnedBlogIfNeeded(
            database: persistence.database,
            restorableBlogs: [(emptyBlog.id, nil)]
        )

        let activeBlogID = try await persistence.database.read { db in
            try AppWorkspace.find(db, key: AppWorkspace.singletonID).activeBlogID
        }
        #expect(activeBlogID == active.blog.id)
    }

    @Test func starterBlogIsReplacedByMoreCompleteSyncedBlog() async throws {
        let persistence = try AppPersistence.makeTesting()
        let active = try BlogBootstrapService(database: persistence.database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        let syncedBlog = try await Self.insertBlog(
            in: persistence.database,
            title: "My Blog"
        )
        let syncedBloggerID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await persistence.database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    id: syncedBloggerID,
                    blogID: syncedBlog.id,
                    displayName: "Roger",
                    createdAt: now,
                    updatedAt: now
                )
            }.execute(db)
            for index in 0..<24 {
                try BlogItem.insert {
                    BlogItem.Draft(
                        blogID: syncedBlog.id,
                        authorID: syncedBloggerID,
                        caption: "Synced entry \(index)",
                        createdAt: now,
                        updatedAt: now,
                        itemDate: now.addingTimeInterval(Double(index)),
                        localDay: "2026-07-09"
                    )
                }.execute(db)
            }
        }

        try await BlogSharingService.restoreOwnedBlogIfNeeded(
            database: persistence.database,
            restorableBlogs: [(syncedBlog.id, nil)]
        )

        let state = try await persistence.database.read { db in
            (
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.find(db, key: syncedBlog.id)
            )
        }
        #expect(state.0.activeBlogID == syncedBlog.id)
        #expect(state.0.activeBlogID != active.blog.id)
        #expect(state.1.bloggerID == syncedBloggerID)
    }

    @Test func meaningfulActiveBlogIsNotReplacedByAnotherOwnerBlog() async throws {
        let persistence = try AppPersistence.makeTesting()
        let active = try BlogBootstrapService(database: persistence.database).bootstrap()
        let ownerBlog = try await Self.insertBlog(
            in: persistence.database,
            title: "Another Blog"
        )
        try await persistence.database.write { db in
            try Blog.find(active.blog.id)
                .update { $0.title = "My Existing Blog" }
                .execute(db)
        }

        try await BlogSharingService.restoreOwnedBlogIfNeeded(
            database: persistence.database,
            restorableBlogs: [(ownerBlog.id, nil)]
        )

        let activeBlogID = try await persistence.database.read { db in
            try AppWorkspace.find(db, key: AppWorkspace.singletonID).activeBlogID
        }
        #expect(activeBlogID == active.blog.id)
    }

    @MainActor
    @Test func sharedBlogLookupRetriesWhileCloudKitImportFinishes() async throws {
        let persistence = try AppPersistence.makeTesting()
        let blogID = UUID()
        var syncCount = 0
        var delays: [Duration] = []

        let blog = try await BlogSharingService.awaitSharedBlog(
            blogID,
            database: persistence.database,
            sleep: { delays.append($0) },
            syncChanges: {
                syncCount += 1
                try await persistence.database.write { db in
                    try Blog.insert {
                        Blog.Draft(
                            id: blogID,
                            title: "Shared",
                            createdAt: .now,
                            updatedAt: .now
                        )
                    }
                    .execute(db)
                }
            }
        )

        #expect(blog.id == blogID)
        #expect(syncCount == 1)
        #expect(delays == [.milliseconds(500)])
    }

    @MainActor
    @Test func acceptanceDoesNotHijackExistingOwnerWithoutParticipantIdentifier() async throws {
        let persistence = try AppPersistence.makeTesting()
        _ = try BlogBootstrapService(database: persistence.database).bootstrap()
        let sharedBlog = try await Self.insertBlog(in: persistence.database, title: "Shared")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await persistence.database.write { db in
            try Blogger.insert {
                Blogger.Draft(blogID: sharedBlog.id, displayName: "Owner", createdAt: now, updatedAt: now)
            }.execute(db)
        }
        let service = BlogSharingService(persistence: persistence)
        let first = try await service.acceptSharedBlog(
            sharedBlog,
            participant: ParticipantIdentity(identifier: nil, displayName: nil)
        )
        let second = try await service.acceptSharedBlog(
            sharedBlog,
            participant: ParticipantIdentity(identifier: "participant", displayName: "Jane")
        )
        let bloggers = try await persistence.database.read {
            try Blogger.where { $0.blogID.eq(sharedBlog.id) }.fetchAll($0)
        }
        #expect(first.bloggerID == second.bloggerID)
        #expect(bloggers.count == 2)
        #expect(bloggers.contains { $0.displayName == "Owner" && $0.cloudKitParticipantIdentifier == nil })
        #expect(bloggers.contains { $0.id == first.bloggerID && $0.cloudKitParticipantIdentifier == "participant" })
    }

    @Test func rootRecordValidationRejectsMalformedAndNonBlogRecords() throws {
        #expect(throws: BlogSharingServiceError.self) {
            try BlogSharingService.validatedBlogID(recordName: nil)
        }
        #expect(throws: BlogSharingServiceError.self) {
            try BlogSharingService.validatedBlogID(recordName: "\(UUID()):trips")
        }
        let id = UUID()
        #expect(try BlogSharingService.validatedBlogID(recordName: "\(id.uuidString):blogs") == id)
    }

    @MainActor
    @Test func mediaDataAndMailingListChangesAreMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mediaID = UUID()
        try await persistence.database.write { db in
            try MediaAsset.insert {
                MediaAsset.Draft(id: mediaID, blogID: workspace.blog.id, filename: "only.jpg", mimeType: "image/jpeg", createdAt: now, updatedAt: now)
            }.execute(db)
        }
        let service = BlogSharingService(persistence: persistence)
        #expect(try await service.isMeaningfulBlog(workspace.blog.id))
        try await persistence.database.write { db in
            try MailingList.find(workspace.mailingList.id).update { $0.name = #bind("Friends") }.execute(db)
        }
        #expect(try await service.isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func remoteMediaMetadataOnAnOtherwiseExactDevelopmentSeedIsMeaningful() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database)
            .bootstrap(seed: DevelopmentSampleData.firstRunSeed)
        try await persistence.database.write { db in
            let fetchedMedia = try MediaAsset.where { $0.blogID.eq(workspace.blog.id) }.fetchOne(db)
            let media = try #require(fetchedMedia)
            try MediaAsset.find(media.id).update {
                $0.cloudAssetIdentifier = #bind("remote-object")
                $0.cloudAssetHash = #bind("abc")
            }.execute(db)
        }
        #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
    }

    @MainActor
    @Test func mailingListEditAndExtraListAreEachMeaningful() async throws {
        for addExtra in [false, true] {
            let persistence = try AppPersistence.makeTesting()
            let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
            try await persistence.database.write { db in
                if addExtra {
                    try MailingList.insert {
                        MailingList.Draft(
                            blogID: workspace.blog.id,
                            createdAt: workspace.blog.createdAt,
                            updatedAt: workspace.blog.updatedAt
                        )
                    }.execute(db)
                } else {
                    try MailingList.find(workspace.mailingList.id)
                        .update { $0.name = #bind("Friends") }
                        .execute(db)
                }
            }
            #expect(try await BlogSharingService(persistence: persistence).isMeaningfulBlog(workspace.blog.id))
        }
    }

    @MainActor
    @Test func missingParticipantIdentityUsesOneFallbackBlogger() async throws {
        let persistence = try AppPersistence.makeTesting()
        _ = try BlogBootstrapService(database: persistence.database).bootstrap()
        let sharedBlog = try await Self.insertBlog(in: persistence.database, title: "Shared")
        let service = BlogSharingService(persistence: persistence)

        let first = try await service.acceptSharedBlog(
            sharedBlog,
            participant: ParticipantIdentity(identifier: nil, displayName: nil)
        )
        let second = try await service.acceptSharedBlog(
            sharedBlog,
            participant: ParticipantIdentity(identifier: nil, displayName: " ")
        )

        #expect(first == second)
        let bloggers = try await persistence.database.read {
            try Blogger.where { $0.blogID.eq(sharedBlog.id) }.fetchAll($0)
        }
        #expect(bloggers.count == 1)
        #expect(bloggers[0].displayName == "Blogger")
    }

    @MainActor
    @Test func failedParticipantUpsertDoesNotSwitchWorkspace() async throws {
        let persistence = try AppPersistence.makeTesting()
        let original = try BlogBootstrapService(database: persistence.database).bootstrap()
        try await persistence.database.write { db in
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(original.blog.id) }
                .execute(db)
        }
        let missingBlog = Blog(
            id: UUID(),
            title: "Missing",
            createdAt: .now,
            updatedAt: .now
        )

        await #expect(throws: (any Error).self) {
            try await BlogSharingService(persistence: persistence).acceptSharedBlog(
                missingBlog,
                participant: ParticipantIdentity(identifier: "participant-1", displayName: "Jane")
            )
        }
        let workspace = try await persistence.database.read {
            try AppWorkspace.find($0, key: AppWorkspace.singletonID)
        }
        #expect(workspace.activeBlogID == original.blog.id)
    }

    @MainActor
    @Test func displayNameIsTrimmedAndEmptyNamesAreRejected() async throws {
        let persistence = try AppPersistence.makeTesting()
        let workspace = try BlogBootstrapService(database: persistence.database).bootstrap()
        try await Self.activate(workspace.blog.id, in: persistence.database)
        let service = BlogSharingService(persistence: persistence)

        try await service.updateDisplayName("  Rog  ", bloggerID: workspace.blogger.id)
        let updated = try await persistence.database.read {
            try Blogger.find($0, key: workspace.blogger.id)
        }
        #expect(updated.displayName == "Rog")
        await #expect(throws: BlogSharingServiceError.self) {
            try await service.updateDisplayName(" \n ", bloggerID: workspace.blogger.id)
        }
    }

    private static func insertBlog(
        in database: any DatabaseWriter,
        title: String
    ) async throws -> Blog {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return try #require(await database.write { db in
            try Blog.insert {
                Blog.Draft(title: title, createdAt: now, updatedAt: now)
            }.returning(\.self).fetchOne(db)
        })
    }

    private static func activate(
        _ blogID: Blog.ID,
        in database: any DatabaseWriter
    ) async throws {
        try await database.write { db in
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(blogID) }
                .execute(db)
        }
    }

    private static func insertReferencedPhoto(
        in database: any DatabaseWriter,
        workspace: BootstrapWorkspace,
        path: String
    ) async throws -> MediaAsset.ID {
        let mediaID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await database.write { db in
            try MediaAsset.insert {
                MediaAsset.Draft(
                    id: mediaID,
                    blogID: workspace.blog.id,
                    localOriginalPath: path,
                    filename: "\(mediaID).jpg",
                    mimeType: "image/jpeg",
                    createdAt: now,
                    updatedAt: now
                )
            }.execute(db)
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: workspace.blog.id,
                    authorID: workspace.blogger.id,
                    createdAt: now,
                    updatedAt: now,
                    itemDate: now,
                    localDay: "2027-01-15",
                    photoAssetID: mediaID
                )
            }.execute(db)
        }
        return mediaID
    }
}
