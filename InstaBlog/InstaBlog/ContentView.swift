import GRDB
import Observation
import SwiftUI

nonisolated struct ActiveWorkspace: Equatable {
    let blog: Blog
    let blogger: Blogger
}

nonisolated enum BlogUpdateObservation: Hashable {
    case journal
    case workspace
}

nonisolated struct BlogUpdateRetryDecision: Equatable {
    let shouldShowPausedNotice: Bool
    let delay: Duration
    let attempt: Int
}

nonisolated struct BlogUpdateRetryState {
    private(set) var failingObservations: Set<BlogUpdateObservation> = []
    private(set) var attempts: [BlogUpdateObservation: Int] = [:]
    private let initialDelaySeconds: Int
    private let maximumDelaySeconds: Int

    init(initialDelaySeconds: Int = 5, maximumDelaySeconds: Int = 300) {
        self.initialDelaySeconds = initialDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
    }

    mutating func registerFailure(
        for observation: BlogUpdateObservation
    ) -> BlogUpdateRetryDecision {
        let shouldShowPausedNotice = failingObservations.isEmpty
        failingObservations.insert(observation)
        let attempt = (attempts[observation] ?? 0) + 1
        attempts[observation] = attempt
        let exponent = min(attempt - 1, 30)
        let multiplier = 1 << exponent
        let delaySeconds = min(initialDelaySeconds * multiplier, maximumDelaySeconds)
        return BlogUpdateRetryDecision(
            shouldShowPausedNotice: shouldShowPausedNotice,
            delay: .seconds(delaySeconds),
            attempt: attempt
        )
    }

    mutating func registerRecovery(for observation: BlogUpdateObservation) {
        failingObservations.remove(observation)
        attempts[observation] = nil
    }
}

@MainActor
@Observable
final class JournalTripLoader {
    private(set) var blogID: Blog.ID?
    var trips: [TripDisplay] = []
    private(set) var isLoading = false
    private(set) var isLoadingUnassigned = false
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
        isLoadingUnassigned = false
        failure = nil
    }

    func load(
        blogID: Blog.ID,
        operation: @escaping @Sendable () throws -> [TripDisplay]
    ) async {
        let requestID = UUID()
        self.requestID = requestID
        isLoading = true
        isLoadingUnassigned = false
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

    func loadCurrentTrip(
        blogID: Blog.ID,
        operation: @escaping @Sendable () throws -> TripDisplay?
    ) async {
        await load(blogID: blogID) {
            try operation().map { [$0] } ?? []
        }
    }

    func loadUnassigned(
        blogID: Blog.ID,
        operation: @escaping @Sendable () throws -> TripDisplay?
    ) async {
        let requestID = UUID()
        self.requestID = requestID
        isLoadingUnassigned = true
        defer {
            if self.requestID == requestID {
                isLoadingUnassigned = false
            }
        }
        do {
            let loadedTrip = try await Task.detached(priority: .userInitiated) {
                try operation()
            }.value
            guard self.requestID == requestID else { return }
            trips.removeAll { $0.isUnassigned }
            if let loadedTrip {
                trips.insert(loadedTrip, at: 0)
            }
        } catch {
            guard self.requestID == requestID else { return }
            AppTelemetry.log(
                "Failed to load unassigned journal entries",
                category: "journal.loading",
                level: .error,
                error: error,
                data: ["blog_id": blogID.uuidString]
            )
            logFailure("Failed to load unassigned journal entries for blog \(blogID): \(error.localizedDescription)")
        }
    }
}

nonisolated enum JournalMutationRunner {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: .userInitiated) {
            try operation()
        }.value
    }
}

