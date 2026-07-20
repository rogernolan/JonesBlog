import GRDB
import Observation
import Sentry

import SQLiteData
import StructuredQueriesCore
import SwiftUI

@main
struct InstaBlogApp: App {
    @UIApplicationDelegateAdaptor(InstaBlogAppDelegate.self) private var appDelegate
    @State private var startup: StartupCoordinator

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
        if !isUITesting {
            SentrySDK.start { options in
                options.dsn = "https://f279a174bb072751f2c2c31001fe8ebb@o4511755059462144.ingest.de.sentry.io/4511755100422224"
                options.sendDefaultPii = false
                options.enableLogs = true

                // Keep Sentry limited to crashes, explicit logs, and curated breadcrumbs.
                options.sampleRate = 1
                options.enableCrashHandler = true
                options.enableAutoSessionTracking = false
                options.enableWatchdogTerminationTracking = false
                options.enableAutoPerformanceTracing = false
                options.enableNetworkBreadcrumbs = false
                options.enableNetworkTracking = false
                options.enableAppHangTracking = false
                options.enableAutoBreadcrumbTracking = false
                options.enableMetrics = false
                options.enableMetricKit = true
                options.enableMetricKitRawPayload = false
                options.enableSwizzling = false
                options.enableCaptureFailedRequests = false
                options.sessionReplay.sessionSampleRate = 0
                options.sessionReplay.onErrorSampleRate = 0
            }
            MetricKitAggregateReporter.shared.start()
        }
        AppTelemetry.log(
            "Runtime environment detected",
            category: "app.startup",
            data: [
                "cloudkit_environment": AppRuntimeEnvironment.cloudKitEnvironment,
                "development_signed": AppRuntimeEnvironment.isDevelopmentSigned,
                "build_source": AppRuntimeEnvironment.buildSource.rawValue,
                "version_build": AppRuntimeEnvironment.versionAndBuild,
            ]
        )
        _startup = State(initialValue: StartupCoordinator(isUITesting: isUITesting))
    }

    var body: some Scene {
        WindowGroup {
            startupView
        }
    }

    @ViewBuilder
    private var startupView: some View {
        switch startup.state {
        case .ready(let runtime):
            ContentView(
                workspace: runtime.initialWorkspace,
                sharingService: runtime.sharingService,
                shareAcceptanceCoordinator: runtime.shareAcceptanceCoordinator,
                loadWorkspace: {
                    try Self.loadActiveWorkspace(from: runtime.database)
                },
                observeWorkspace: {
                    Self.observeActiveWorkspace(from: runtime.database)
                },
                observeJournalChanges: { blogID in
                    Self.observeJournalChanges(from: runtime.database, blogID: blogID)
                },
                makeJournalService: { workspace in
                    JournalService(
                        database: runtime.database,
                        blogID: workspace.blog.id,
                        bloggerID: workspace.blogger.id,
                        syncStatusOverride: runtime.syncStatusOverride,
                        photoAvailabilityOverride: runtime.photoAvailabilityOverride,
                        mediaAssetSyncService: runtime.mediaAssetSyncService
                    )
                }
            )
        case .bloggerSelectionRequired(let pending):
            BloggerSelectionRecoveryView(
                requirement: pending.requirement,
                errorMessage: startup.recoveryErrorMessage,
                onSelect: startup.selectBlogger,
                onCreate: startup.createBlogger
            )
        case .failed(let message):
            StartupFailureView(message: message, retry: startup.retry)
        case .preparing:
            ProgressView("Opening InstaBlog…")
        }
    }

    struct Runtime {
        let database: any DatabaseWriter
        let sharingService: any BlogSharingServiceProtocol
        let initialWorkspace: ActiveWorkspace
        let shareAcceptanceCoordinator: ShareAcceptanceCoordinator
        let syncStatusOverride: BlogItemSyncStatus?
        let photoAvailabilityOverride: BlogItemPhotoAvailability?
        let mediaAssetSyncService: MediaAssetSyncService?
    }

    struct PendingStartup {
        let database: any DatabaseWriter
        let persistence: AppPersistence?
        let requirement: BloggerSelectionRequirement
        let isUITesting: Bool
        let syncStatusOverride: BlogItemSyncStatus?
        let photoAvailabilityOverride: BlogItemPhotoAvailability?
    }

    enum LaunchState {
        case preparing
        case ready(Runtime)
        case bloggerSelectionRequired(PendingStartup)
        case failed(String)
    }

    @MainActor
    @Observable
    final class StartupCoordinator {
        private(set) var state: LaunchState = .preparing
        private(set) var recoveryErrorMessage: String?
        private let isUITesting: Bool
#if DEBUG
        private var hasInjectedStartupFailure = false
#endif

        init(isUITesting: Bool) {
            self.isUITesting = isUITesting
            Task { await prepareDatabase() }
        }

        func retry() {
            recoveryErrorMessage = nil
            state = .preparing
            Task { await prepareDatabase() }
        }

        private func prepareDatabase() async {
            do {
#if DEBUG
                if isUITesting,
                   ProcessInfo.processInfo.arguments.contains("-ui-testing-startup-failure-once"),
                   !hasInjectedStartupFailure {
                    hasInjectedStartupFailure = true
                    throw StartupUITestFailure()
                }
#endif
                let syncStatusOverride = ProcessInfo.processInfo.environment["UI_TEST_SYNC_STATUS"]
                    .flatMap(BlogItemSyncStatus.init(rawValue:))
                let photoAvailabilityOverride = ProcessInfo.processInfo.environment["UI_TEST_PHOTO_AVAILABILITY"]
                    .flatMap(BlogItemPhotoAvailability.init(rawValue:))
                let database = try isUITesting
                    ? AppDatabase.makeInMemory()
                    : AppDatabase.makeLive()
#if DEBUG
                if isUITesting {
                    if ProcessInfo.processInfo.arguments.contains("-ui-testing-stale-blogger-identity") {
                        try Self.prepareBloggerRecoveryUITest(database: database)
                    } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-missing-active-blog") {
                        try Self.prepareMissingActiveBlogUITest(database: database)
                    }
                }
#endif
                let persistence: AppPersistence?
                if SharingServiceAvailability.isEnabled(
                    containerIdentifier: AppCloudKitConfiguration.containerIdentifier,
                    isUITesting: isUITesting
                ) {
                    let livePersistence = try AppPersistence(
                        database: database,
                        containerIdentifier: AppCloudKitConfiguration.containerIdentifier
                    )
                    prepareDependencies {
                        $0.defaultSyncEngine = livePersistence.syncEngine
                    }
                    persistence = livePersistence
                    do {
                        AppTelemetry.record(
                            "Initial CloudKit sync started",
                            category: "cloud.sync"
                        )
                        try await livePersistence.syncEngine.syncChanges()
                        AppTelemetry.record(
                            "Initial CloudKit sync completed",
                            category: "cloud.sync"
                        )
                    } catch {
                        AppTelemetry.record(
                            "Initial CloudKit sync failed; continuing with local data",
                            category: "cloud.sync",
                            level: .warning,
                            error: error
                        )
                    }
                } else {
                    persistence = nil
                }
                let preparation = try BlogBootstrapService(database: database).prepare(
                    seed: Self.seed(isUITesting: isUITesting)
                )
                switch preparation {
                case .ready(let workspace):
                    state = .ready(try Self.makeRuntime(
                        database: database,
                        persistence: persistence,
                        workspace: workspace,
                        isUITesting: isUITesting,
                        syncStatusOverride: syncStatusOverride,
                        photoAvailabilityOverride: photoAvailabilityOverride
                    ))
                case .bloggerSelectionRequired(let requirement):
                    state = .bloggerSelectionRequired(PendingStartup(
                        database: database,
                        persistence: persistence,
                        requirement: requirement,
                        isUITesting: isUITesting,
                        syncStatusOverride: syncStatusOverride,
                        photoAvailabilityOverride: photoAvailabilityOverride
                    ))
                }
            } catch {
                AppTelemetry.capture(
                    error,
                    message: "App startup failed",
                    category: "app.startup"
                )
                state = .failed(
                    "InstaBlog could not prepare its database. Your data has not been changed. Please try again."
                )
            }
        }

        func selectBlogger(_ blogger: Blogger) {
            finishRecovery { pending in
                try BlogBootstrapService(database: pending.database).selectBlogger(
                    blogID: pending.requirement.blog.id,
                    bloggerID: blogger.id
                )
            }
        }

        func createBlogger(displayName: String) {
            let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else {
                recoveryErrorMessage = "Enter a display name for the new Blogger."
                return
            }
            finishRecovery { pending in
                try BlogBootstrapService(database: pending.database).createAndSelectBlogger(
                    blogID: pending.requirement.blog.id,
                    displayName: displayName
                )
            }
        }

        private func finishRecovery(
            _ operation: (PendingStartup) throws -> BootstrapWorkspace
        ) {
            guard case .bloggerSelectionRequired(let pending) = state else { return }
            do {
                let workspace = try operation(pending)
                recoveryErrorMessage = nil
                state = .ready(try Self.makeRuntime(
                    database: pending.database,
                    persistence: pending.persistence,
                    workspace: workspace,
                    isUITesting: pending.isUITesting,
                    syncStatusOverride: pending.syncStatusOverride,
                    photoAvailabilityOverride: pending.photoAvailabilityOverride
                ))
            } catch {
                recoveryErrorMessage = "The Blogger could not be selected. Please try again."
                AppTelemetry.log(
                    "Blogger identity recovery failed",
                    category: "app.startup",
                    level: .error,
                    error: error
                )
            }
        }

        private static func makeRuntime(
            database: any DatabaseWriter,
            persistence: AppPersistence?,
            workspace: BootstrapWorkspace,
            isUITesting: Bool,
            syncStatusOverride: BlogItemSyncStatus?,
            photoAvailabilityOverride: BlogItemPhotoAvailability?
        ) throws -> Runtime {
            let sharingService: any BlogSharingServiceProtocol
            let mediaAssetSyncService: MediaAssetSyncService?
            if !SharingServiceAvailability.isEnabled(
                containerIdentifier: AppCloudKitConfiguration.containerIdentifier,
                isUITesting: isUITesting
            ) {
                sharingService = UnavailableBlogSharingService(database: database)
                mediaAssetSyncService = nil
            } else {
                guard let persistence else { throw StartupRuntimeError.missingPersistence }
                sharingService = BlogSharingService(persistence: persistence)
                mediaAssetSyncService = MediaAssetSyncService(persistence: persistence)
            }
            let shareAcceptanceCoordinator = ShareAcceptanceCoordinator(
                sharingService: sharingService
            )
            let initialWorkspace = try InstaBlogApp.loadActiveWorkspace(
                from: database,
                fallback: workspace
            )
            CloudKitSceneBridge.shareAcceptanceHandler = { metadata in
                Task {
                    await shareAcceptanceCoordinator.receive(
                        metadata,
                        resolvingActiveBlogID: {
                            let persistedBlogID = try await database.read { db in
                                try AppWorkspace
                                    .find(AppWorkspace.singletonID)
                                    .select(\.activeBlogID)
                                    .fetchOne(db)
                                    ?? nil
                            }
                            return persistedBlogID ?? workspace.blog.id
                        }
                    )
                }
            }
            InstaBlogAppDelegate.remoteNotificationHandler = {
                await RemoteNotificationSyncHandler.run(
                    synchronizeCloudState: {
                        await sharingService.synchronizeCloudState()
                    },
                    loadActiveBlogID: {
                        try await database.read { db in
                            try AppWorkspace
                                .find(AppWorkspace.singletonID)
                                .select(\.activeBlogID)
                                .fetchOne(db)
                                ?? nil
                        }
                    },
                    synchronizeMedia: { blogID in
                        try await mediaAssetSyncService?.synchronize(blogID: blogID)
                    }
                )
            }
            return Runtime(
                database: database,
                sharingService: sharingService,
                initialWorkspace: initialWorkspace,
                shareAcceptanceCoordinator: shareAcceptanceCoordinator,
                syncStatusOverride: syncStatusOverride,
                photoAvailabilityOverride: photoAvailabilityOverride,
                mediaAssetSyncService: mediaAssetSyncService
            )
        }

        private static func seed(isUITesting: Bool) -> FirstRunSeed? {
#if DEBUG
            guard isUITesting else { return nil }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-empty-blog") {
                return nil
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-empty-current-trip") {
                return DevelopmentSampleData.emptyCurrentTripUITestSeed
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-historical-trip") {
                return DevelopmentSampleData.historicalTripUITestSeed
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-gallery") {
                return DevelopmentSampleData.galleryUITestSeed
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-linked-posts") {
                return DevelopmentSampleData.linkedPostsUITestSeed
            } else {
                return DevelopmentSampleData.firstRunSeed
            }
