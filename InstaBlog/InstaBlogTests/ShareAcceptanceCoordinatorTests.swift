import Foundation
import Testing
@testable import InstaBlog

@MainActor
struct ShareAcceptanceCoordinatorTests {
    @Test
    func emptyBlogAcceptsImmediately() async {
        let accepted = AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        let fake = FakeShareAcceptanceService(isMeaningful: false, result: .success(accepted))
        let coordinator = fake.makeCoordinator()

        await coordinator.receive(
            ShareInvitation(blogTitle: "Shared Adventures"),
            activeBlogID: UUID()
        )

        #expect(coordinator.presentation == .accepted(accepted))
        #expect(fake.acceptCallCount == 1)
    }

    @Test
    func meaningfulBlogRequiresConfirmation() async {
        let fake = FakeShareAcceptanceService()
        let coordinator = fake.makeCoordinator()

        await coordinator.receive(
            ShareInvitation(blogTitle: "Shared Adventures"),
            activeBlogID: UUID()
        )

        #expect(coordinator.presentation == .confirmation(blogTitle: "Shared Adventures"))
        #expect(fake.acceptCallCount == 0)
    }

    @Test
    func cancelClearsInvitationWithoutAccepting() async {
        let fake = FakeShareAcceptanceService()
        let coordinator = fake.makeCoordinator()
        await coordinator.receive(ShareInvitation(blogTitle: "Shared Adventures"), activeBlogID: UUID())

        coordinator.cancel()
        await coordinator.confirm()

        #expect(coordinator.presentation == .none)
        #expect(fake.acceptCallCount == 0)
    }

    @Test
    func confirmAcceptsInvitation() async {
        let accepted = AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        let fake = FakeShareAcceptanceService(result: .success(accepted))
        let coordinator = fake.makeCoordinator()
        await coordinator.receive(ShareInvitation(blogTitle: "Shared Adventures"), activeBlogID: UUID())

        await coordinator.confirm()

        #expect(coordinator.presentation == .accepted(accepted))
        #expect(fake.acceptCallCount == 1)
    }

    @Test
    func failurePresentsErrorWithoutChangingActiveBlog() async {
        let activeBlogID = UUID()
        let fake = FakeShareAcceptanceService(result: .failure(TestError.acceptanceFailed))
        let coordinator = fake.makeCoordinator()
        await coordinator.receive(ShareInvitation(blogTitle: "Shared Adventures"), activeBlogID: activeBlogID)

        await coordinator.confirm()

        #expect(coordinator.presentation == .error(message: "Acceptance failed"))
        #expect(fake.activeBlogID == activeBlogID)
    }

    @Test
    func repeatedConfirmWhileAcceptingIsIgnored() async {
        let accepted = AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        let gate = AcceptanceGate()
        let fake = FakeShareAcceptanceService(result: .success(accepted), gate: gate)
        let coordinator = fake.makeCoordinator()
        await coordinator.receive(ShareInvitation(blogTitle: "Shared Adventures"), activeBlogID: UUID())

        async let first: Void = coordinator.confirm()
        await gate.waitUntilAcceptanceStarts()
        await coordinator.confirm()
        gate.resume()
        await first

        #expect(coordinator.presentation == .accepted(accepted))
        #expect(fake.acceptCallCount == 1)
    }

    @Test
    func secondInvitationDoesNotReplaceVisibleConfirmation() async {
        let fake = FakeShareAcceptanceService()
        let coordinator = fake.makeCoordinator()
        await coordinator.receive(ShareInvitation(blogTitle: "First Blog"), activeBlogID: UUID())

        await coordinator.receive(ShareInvitation(blogTitle: "Second Blog"), activeBlogID: UUID())
        await coordinator.confirm()

        #expect(fake.acceptedInvitationTitles == ["First Blog"])
    }

    @Test
    func secondInvitationDoesNotReplaceSuspendedMeaningfulCheck() async {
        let meaningfulGate = AcceptanceGate()
        let fake = FakeShareAcceptanceService(meaningfulGate: meaningfulGate)
        let coordinator = fake.makeCoordinator()

        async let first: Void = coordinator.receive(
            ShareInvitation(blogTitle: "First Blog"),
            activeBlogID: UUID()
        )
        await meaningfulGate.waitUntilAcceptanceStarts()
        await coordinator.receive(ShareInvitation(blogTitle: "Second Blog"), activeBlogID: UUID())
        meaningfulGate.resume()
        await first
        await coordinator.confirm()

        #expect(fake.acceptedInvitationTitles == ["First Blog"])
    }

