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
    private(set) var isLoading = false
    private(set) var failure: JournalNotice?
    private var requestID = UUID()
    @ObservationIgnored private let logFailure: (String) -> Void

    init(logFailure: @escaping (String) -> Void = { _ in }) {
        self.logFailure = logFailure
    }

    func reset() {
        requestID = UUID()
        blogID = nil
        trips = []
        isLoading = false
        failure = nil
    }

    func load(
        blogID: Blog.ID,
        operation: @escaping @Sendable () throws -> [TripDisplay]
    ) async {
        let requestID = UUID()
        self.requestID = requestID
        isLoading = true
        failure = nil
        let loadedTrips: [TripDisplay]
        do {
            loadedTrips = try await Task.detached(priority: .userInitiated) {
                try operation()
            }.value
        } catch {
            guard self.requestID == requestID else { return }
            isLoading = false
            failure = JournalNotice(
                title: "Could Not Load Journal",
                message: "Your journal could not be loaded. Please try again."
            )
            AppTelemetry.log(
                "Failed to load journal",
                category: "journal.loading",
                level: .error,
                error: error,
                data: ["blog_id": blogID.uuidString]
            )
            logFailure("Failed to load journal for blog \(blogID): \(error.localizedDescription)")
            return
        }
        guard self.requestID == requestID else { return }
        self.blogID = blogID
        trips = loadedTrips
        isLoading = false
        failure = nil
    }
}

struct ContentView: View {
    @State private var workspace: ActiveWorkspace
    @State private var journalService: JournalService
    @State private var tripLoader = JournalTripLoader()
    @State private var contentNotices = JournalActionErrorState()
    @State private var reloadGeneration = 0
    @State private var journalObservationAttempt = 0
    @State private var workspaceObservationAttempt = 0
    @State private var isCheckingCloudBlogs = !Self.isRunningUITests
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    let sharingService: any BlogSharingServiceProtocol
    let shareAcceptanceCoordinator: ShareAcceptanceCoordinator
    let loadWorkspace: () throws -> ActiveWorkspace
    let observeWorkspace: () -> AsyncValueObservation<ActiveWorkspace>
    let observeJournalChanges: (Blog.ID) -> AsyncValueObservation<JournalChangeToken>
    let makeJournalService: (ActiveWorkspace) -> JournalService

    init(
        workspace: ActiveWorkspace,
        sharingService: any BlogSharingServiceProtocol,
        shareAcceptanceCoordinator: ShareAcceptanceCoordinator,
        loadWorkspace: @escaping () throws -> ActiveWorkspace,
        observeWorkspace: @escaping () -> AsyncValueObservation<ActiveWorkspace>,
        observeJournalChanges: @escaping (Blog.ID) -> AsyncValueObservation<JournalChangeToken>,
        makeJournalService: @escaping (ActiveWorkspace) -> JournalService
    ) {
        _workspace = State(initialValue: workspace)
        _journalService = State(initialValue: makeJournalService(workspace))
        self.sharingService = sharingService
        self.shareAcceptanceCoordinator = shareAcceptanceCoordinator
        self.loadWorkspace = loadWorkspace
        self.observeWorkspace = observeWorkspace
        self.observeJournalChanges = observeJournalChanges
        self.makeJournalService = makeJournalService
    }

