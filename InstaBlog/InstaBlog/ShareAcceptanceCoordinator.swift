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
        case acceptedReloadError(AcceptedBlog, message: String)
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
        resolvingActiveBlogID: @escaping () async throws -> Blog.ID
    ) async {
        let invitation = ShareInvitation(
            blogTitle: metadata.share[CKShare.SystemFieldKey.title] as? String ?? "Shared Blog"
        )
        let pending = Pending(
            invitation: invitation,
            resolveActiveBlogID: resolvingActiveBlogID
        ) { [acceptMetadata] in
            guard let acceptMetadata else {
                throw ShareAcceptanceError.missingCloudKitMetadata
            }
            return try await acceptMetadata(metadata)
        }
        await receive(pending)
    }

    func receive(_ invitation: ShareInvitation, activeBlogID: Blog.ID) async {
        await receive(invitation, resolvingActiveBlogID: { activeBlogID })
    }

    func receive(
        _ invitation: ShareInvitation,
        resolvingActiveBlogID: @escaping () async throws -> Blog.ID
    ) async {
        let pending = Pending(
            invitation: invitation,
            resolveActiveBlogID: resolvingActiveBlogID
        ) { [acceptInvitation] in
            try await acceptInvitation(invitation)
        }
        await receive(pending)
    }

    private func receive(_ candidate: Pending) async {
        guard pending == nil else { return }
        pending = candidate
        await preflight(candidate)
    }

    private func preflight(_ candidate: Pending) async {
        do {
            let activeBlogID = try await candidate.resolveActiveBlogID()
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
            AppTelemetry.record(
                "Share acceptance preflight failed",
                category: "cloud.sharing",
                level: .error,
                error: error
            )
            presentation = .error(message: error.localizedDescription)
        }
    }

    func cancel() {
        guard presentation != .accepting else { return }
        if case .acceptedReloadError = presentation { return }
        clearPendingInvitation()
        presentation = .none
    }

    func confirm() async {
        guard case .confirmation = presentation else { return }
        await acceptPendingInvitation()
    }

    func retry() async {
        guard case .error = presentation, let pending else { return }
        await preflight(pending)
    }

    func acceptedWorkspaceReloadSucceeded() {
        guard case .accepted = presentation else { return }
        presentation = .none
    }

    func acceptedWorkspaceReloadFailed(_ accepted: AcceptedBlog, error: any Error) {
        guard presentation == .accepted(accepted) else { return }
        AppTelemetry.record(
            "Accepted shared blog reload failed",
            category: "cloud.sharing",
            level: .error,
            error: error,
            data: ["blog_id": accepted.blogID.uuidString]
        )
        presentation = .acceptedReloadError(accepted, message: error.localizedDescription)
    }

    func retryAcceptedWorkspaceReload() {
        guard case let .acceptedReloadError(accepted, _) = presentation else { return }
        presentation = .accepted(accepted)
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
            AppTelemetry.log(
                "Share acceptance coordinator failed",
                category: "cloud.sharing",
                level: .error,
                error: error
            )
            presentation = .error(message: error.localizedDescription)
        }
    }

    private func clearPendingInvitation() {
        pending = nil
    }

    private struct Pending {
        let id = UUID()
        let invitation: ShareInvitation
        let resolveActiveBlogID: () async throws -> Blog.ID
        let accept: () async throws -> AcceptedBlog
    }
}

extension ShareAcceptanceCoordinator.Presentation {
    nonisolated var blocksShell: Bool {
        switch self {
        case .none:
            false
        case .confirmation, .accepting, .accepted, .acceptedReloadError, .error:
            true
        }
    }
}

private enum ShareAcceptanceError: LocalizedError {
    case missingCloudKitMetadata

    var errorDescription: String? {
        "The Blog share invitation is no longer available."
    }
}