#else
            return nil
#endif
        }

#if DEBUG
        private static func prepareBloggerRecoveryUITest(
            database: any DatabaseWriter
        ) throws {
            let workspace = try BlogBootstrapService(database: database).bootstrap()
            let timestamp = Date()
            try database.write { db in
                for displayName in ["Jane", "Rog"] {
                    try Blogger.insert {
                        Blogger.Draft(
                            id: UUID(),
                            blogID: workspace.blog.id,
                            displayName: displayName,
                            createdAt: timestamp,
                            updatedAt: timestamp
                        )
                    }.execute(db)
                }
                try Blogger.find(workspace.blogger.id).delete().execute(db)
            }
        }

        private static func prepareMissingActiveBlogUITest(
            database: any DatabaseWriter
        ) throws {
            _ = try BlogBootstrapService(database: database).bootstrap()
            try database.write { db in
                try AppWorkspace.find(AppWorkspace.singletonID)
                    .update { $0.activeBlogID = #bind(UUID()) }
                    .execute(db)
            }
        }
#endif
    }

#if DEBUG
    private struct StartupUITestFailure: Error {}
#endif

    private enum StartupRuntimeError: Error {
        case missingPersistence
    }

    private static func loadActiveWorkspace(
        from database: any DatabaseWriter,
        fallback: BootstrapWorkspace? = nil
    ) throws -> ActiveWorkspace {
        try database.read { db in
            try loadActiveWorkspace(from: db, fallback: fallback)
        }
    }

    private static func observeActiveWorkspace(
        from database: any DatabaseWriter
    ) -> AsyncValueObservation<ActiveWorkspace> {
        ValueObservation
            .tracking { db in
                try loadActiveWorkspace(from: db)
            }
            .values(in: database)
    }

    private static func observeJournalChanges(
        from database: any DatabaseWriter,
        blogID: Blog.ID
    ) -> AsyncValueObservation<JournalChangeToken> {
        JournalChangeObserver.observe(database: database, blogID: blogID)
    }

    private static func loadActiveWorkspace(
        from db: Database,
        fallback: BootstrapWorkspace? = nil
    ) throws -> ActiveWorkspace {
        let activeBlogID = try AppWorkspace
            .find(AppWorkspace.singletonID)
            .select(\.activeBlogID)
            .fetchOne(db)
            ?? nil
        let blog: Blog
        if let activeBlogID {
            blog = try Blog.find(db, key: activeBlogID)
        } else if let fallback {
            blog = fallback.blog
        } else {
            throw ActiveWorkspaceError.missingBlog
        }

        let identity = try AppBlogIdentity.find(blog.id).fetchOne(db)
        let blogger = if let identity {
            try Blogger.find(db, key: identity.bloggerID)
        } else if let fallback, fallback.blog.id == blog.id {
            fallback.blogger
        } else if let first = try Blogger
            .where({ $0.blogID.eq(blog.id) })
            .order(by: { ($0.createdAt, $0.id) })
            .fetchOne(db)
        {
            first
        } else {
            throw ActiveWorkspaceError.missingBlogger
        }
        return ActiveWorkspace(blog: blog, blogger: blogger)
    }

}

