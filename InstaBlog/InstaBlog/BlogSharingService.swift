import CloudKit
import SQLiteData
import UIKit

nonisolated enum BlogShareState: Equatable {
    case notShared
    case sharedOwner
    case sharedParticipant
    case unavailable(message: String)
    case error(message: String)
}

nonisolated struct BlogShareMetadata: Equatable {
    var isShared: Bool
    var currentUserIsOwner: Bool
    var currentUserCanWrite: Bool

    var shareState: BlogShareState {
        guard isShared else {
            return .notShared
        }
        if currentUserIsOwner {
            return .sharedOwner
        }
        if currentUserCanWrite {
            return .sharedParticipant
        }
        return .unavailable(message: "This shared blog is read-only.")
    }
}

nonisolated struct AcceptedBlog: Equatable {
    let blogID: Blog.ID
    let bloggerID: Blogger.ID
}

nonisolated struct ParticipantIdentity: Equatable, Sendable {
    let identifier: String?
    let displayName: String?
}

@MainActor
protocol BlogSharingServiceProtocol {
    func shareState(for blogID: Blog.ID) async -> BlogShareState
    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord
    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool
    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog
    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws
}

@MainActor
final class BlogSharingService: BlogSharingServiceProtocol {
    static let availablePermissions: UICloudSharingController.PermissionOptions = [.allowReadWrite]

    private let database: any DatabaseWriter
    private let syncEngine: SyncEngine

    init(persistence: AppPersistence) {
        self.database = persistence.database
        self.syncEngine = persistence.syncEngine
    }

    func shareState(for blogID: Blog.ID) async -> BlogShareState {
        do {
            let share = try await database.read { db -> CKShare? in
                let blog = try Blog.find(db, key: blogID)
                return try SyncMetadata
                    .find(blog.syncMetadataID)
                    .select(\.share)
                    .fetchOne(db)
                    ?? nil
            }
            guard let share else {
                return .notShared
            }
            let participant = share.currentUserParticipant
            return BlogShareMetadata(
                isShared: true,
                currentUserIsOwner: participant?.role == .owner,
                currentUserCanWrite: participant?.permission == .readWrite
                    || share.publicPermission == .readWrite
            ).shareState
        } catch {
            return .error(message: error.localizedDescription)
        }
    }

    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord {
        let blog = try await database.read { db in
            try Blog.find(db, key: blogID)
        }
        return try await syncEngine.share(record: blog) { share in
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            share.publicPermission = .none
        }
    }

    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool {
        try await database.read { db in
            let blog = try Blog.find(db, key: blogID)
            if blog.title != BootstrapDefaults.blogTitle
                || blog.galleryIntervalSeconds != BootstrapDefaults.galleryIntervalSeconds
                || blog.galleryDistanceMeters != BootstrapDefaults.galleryDistanceMeters
            {
                return true
            }

            let bloggers = try Blogger.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let trips = try Trip.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let items = try BlogItem.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let subscriberCount = try Subscriber.where { $0.blogID.eq(blogID) }.fetchCount(db)
            let publishCount = try PublishEvent.where { $0.blogID.eq(blogID) }.fetchCount(db)

            if Self.isDevelopmentSeed(
                bloggers: bloggers,
                trips: trips,
                items: items,
                subscriberCount: subscriberCount,
                publishCount: publishCount
            ) {
                return false
            }
            return bloggers.contains { $0.displayName != BootstrapDefaults.bloggerDisplayName }
                || !trips.isEmpty
                || !items.isEmpty
                || subscriberCount > 0
                || publishCount > 0
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog {
        try await syncEngine.acceptShare(metadata: metadata)
        try await syncEngine.syncChanges()

        guard let rootRecordID = metadata.hierarchicalRootRecordID,
              let blogID = Self.blogID(from: rootRecordID.recordName)
        else {
            throw BlogSharingServiceError.sharedBlogNotFound
        }
        let blog = try await database.read { db in
            try Blog.find(db, key: blogID)
        }
        let userIdentity = metadata.share.currentUserParticipant?.userIdentity
        return try await acceptSharedBlog(
            blog,
            participant: ParticipantIdentity(
                identifier: userIdentity?.userRecordID?.recordName,
                displayName: Self.displayName(from: userIdentity?.nameComponents)
            )
        )
    }

    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BlogSharingServiceError.emptyDisplayName
        }
        try await database.write { db in
            try Blogger.find(bloggerID)
                .update {
                    $0.displayName = #bind(trimmedName)
                    $0.updatedAt = #bind(Date.now)
                }
                .execute(db)
        }
    }

