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
        false
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog {
        throw BlogSharingServiceError.notImplemented
    }

    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws {
        throw BlogSharingServiceError.notImplemented
    }
}

private enum BlogSharingServiceError: LocalizedError {
    case notImplemented

    var errorDescription: String? {
        "This sharing operation is not implemented yet."
    }
}