struct ContentView: View {
    @State private var workspace: ActiveWorkspace
    @State private var journalService: JournalService
    @State private var recipientStore: EmailRecipientStore
    @State private var tripLoader = JournalTripLoader()
    @State private var contentNotices = JournalActionErrorState()
    @State private var reloadGeneration = 0
    @State private var unassignedReloadGeneration = 0
    @State private var shouldLoadAllTrips = false
    @State private var hasLoadedAllTrips = false
    @State private var journalObservationAttempt = 0
    @State private var workspaceObservationAttempt = 0
    @State private var blogUpdateRetryState = BlogUpdateRetryState()
    @State private var editorDraftStore = JournalEditorDraftStore()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    let sharingService: any BlogSharingServiceProtocol
    let shareAcceptanceCoordinator: ShareAcceptanceCoordinator
    let cloudArrivalNotices: CloudJournalArrivalNotices
    let loadWorkspace: () throws -> ActiveWorkspace
    let observeWorkspace: () -> AsyncValueObservation<ActiveWorkspace>
    let observeJournalChanges: (Blog.ID) -> AsyncValueObservation<JournalChangeToken>
    let makeJournalService: (ActiveWorkspace) -> JournalService
    let makeRecipientStore: (ActiveWorkspace) -> EmailRecipientStore
    let eraseAndImportArchive: (URL) -> Void
    let resetDatabase: (() -> Void)?

    init(
        workspace: ActiveWorkspace,
        sharingService: any BlogSharingServiceProtocol,
        shareAcceptanceCoordinator: ShareAcceptanceCoordinator,
        cloudArrivalNotices: CloudJournalArrivalNotices,
        loadWorkspace: @escaping () throws -> ActiveWorkspace,
        observeWorkspace: @escaping () -> AsyncValueObservation<ActiveWorkspace>,
        observeJournalChanges: @escaping (Blog.ID) -> AsyncValueObservation<JournalChangeToken>,
        makeJournalService: @escaping (ActiveWorkspace) -> JournalService,
        makeRecipientStore: @escaping (ActiveWorkspace) -> EmailRecipientStore,
        eraseAndImportArchive: @escaping (URL) -> Void = { _ in },
        resetDatabase: (() -> Void)? = nil
    ) {
        _workspace = State(initialValue: workspace)
        _journalService = State(initialValue: makeJournalService(workspace))
        _recipientStore = State(initialValue: makeRecipientStore(workspace))
        self.sharingService = sharingService
        self.shareAcceptanceCoordinator = shareAcceptanceCoordinator
        self.cloudArrivalNotices = cloudArrivalNotices
        self.loadWorkspace = loadWorkspace
        self.observeWorkspace = observeWorkspace
        self.observeJournalChanges = observeJournalChanges
        self.makeJournalService = makeJournalService
        self.makeRecipientStore = makeRecipientStore
        self.eraseAndImportArchive = eraseAndImportArchive
        self.resetDatabase = resetDatabase
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
                JournalLoadFailureView(
                    notice: failure,
                    retry: requestTripsReload,
                    resetDatabase: resetDatabase
                )
            }

            ShareAcceptanceOverlay(
                coordinator: shareAcceptanceCoordinator,
                onAccepted: reloadWorkspace,
                resetDatabase: resetDatabase
            )