    @Test
    func secondInvitationDoesNotReplaceInvitationBeingAccepted() async {
        let acceptanceGate = AcceptanceGate()
        let fake = FakeShareAcceptanceService(gate: acceptanceGate)
        let coordinator = fake.makeCoordinator()
        await coordinator.receive(ShareInvitation(blogTitle: "First Blog"), activeBlogID: UUID())

        async let acceptance: Void = coordinator.confirm()
        await acceptanceGate.waitUntilAcceptanceStarts()
        await coordinator.receive(ShareInvitation(blogTitle: "Second Blog"), activeBlogID: UUID())
        acceptanceGate.resume()
        await acceptance

        #expect(fake.acceptedInvitationTitles == ["First Blog"])
    }

    @Test
    func activeBlogLookupFailureDoesNotAcceptInvitation() async {
        let fake = FakeShareAcceptanceService()
        let coordinator = fake.makeCoordinator()

        await coordinator.receive(
            ShareInvitation(blogTitle: "Shared Adventures"),
            resolvingActiveBlogID: { throw TestError.activeBlogLookupFailed }
        )

        #expect(
            coordinator.presentation
                == .error(message: "The active Blog could not be loaded")
        )
        #expect(fake.acceptCallCount == 0)
    }

    @Test
    func failedAcceptanceCanBeRetried() async {
        var attempts = 0
        let accepted = AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        let coordinator = ShareAcceptanceCoordinator(
            isMeaningfulBlog: { _ in true },
            acceptInvitation: { _ in
                attempts += 1
                if attempts == 1 {
                    throw TestError.acceptanceFailed
                }
                return accepted
            }
        )
        await coordinator.receive(ShareInvitation(blogTitle: "Shared Adventures"), activeBlogID: UUID())
        await coordinator.confirm()

        await coordinator.retry()

        #expect(coordinator.presentation == .accepted(accepted))
        #expect(attempts == 2)
    }

    @Test
    func acceptedWorkspaceReloadFailureCanBeRetried() async {
        let accepted = AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        let coordinator = ShareAcceptanceCoordinator(
            isMeaningfulBlog: { _ in false },
            acceptInvitation: { _ in accepted }
        )
        await coordinator.receive(ShareInvitation(blogTitle: "Shared Adventures"), activeBlogID: UUID())

        coordinator.acceptedWorkspaceReloadFailed(
            accepted,
            error: TestError.activeBlogLookupFailed
        )
        #expect(
            coordinator.presentation
                == .acceptedReloadError(
                    accepted,
                    message: "The active Blog could not be loaded"
                )
        )

        coordinator.retryAcceptedWorkspaceReload()

        #expect(coordinator.presentation == .accepted(accepted))
    }

    @Test
    func acceptedWorkspaceReloadFailureCannotExposeOldWorkspace() async {
        let accepted = AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        let coordinator = ShareAcceptanceCoordinator(
            isMeaningfulBlog: { _ in false },
            acceptInvitation: { _ in accepted }
        )
        await coordinator.receive(ShareInvitation(blogTitle: "Shared Adventures"), activeBlogID: UUID())
        coordinator.acceptedWorkspaceReloadFailed(
            accepted,
            error: TestError.activeBlogLookupFailed
        )

        coordinator.cancel()

        #expect(
            coordinator.presentation
                == .acceptedReloadError(
                    accepted,
                    message: "The active Blog could not be loaded"
                )
        )
        #expect(coordinator.presentation.blocksShell)
    }
}

@MainActor
private final class FakeShareAcceptanceService {
    var acceptCallCount = 0
    private(set) var acceptedInvitationTitles: [String] = []
    private(set) var activeBlogID: Blog.ID?

    private let isMeaningful: Bool
    private let result: Result<AcceptedBlog, Error>
    private let gate: AcceptanceGate?
    private let meaningfulGate: AcceptanceGate?

    init(
        isMeaningful: Bool = true,
        result: Result<AcceptedBlog, Error> = .success(
            AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        ),
        gate: AcceptanceGate? = nil,
        meaningfulGate: AcceptanceGate? = nil
    ) {
        self.isMeaningful = isMeaningful
        self.result = result
        self.gate = gate
        self.meaningfulGate = meaningfulGate
    }

    func makeCoordinator() -> ShareAcceptanceCoordinator {
        ShareAcceptanceCoordinator(
            isMeaningfulBlog: { [self] blogID in
                activeBlogID = blogID
                if let meaningfulGate {
                    await meaningfulGate.suspend()
                }
                return isMeaningful
            },
            acceptInvitation: { [self] invitation in
                acceptCallCount += 1
                acceptedInvitationTitles.append(invitation.blogTitle)
                if let gate {
                    await gate.suspend()
                }
                let accepted = try result.get()
                activeBlogID = accepted.blogID
                return accepted
            }
        )
    }
}

private enum TestError: LocalizedError {
    case acceptanceFailed
    case activeBlogLookupFailed

    var errorDescription: String? {
        switch self {
        case .acceptanceFailed:
            "Acceptance failed"
        case .activeBlogLookupFailed:
            "The active Blog could not be loaded"
        }
    }
}

@MainActor
private final class AcceptanceGate {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func suspend() async {
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilAcceptanceStarts() async {
        guard !didStart else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