    func acceptSharedBlog(
        _ blog: Blog,
        participant: ParticipantIdentity
    ) async throws -> AcceptedBlog {
        let identifier = participant.identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let displayName = participant.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "Blogger"

        return try await database.write { db in
            guard try Blog.find(blog.id).fetchOne(db) != nil else {
                throw BlogSharingServiceError.sharedBlogNotFound
            }
            let existing = try Blogger
                .where { $0.blogID.eq(blog.id) }
                .fetchAll(db)
                .first {
                    if let identifier {
                        return $0.cloudKitParticipantIdentifier == identifier
                    }
                    return $0.cloudKitParticipantIdentifier == nil
                }

            let bloggerID: Blogger.ID
            if let existing {
                bloggerID = existing.id
                try Blogger.find(existing.id)
                    .update {
                        $0.displayName = #bind(displayName)
                        $0.updatedAt = #bind(Date.now)
                    }
                    .execute(db)
            } else {
                bloggerID = UUID()
                try Blogger.insert {
                    Blogger.Draft(
                        id: bloggerID,
                        blogID: blog.id,
                        displayName: displayName,
                        createdAt: .now,
                        updatedAt: .now,
                        cloudKitParticipantIdentifier: identifier
                    )
                }
                .execute(db)
            }

            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(blog.id) }
                .execute(db)
            return AcceptedBlog(blogID: blog.id, bloggerID: bloggerID)
        }
    }

    private static func blogID(from recordName: String) -> Blog.ID? {
        guard recordName.hasSuffix(":blogs") else { return nil }
        return UUID(uuidString: String(recordName.dropLast(":blogs".count)))
    }

    private static func displayName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let parts = [components.givenName, components.middleName, components.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    nonisolated private static func isDevelopmentSeed(
        bloggers: [Blogger],
        trips: [Trip],
        items: [BlogItem],
        subscriberCount: Int,
        publishCount: Int
    ) -> Bool {
        Set(bloggers.map(\.displayName)) == ["Rog", "Jane"]
            && trips.count == 1
            && trips[0].title == "Provence by Train"
            && trips[0].description == "A sample journal used to exercise the SQLiteData-backed UI."
            && trips[0].startLocalDay == "2026-06-19"
            && trips[0].endLocalDay == "2026-06-20"
            && trips[0].createdAt == trips[0].updatedAt
            && Set(items.compactMap(\.caption)) == [
                "The first train south slipped past fields already bright with heat.",
                "The road opened into salt marshes, pale and bright under the morning sun.",
                "We found a table beside the fishing boats.",
                "The bouillabaisse arrived looking heroic.",
                "Boats knocking softly against the quay.",
                "One last coffee before the road west.",
                "Flamingos gathering in the late light.",
            ]
            && items.allSatisfy {
                $0.itemTimeZoneIdentifier == "Europe/Paris"
                    && $0.countryCode == "FR"
                    && $0.photoAssetID != nil
                    && $0.createdAt == $0.updatedAt
            }
            && subscriberCount == 0
            && publishCount == 0
    }
}

enum BlogSharingServiceError: LocalizedError {
    case emptyDisplayName
    case sharedBlogNotFound

    var errorDescription: String? {
        switch self {
        case .emptyDisplayName:
            "Display name cannot be empty."
        case .sharedBlogNotFound:
            "The accepted shared blog could not be found."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
