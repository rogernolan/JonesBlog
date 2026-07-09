import GRDB
import Observation
import SwiftUI

nonisolated struct ActiveWorkspace: Equatable {
    let blog: Blog
    let blogger: Blogger
}

@MainActor
@Observable
final class JournalTripLoader {
    private(set) var blogID: Blog.ID?
    var trips: [TripDisplay] = []
    private var requestID = UUID()

    func reset() {
        requestID = UUID()
        blogID = nil
        trips = []
    }

    func load(
        blogID: Blog.ID,
        operation: @escaping @Sendable () throws -> [TripDisplay]
    ) async {
        let requestID = UUID()
        self.requestID = requestID
        let loadedTrips = await Task.detached(priority: .userInitiated) {
            try? operation()
        }.value
        guard self.requestID == requestID else { return }
        self.blogID = blogID
        trips = loadedTrips ?? []
    }
}

struct ContentView: View {
    @State private var workspace: ActiveWorkspace
    @State private var journalService: JournalService
    @State private var tripLoader = JournalTripLoader()
    @State private var reloadGeneration = 0
    @State private var isLocatingCloudBlogs = !Self.isRunningUITests
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let sharingService: any BlogSharingServiceProtocol
    let shareAcceptanceCoordinator: ShareAcceptanceCoordinator
    let loadWorkspace: () throws -> ActiveWorkspace
    let observeWorkspace: () -> AsyncValueObservation<ActiveWorkspace>
    let makeJournalService: (ActiveWorkspace) -> JournalService

    init(
        workspace: ActiveWorkspace,
        sharingService: any BlogSharingServiceProtocol,
        shareAcceptanceCoordinator: ShareAcceptanceCoordinator,
        loadWorkspace: @escaping () throws -> ActiveWorkspace,
        observeWorkspace: @escaping () -> AsyncValueObservation<ActiveWorkspace>,
        makeJournalService: @escaping (ActiveWorkspace) -> JournalService
    ) {
        _workspace = State(initialValue: workspace)
        _journalService = State(initialValue: makeJournalService(workspace))
        self.sharingService = sharingService
        self.shareAcceptanceCoordinator = shareAcceptanceCoordinator
        self.loadWorkspace = loadWorkspace
        self.observeWorkspace = observeWorkspace
        self.makeJournalService = makeJournalService
    }

    var body: some View {
        ZStack {
            if isLocatingCloudBlogs {
                locatingCloudBlogsView
            } else {
                shell
                .id(workspace.blog.id)
                .allowsHitTesting(!shareAcceptanceCoordinator.presentation.blocksShell)
                .accessibilityHidden(shareAcceptanceCoordinator.presentation.blocksShell)
            }

            ShareAcceptanceOverlay(
                coordinator: shareAcceptanceCoordinator,
                onAccepted: reloadWorkspace
            )
        }
        .task {
            guard !Self.isRunningUITests else { return }
            await sharingService.restoreOwnedBlogIfNeeded()
            do {
                try reloadWorkspace()
            } catch {
                assertionFailure("Unable to reload workspace after startup sync: \(error)")
            }
            isLocatingCloudBlogs = false
        }
        .task {
            guard !Self.isRunningUITests else { return }
            await journalService.requestLocationPermissionIfNeeded()
        }
        .task(id: TripLoadRequest(
            blogID: workspace.blog.id,
            generation: reloadGeneration,
            isLocatingCloudBlogs: isLocatingCloudBlogs
        )) {
            guard !isLocatingCloudBlogs else { return }
            guard !Task.isCancelled else { return }
            let service = journalService
            await tripLoader.load(blogID: workspace.blog.id) {
                try service.loadTrips()
            }
            while !Task.isCancelled {
                await service.synchronizeMediaAssets()
                await tripLoader.load(blogID: workspace.blog.id) {
                    try service.loadTrips()
                }
                guard tripLoader.trips.contains(where: \.hasPendingUpload) else {
                    break
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
        }
        .task {
            do {
                for try await updatedWorkspace in observeWorkspace() {
                    guard updatedWorkspace != workspace else { continue }
                    workspace = updatedWorkspace
                    journalService = makeJournalService(updatedWorkspace)
                    tripLoader.reset()
                }
            } catch {
                assertionFailure("Unable to observe the active workspace: \(error)")
            }
        }
    }

    @ViewBuilder
    private var shell: some View {
        if shouldUseIPadLayout {
            IPadShell(
                trips: $tripLoader.trips,
                isLoadingTrips: tripLoader.blogID != workspace.blog.id,
                journalService: journalService,
                blog: workspace.blog,
                blogger: workspace.blogger,
                sharingService: sharingService,
                onReloadTrips: requestTripsReload
            )
        } else {
            IPhoneShell(
                trips: $tripLoader.trips,
                isLoadingTrips: tripLoader.blogID != workspace.blog.id,
                journalService: journalService,
                blog: workspace.blog,
                blogger: workspace.blogger,
                sharingService: sharingService,
                onReloadTrips: requestTripsReload
            )
        }
    }

    private var shouldUseIPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
    }

    private func requestTripsReload() {
        reloadGeneration += 1
    }

    private var locatingCloudBlogsView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Locating iCloud blogs…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func reloadWorkspace() throws {
        let reloaded = try loadWorkspace()
        workspace = reloaded
        journalService = makeJournalService(reloaded)
        tripLoader.reset()
    }

    private func reloadWorkspace(_ accepted: AcceptedBlog) throws {
        let reloaded = try loadWorkspace()
        guard reloaded.blog.id == accepted.blogID,
              reloaded.blogger.id == accepted.bloggerID
        else { throw ActiveWorkspaceReloadError.mismatchedAcceptedWorkspace }
        workspace = reloaded
        journalService = makeJournalService(reloaded)
        tripLoader.reset()
    }
}

private struct TripLoadRequest: Equatable {
    let blogID: Blog.ID
    let generation: Int
    let isLocatingCloudBlogs: Bool
}

private extension TripDisplay {
    var hasPendingUpload: Bool {
        days.contains { day in
            day.entries.contains { entry in
                switch entry {
                case let .blogItem(item):
                    item.syncStatus == .pending
                case let .gallery(gallery):
                    gallery.items.contains { $0.syncStatus == .pending }
                }
            }
        }
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
            case let .acceptedReloadError(_, message):
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