            if let notice = cloudArrivalNotices.notice {
                CloudJournalArrivalToast(notice: notice)
            }
        }
        .journalActionErrors(contentNotices)
        .onChange(of: cloudArrivalNotices.blockingFailure?.id) { _, _ in
            if let failure = cloudArrivalNotices.blockingFailure {
                contentNotices.presentModal(failure)
            }
        }
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
        .task(id: cloudArrivalNotices.notice?.id) {
            guard let noticeID = cloudArrivalNotices.notice?.id else { return }
            do {
                try await Task.sleep(for: .seconds(5))
                cloudArrivalNotices.dismissNotice(id: noticeID)
            } catch {
                // The view was replaced before the toast's display interval elapsed.
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
            loadsAllTrips: shouldLoadAllTrips
        )) {
            guard !Task.isCancelled else { return }
            let service = journalService
            await tripLoader.loadCurrentTrip(blogID: workspace.blog.id) {
                try service.loadCurrentTrip()
            }
            while !Task.isCancelled {
                await service.synchronizeMediaAssets()
                await tripLoader.loadCurrentTrip(blogID: workspace.blog.id) {
                    try service.loadCurrentTrip()
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
            guard shouldLoadAllTrips else { return }
            await tripLoader.load(blogID: workspace.blog.id) {
                try service.loadTrips()
            }
            hasLoadedAllTrips = tripLoader.failure == nil
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
        .task(id: UnassignedLoadRequest(
            blogID: workspace.blog.id,
            generation: unassignedReloadGeneration
        )) {
            guard unassignedReloadGeneration > 0,
                  shouldLoadAllTrips,
                  !Task.isCancelled
            else { return }
            let service = journalService
            await tripLoader.loadUnassigned(blogID: workspace.blog.id) {
                try service.loadUnassignedTrip()
            }
        }
        .task(id: JournalObservationRequest(
            blogID: workspace.blog.id,
            attempt: journalObservationAttempt
        )) {
            do {
                for try await _ in observeJournalChanges(workspace.blog.id) {
                    guard !Task.isCancelled else { return }
                    blogUpdateRetryState.registerRecovery(for: .journal)
                    let service = journalService
                    if shouldLoadAllTrips {
                        await tripLoader.load(blogID: workspace.blog.id) {
                            try service.loadTrips()
                        }
                    } else {
                        await tripLoader.loadCurrentTrip(blogID: workspace.blog.id) {
                            try service.loadCurrentTrip()
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if JournalDatabaseFailure.isMissingMigration(error) {
                    contentNotices.reportFailure(
                        error,
                        context: "journal change observation",
                        as: .modal(JournalNotice(
                            title: "Journal Update Required",
                            message: "This app version cannot read the journal database. Update the app before continuing."
                        ))
                    )
                    return
                }
                let retry = blogUpdateRetryState.registerFailure(for: .journal)
                reportPausedBlogUpdatesIfNeeded(
                    retry,
                    error: error,
                    context: "journal change observation"
                )
                do {
                    try await Task.sleep(for: retry.delay)
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
                    blogUpdateRetryState.registerRecovery(for: .workspace)
                    guard updatedWorkspace != workspace else { continue }
                    workspace = updatedWorkspace
                    journalService = makeJournalService(updatedWorkspace)
                    recipientStore = makeRecipientStore(updatedWorkspace)
                    tripLoader.reset()
                }
            } catch {
                guard !Task.isCancelled else { return }
                let retry = blogUpdateRetryState.registerFailure(for: .workspace)
                reportPausedBlogUpdatesIfNeeded(
                    retry,
                    error: error,
                    context: "active workspace observation"
                )
                do {
                    try await Task.sleep(for: retry.delay)
                    workspaceObservationAttempt += 1
                } catch {
                    return
                }
            }
        }
    }

    private func reportPausedBlogUpdatesIfNeeded(
        _ retry: BlogUpdateRetryDecision,
        error: any Error,
        context: String
    ) {
        if retry.shouldShowPausedNotice {
            contentNotices.reportFailure(
                error,
                context: context,
                as: .toast(JournalNotice(
                    title: "Blog Updates Paused",
                    message: "Blog changes stopped updating. Retrying automatically."
                ))
            )
        } else {
            AppTelemetry.log(
                "Blog update retry failed",
                category: "journal.observation",
                level: .warning,
                error: error,
                data: ["attempt": retry.attempt]
            )
        }
    }

    @ViewBuilder
    private var shell: some View {
        if shouldUseIPadLayout {
            IPadShell(
                trips: $tripLoader.trips,
                hasResolvedCurrentTrip: tripLoader.blogID == workspace.blog.id,
                isLoadingAllTrips: shouldLoadAllTrips && tripLoader.isLoading,
                isLoadingUnassigned: tripLoader.isLoadingUnassigned,
                isLoadingShareTrips: shouldLoadAllTrips && !hasLoadedAllTrips,
                journalService: journalService,
                recipientStore: recipientStore,
                blog: workspace.blog,
                blogger: workspace.blogger,
                sharingService: sharingService,
                draftStore: editorDraftStore,
                eraseAndImportArchive: eraseAndImportArchive,
                onReloadTrips: requestTripsReload,
                onReloadUnassigned: requestUnassignedReload,
                onLoadAllTrips: requestAllTripsLoad,
                onRefresh: refreshJournal
            )
        } else {
            IPhoneShell(
                trips: $tripLoader.trips,
                hasResolvedCurrentTrip: tripLoader.blogID == workspace.blog.id,
                isLoadingAllTrips: shouldLoadAllTrips && tripLoader.isLoading,
                isLoadingUnassigned: tripLoader.isLoadingUnassigned,
                isLoadingShareTrips: shouldLoadAllTrips && !hasLoadedAllTrips,
                journalService: journalService,
                recipientStore: recipientStore,
                blog: workspace.blog,
                blogger: workspace.blogger,
                sharingService: sharingService,
                draftStore: editorDraftStore,
                eraseAndImportArchive: eraseAndImportArchive,
                onReloadTrips: requestTripsReload,
                onReloadUnassigned: requestUnassignedReload,
                onLoadAllTrips: requestAllTripsLoad,
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
        if shouldLoadAllTrips {
            hasLoadedAllTrips = false
        }
        reloadGeneration += 1
    }

    private func requestUnassignedReload() {
        guard shouldLoadAllTrips else {
            requestTripsReload()
            return
        }
        unassignedReloadGeneration += 1
    }

    private func requestAllTripsLoad() {
        guard !shouldLoadAllTrips else { return }
        hasLoadedAllTrips = false
        shouldLoadAllTrips = true
    }

    private func refreshJournal() async {
        await sharingService.recoverSharedJournalRelationships()
        requestTripsReload()
    }

    private func reloadWorkspace() throws {
        let reloaded = try loadWorkspace()
        workspace = reloaded
        journalService = makeJournalService(reloaded)
        recipientStore = makeRecipientStore(reloaded)
        tripLoader.reset()
        requestTripsReload()
    }

    private func reloadWorkspace(_ accepted: AcceptedBlog) throws {
        let reloaded = try loadWorkspace()
        guard reloaded.blog.id == accepted.blogID,
              reloaded.blogger.id == accepted.bloggerID
        else { throw ActiveWorkspaceReloadError.mismatchedAcceptedWorkspace }
        workspace = reloaded
        journalService = makeJournalService(reloaded)
        recipientStore = makeRecipientStore(reloaded)
        tripLoader.reset()
        requestTripsReload()
    }
}

private struct JournalObservationRequest: Equatable {
    let blogID: Blog.ID
    let attempt: Int
}

private struct UnassignedLoadRequest: Equatable {
    let blogID: Blog.ID
    let generation: Int
}

private struct CloudJournalArrivalToast: View {
    let notice: JournalNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notice.title).font(.headline)
            Text(notice.message).font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .shadow(radius: 6, y: 3)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct JournalLoadFailureView: View {
    let notice: JournalNotice
    let retry: () -> Void
    let resetDatabase: (() -> Void)?

    @State private var showsResetConfirmation = false

    var body: some View {
        ContentUnavailableView {
            Label(notice.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(notice.message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
#if DEBUG
            if resetDatabase != nil {
                Button("Reset Database", role: .destructive) {
                    showsResetConfirmation = true
                }
                .buttonStyle(.bordered)
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("journal-load-failure")
#if DEBUG
        .alert("Reset InstaBlog?", isPresented: $showsResetConfirmation) {
            Button("Reset Database", role: .destructive) {
                resetDatabase?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes this build’s local Blog, photos, iCloud records, and shares. The app will reopen as a new install."
            )
        }
#endif
    }
}

private struct TripLoadRequest: Equatable {
    let blogID: Blog.ID
    let generation: Int
    let loadsAllTrips: Bool
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
    let resetDatabase: (() -> Void)?
    @AccessibilityFocusState private var isModalFocused: Bool
    @State private var showsResetConfirmation = false

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
                    HStack {
#if DEBUG
                        if resetDatabase != nil {
                            Button("Reset Database", role: .destructive) {
                                showsResetConfirmation = true
                            }
                        }
                        Spacer()
#endif
                        Button("Retry") {
                            coordinator.retryAcceptedWorkspaceReload()
                        }
                        .buttonStyle(.borderedProminent)
                    }
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
#if DEBUG
        .alert("Reset InstaBlog?", isPresented: $showsResetConfirmation) {
            Button("Reset Database", role: .destructive) {
                resetDatabase?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes this build’s local Blog, photos, iCloud records, and shares. The app will reopen as a new install."
            )
        }
#endif
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
