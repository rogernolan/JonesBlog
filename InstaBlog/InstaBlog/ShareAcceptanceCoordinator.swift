import CloudKit
import Foundation
import Observation

nonisolated struct ShareInvitation: Equatable {
    let blogTitle: String

    init(blogTitle: String) {
        let trimmedTitle = blogTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.blogTitle = trimmedTitle.isEmpty ? "Shared Blog" : trimmedTitle
    }
}

@MainActor
@Observable
final class ShareAcceptanceCoordinator {
    enum Presentation: Equatable {
        case none
        case confirmation(blogTitle: String)
        case accepting
        case accepted(AcceptedBlog)
        case error(message: String)
    }

    private(set) var presentation: Presentation = .none

    @ObservationIgnored
    private let isMeaningfulBlog: (Blog.ID) async throws -> Bool
    @ObservationIgnored
    private let acceptInvitation: (ShareInvitation) async throws -> AcceptedBlog
    @ObservationIgnored
    private let acceptMetadata: ((CKShare.Metadata) async throws -> AcceptedBlog)?
    @ObservationIgnored
    private var pending: Pending?

    init(sharingService: any BlogSharingServiceProtocol) {
        self.isMeaningfulBlog = sharingService.isMeaningfulBlog
        self.acceptInvitation = { _ in
            throw ShareAcceptanceError.missingCloudKitMetadata
        }
        self.acceptMetadata = sharingService.acceptShare
    }

    init(
        isMeaningfulBlog: @escaping (Blog.ID) async throws -> Bool,
        acceptInvitation: @escaping (ShareInvitation) async throws -> AcceptedBlog
    ) {
        self.isMeaningfulBlog = isMeaningfulBlog
        self.acceptInvitation = acceptInvitation
        self.acceptMetadata = nil
    }

    func receive(_ metadata: CKShare.Metadata, activeBlogID: Blog.ID) async {
        await receive(metadata, resolvingActiveBlogID: { activeBlogID })
    }

    func receive(
        _ metadata: CKShare.Metadata,
        resolvingActiveBlogID: () async throws -> Blog.ID
    ) async {
        let invitation = ShareInvitation(
            blogTitle: metadata.share[CKShare.SystemFieldKey.title] as? String ?? "Shared Blog"
        )
        let pending = Pending(invitation: invitation) { [acceptMetadata] in
            guard let acceptMetadata else {
                throw ShareAcceptanceError.missingCloudKitMetadata
            }
            return try await acceptMetadata(metadata)
        }
        await receive(pending, resolvingActiveBlogID: resolvingActiveBlogID)
    }

    func receive(_ invitation: ShareInvitation, activeBlogID: Blog.ID) async {
        await receive(invitation, resolvingActiveBlogID: { activeBlogID })
    }

    func receive(
        _ invitation: ShareInvitation,
        resolvingActiveBlogID: () async throws -> Blog.ID
    ) async {
        let pending = Pending(invitation: invitation) { [acceptInvitation] in
            try await acceptInvitation(invitation)
        }
        await receive(pending, resolvingActiveBlogID: resolvingActiveBlogID)
    }

    private func receive(
        _ candidate: Pending,
        resolvingActiveBlogID: () async throws -> Blog.ID
    ) async {
        guard pending == nil else { return }
        pending = candidate
        do {
            let activeBlogID = try await resolvingActiveBlogID()
            guard pending?.id == candidate.id else { return }
            if try await isMeaningfulBlog(activeBlogID) {
                guard pending?.id == candidate.id else { return }
                presentation = .confirmation(blogTitle: candidate.invitation.blogTitle)
            } else {
                guard pending?.id == candidate.id else { return }
                await acceptPendingInvitation()
            }
        } catch {
            guard pending?.id == candidate.id else { return }
            clearPendingInvitation()
            presentation = .error(message: error.localizedDescription)
        }
    }

    func cancel() {
        guard presentation != .accepting else { return }
        clearPendingInvitation()
        presentation = .none
    }

    func confirm() async {
        guard case .confirmation = presentation else { return }
        await acceptPendingInvitation()
    }

    func retry() async {
        guard case .error = presentation, pending != nil else { return }
        await acceptPendingInvitation()
    }

    private func acceptPendingInvitation() async {
        guard let pending, presentation != .accepting else { return }
        presentation = .accepting
        do {
            let accepted = try await pending.accept()
            guard self.pending?.id == pending.id else { return }
            clearPendingInvitation()
            presentation = .accepted(accepted)
        } catch {
            guard self.pending?.id == pending.id else { return }
            presentation = .error(message: error.localizedDescription)
        }
    }

    private func clearPendingInvitation() {
        pending = nil
    }

    private struct Pending {
        let id = UUID()
        let invitation: ShareInvitation
        let accept: () async throws -> AcceptedBlog
    }
}

private enum ShareAcceptanceError: LocalizedError {
    case missingCloudKitMetadata

    var errorDescription: String? {
        "The Blog share invitation is no longer available."
    }
}