    var body: some View {
        ZStack {
            shell
                .id(workspace.blog.id)
                .allowsHitTesting(
                    !shareAcceptanceCoordinator.presentation.blocksShell && blockingLoadFailure == nil
                )
                .accessibilityHidden(
                    shareAcceptanceCoordinator.presentation.blocksShell || blockingLoadFailure != nil
                )

            if let failure = blockingLoadFailure {
                JournalLoadFailureView(notice: failure, retry: requestTripsReload)
            }

            if isCheckingCloudBlogs {
                cloudCheckToast
            }

            ShareAcceptanceOverlay(
                coordinator: shareAcceptanceCoordinator,
                onAccepted: reloadWorkspace
            )
        }
        .journalActionErrors(contentNotices)
        .onChange(of: tripLoader.failure) { _, failure in
            guard failure != nil, tripLoader.blogID == workspace.blog.id else { return }
            contentNotices.presentToast(
                JournalNotice(
                    title: "Journal Not Refreshed",
                    message: "Your journal could not be refreshed. Pull to refresh or try again shortly."
                )
            )
        }
        .task {
            guard !Self.isRunningUITests else { return }
            defer { isCheckingCloudBlogs = false }
            await sharingService.restoreAcceptedSharedBlogIfNeeded()
            do {
                try reloadWorkspace()
            } catch {
                contentNotices.reportFailure(
                    error,
                    context: "startup workspace refresh",
                    as: .modal(JournalNotice(
                        title: "Could Not Refresh Blog",
                        message: "The current Blog is still available, but Cloud updates could not be loaded. Please try again shortly."
                    ))
                )
            }
        }
        .task {
            guard !Self.isRunningUITests else { return }
            await journalService.requestLocationPermissionIfNeeded()
            do {
                let location = try await journalService.currentLocation()
                AppTelemetry.log(
                    "Launch location stabilized",
                    category: "location.launch",
                    data: [
                        "latitude": location.latitude,
                        "longitude": location.longitude,
                    ]
                )
            } catch {
                AppTelemetry.log(
                    "Launch location unavailable",
                    category: "location.launch",
                    level: .warning,
                    error: error
                )
            }
        }
        .task(id: TripLoadRequest(
            blogID: workspace.blog.id,
            generation: reloadGeneration,
            isCheckingCloudBlogs: isCheckingCloudBlogs
        )) {
            guard !isCheckingCloudBlogs else { return }
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
        .task(id: JournalObservationRequest(
            blogID: workspace.blog.id,
            attempt: journalObservationAttempt
        )) {
            do {
                for try await _ in observeJournalChanges(workspace.blog.id) {
                    guard !Task.isCancelled else { return }
                    guard !isCheckingCloudBlogs else { continue }
                    await sharingService.synchronizeCloudState()
                    let service = journalService
                    await service.synchronizeMediaAssets()
                    await tripLoader.load(blogID: workspace.blog.id) {
                        try service.loadTrips()
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                contentNotices.reportFailure(
                    error,
                    context: "journal change observation",
                    as: .toast(JournalNotice(
                        title: "Journal Updates Paused",
                        message: "Live journal updates stopped. Retrying automatically."
                    ))
                )
                do {
                    try await Task.sleep(for: .seconds(5))
                    journalObservationAttempt += 1
                } catch {
                    return
                }
            }
        }
        .task(id: scenePhase) {
            guard !Self.isRunningUITests else { return }
            guard scenePhase == .active else { return }
            await sharingService.synchronizeCloudState()
        }
        .task(id: workspaceObservationAttempt) {
            do {
                for try await updatedWorkspace in observeWorkspace() {
                    guard updatedWorkspace != workspace else { continue }
                    workspace = updatedWorkspace
                    journalService = makeJournalService(updatedWorkspace)
                    tripLoader.reset()
                }
            } catch {
                guard !Task.isCancelled else { return }
                contentNotices.reportFailure(
                    error,
                    context: "active workspace observation",
                    as: .toast(JournalNotice(
                        title: "Blog Updates Paused",
                        message: "Blog changes stopped updating. Retrying automatically."
                    ))
                )
                do {
                    try await Task.sleep(for: .seconds(5))
                    workspaceObservationAttempt += 1
                } catch {
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var shell: some View {
        if shouldUseIPadLayout {
            IPadShell(
                trips: $tripLoader.trips,
                isLoadingTrips: tripLoader.blogID != workspace.blog.id && tripLoader.failure == nil,
                journalService: journalService,
                blog: workspace.blog,
                blogger: workspace.blogger,
                sharingService: sharingService,
                onReloadTrips: requestTripsReload,
                onRefresh: refreshJournal
            )
        } else {
            IPhoneShell(
                trips: $tripLoader.trips,
                isLoadingTrips: tripLoader.blogID != workspace.blog.id && tripLoader.failure == nil,
                journalService: journalService,
                blog: workspace.blog,
                blogger: workspace.blogger,
                sharingService: sharingService,
                onReloadTrips: requestTripsReload,
                onRefresh: refreshJournal
            )
        }
    }

    private var shouldUseIPadLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    private var blockingLoadFailure: JournalNotice? {
        guard tripLoader.blogID != workspace.blog.id else { return nil }
        return tripLoader.failure
    }

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
    }

    private func requestTripsReload() {
        reloadGeneration += 1
    }

    private func refreshJournal() async {
        await sharingService.recoverSharedJournalRelationships()
        requestTripsReload()
    }

    private var cloudCheckToast: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Checking for iCloud Blog…")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .padding(.top, 10)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
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

private struct JournalObservationRequest: Equatable {
    let blogID: Blog.ID
    let attempt: Int
}

private struct JournalLoadFailureView: View {
    let notice: JournalNotice
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(notice.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(notice.message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("journal-load-failure")
    }
}

private struct TripLoadRequest: Equatable {
    let blogID: Blog.ID
    let generation: Int
    let isCheckingCloudBlogs: Bool
}

private extension TripDisplay {
    var hasPendingUpload: Bool {
        days.contains { day in
            day.blogItems.contains { $0.syncStatus == .pending }
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
