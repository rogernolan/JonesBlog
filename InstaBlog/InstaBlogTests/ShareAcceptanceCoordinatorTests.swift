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
}

@MainActor
private final class FakeShareAcceptanceService {
    var acceptCallCount = 0
    private(set) var activeBlogID: Blog.ID?

    private let isMeaningful: Bool
    private let result: Result<AcceptedBlog, Error>
    private let gate: AcceptanceGate?

    init(
        isMeaningful: Bool = true,
        result: Result<AcceptedBlog, Error> = .success(
            AcceptedBlog(blogID: UUID(), bloggerID: UUID())
        ),
        gate: AcceptanceGate? = nil
    ) {
        self.isMeaningful = isMeaningful
        self.result = result
        self.gate = gate
    }

    func makeCoordinator() -> ShareAcceptanceCoordinator {
        ShareAcceptanceCoordinator(
            isMeaningfulBlog: { [self] blogID in
                activeBlogID = blogID
                return isMeaningful
            },
            acceptInvitation: { [self] _ in
                acceptCallCount += 1
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

    var errorDescription: String? { "Acceptance failed" }
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
