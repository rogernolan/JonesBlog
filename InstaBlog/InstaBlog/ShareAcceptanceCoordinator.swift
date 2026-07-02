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
    private var pendingInvitation: ShareInvitation?
    @ObservationIgnored
    private var pendingMetadata: CKShare.Metadata?

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
        pendingMetadata = metadata
        let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? "Shared Blog"
        await receive(ShareInvitation(blogTitle: title), activeBlogID: activeBlogID)
    }

    func receive(_ invitation: ShareInvitation, activeBlogID: Blog.ID) async {
        guard presentation != .accepting else { return }
        pendingInvitation = invitation
        do {
            if try await isMeaningfulBlog(activeBlogID) {
                presentation = .confirmation(blogTitle: invitation.blogTitle)
            } else {
                await acceptPendingInvitation()
            }
        } catch {
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

    private func acceptPendingInvitation() async {
        guard let invitation = pendingInvitation, presentation != .accepting else { return }
        presentation = .accepting
        do {
            let accepted: AcceptedBlog
            if let metadata = pendingMetadata, let acceptMetadata {
                accepted = try await acceptMetadata(metadata)
            } else {
                accepted = try await acceptInvitation(invitation)
            }
            clearPendingInvitation()
            presentation = .accepted(accepted)
        } catch {
            clearPendingInvitation()
            presentation = .error(message: error.localizedDescription)
        }
    }

    private func clearPendingInvitation() {
        pendingInvitation = nil
        pendingMetadata = nil
    }
}

private enum ShareAcceptanceError: LocalizedError {
    case missingCloudKitMetadata

    var errorDescription: String? {
        "The Blog share invitation is no longer available."
    }
}
