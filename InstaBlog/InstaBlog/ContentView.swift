import SwiftUI

nonisolated struct ActiveWorkspace: Equatable {
    let blog: Blog
    let blogger: Blogger
}

struct ContentView: View {
    @State private var workspace: ActiveWorkspace
    @State private var journalService: JournalService
    let sharingService: any BlogSharingServiceProtocol
    let shareAcceptanceCoordinator: ShareAcceptanceCoordinator
    let loadWorkspace: () throws -> ActiveWorkspace
    let makeJournalService: (ActiveWorkspace) -> JournalService

    init(
        workspace: ActiveWorkspace,
        sharingService: any BlogSharingServiceProtocol,
        shareAcceptanceCoordinator: ShareAcceptanceCoordinator,
        loadWorkspace: @escaping () throws -> ActiveWorkspace,
        makeJournalService: @escaping (ActiveWorkspace) -> JournalService
    ) {
        _workspace = State(initialValue: workspace)
        _journalService = State(initialValue: makeJournalService(workspace))
        self.sharingService = sharingService
        self.shareAcceptanceCoordinator = shareAcceptanceCoordinator
        self.loadWorkspace = loadWorkspace
        self.makeJournalService = makeJournalService
    }

    var body: some View {
        ZStack {
            IPhoneShell(
                trip: try? journalService.loadCurrentTrip(),
                journalService: journalService,
                blog: workspace.blog,
                blogger: workspace.blogger,
                sharingService: sharingService
            )
            .id(workspace.blog.id)
            .allowsHitTesting(!shareAcceptanceCoordinator.presentation.blocksShell)
            .accessibilityHidden(shareAcceptanceCoordinator.presentation.blocksShell)

            ShareAcceptanceOverlay(
                coordinator: shareAcceptanceCoordinator,
                onAccepted: reloadWorkspace
            )
        }
        .task {
            guard !Self.isRunningUITests else { return }
            await journalService.requestLocationPermissionIfNeeded()
        }
    }

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
    }

    private func reloadWorkspace(_ accepted: AcceptedBlog) throws {
        let reloaded = try loadWorkspace()
        guard reloaded.blog.id == accepted.blogID,
              reloaded.blogger.id == accepted.bloggerID
        else { throw ActiveWorkspaceReloadError.mismatchedAcceptedWorkspace }
        workspace = reloaded
        journalService = makeJournalService(reloaded)
    }
}

private enum ActiveWorkspaceReloadError: LocalizedError {
    case mismatchedAcceptedWorkspace

    var errorDescription: String? {
        "The accepted Blog could not be loaded. Try again."
    }
}

private struct ShareAcceptanceOverlay: View {
    let coordinator: ShareAcceptanceCoordinator
    let onAccepted: (AcceptedBlog) throws -> Void
    @AccessibilityFocusState private var isModalFocused: Bool

    var body: some View {
        Group {
            switch coordinator.presentation {
            case .none:
                EmptyView()
            case let .confirmation(blogTitle):
                card(title: "Join \(blogTitle)?") {
                    Text(
                        "Your current Blog will be hidden, not deleted. "
                            + "You can return to it after leaving the shared Blog."
                    )
                    HStack {
                        Button("Cancel", role: .cancel) {
                            coordinator.cancel()
                        }
                        Spacer()
                        Button("Join Blog") {
                            Task { await coordinator.confirm() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .accepting:
                card(title: "Joining Blog") {
                    ProgressView()
                    Text("Accepting the shared Blog…")
                }
            case let .accepted(accepted):
                Color.clear
                    .task {
                        do {
                            try onAccepted(accepted)
                            coordinator.acceptedWorkspaceReloadSucceeded()
                        } catch {
                            coordinator.acceptedWorkspaceReloadFailed(accepted, error: error)
                        }
                    }
            case let .acceptedReloadError(accepted, message):
                card(title: "Could Not Load Blog") {
                    Text(message)
                    Button("Retry") {
                        coordinator.retryAcceptedWorkspaceReload()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case let .error(message):
                card(title: "Could Not Join Blog") {
                    Text(message)
                    HStack {
                        Button("Dismiss", role: .cancel) {
                            coordinator.cancel()
                        }
                        Spacer()
                        Button("Retry") {
                            Task { await coordinator.retry() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func card<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.headline)
                content()
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .padding()
            .accessibilityFocused($isModalFocused)
            .onAppear { isModalFocused = true }
        }
        .accessibilityAddTraits(.isModal)
    }
}