private struct StartupFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Open InstaBlog", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct BloggerSelectionRecoveryView: View {
    let requirement: BloggerSelectionRequirement
    let errorMessage: String?
    let onSelect: (Blogger) -> Void
    let onCreate: (String) -> Void

    @State private var isShowingSelection = true
    @State private var isCreatingBlogger = false
    @State private var newDisplayName = ""

    var body: some View {
        ContentUnavailableView {
            Label("Choose Your Blogger", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            VStack(spacing: 8) {
                Text("Choose the Blogger you use for \(requirement.blog.title), or create a new one.")
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(AppColors.alertRed)
                }
            }
        } actions: {
            Button("Choose Blogger") {
                isShowingSelection = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("Choose Blogger")
        }
        .confirmationDialog(
            "Choose Your Blogger",
            isPresented: $isShowingSelection,
            titleVisibility: .visible
        ) {
            ForEach(requirement.bloggers) { blogger in
                Button(blogger.displayName) {
                    onSelect(blogger)
                }
            }
            Button("Create New Blogger") {
                isCreatingBlogger = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Blogger previously selected on this device is no longer available.")
        }
        .alert("Create Blogger", isPresented: $isCreatingBlogger) {
            TextField("Display name", text: $newDisplayName)
                .accessibilityIdentifier("New Blogger display name")
            Button("Cancel", role: .cancel) {
                isShowingSelection = true
            }
            Button("Create") {
                onCreate(newDisplayName)
            }
            .disabled(newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter the display name to use when writing posts.")
        }
    }
}

private enum ActiveWorkspaceError: Error {
    case missingBlog
    case missingBlogger
}
