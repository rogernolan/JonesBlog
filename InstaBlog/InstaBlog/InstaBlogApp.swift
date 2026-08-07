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
    @State private var showsProductionDataWarning: Bool

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
        _startup = State(initialValue: StartupCoordinator(isUITesting: isUITesting))
        _showsProductionDataWarning = State(
            initialValue: !isUITesting
                && AppRuntimeEnvironment.current.requiresProductionDataWarning
        )
    }

    var body: some Scene {
        WindowGroup {
            startupView
                .alert(
                    "Live Production Data",
                    isPresented: $showsProductionDataWarning
                ) {
                    Button("I Understand") {}
                } message: {
                    Text(
                        "This debug build is connected to the production CloudKit database used by TestFlight and the App Store. Changes here affect live data."
                    )
                }
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
                },
                eraseAndImportArchive: startup.eraseAndImportArchive,
                resetDatabase: startup.debugResetDatabase
            )
        case .bloggerSelectionRequired(let pending):
            BloggerSelectionRecoveryView(
                requirement: pending.requirement,
                errorMessage: startup.recoveryErrorMessage,
                onSelect: startup.selectBlogger,
                onCreate: startup.createBlogger,
                resetDatabase: startup.debugResetDatabase
            )
        case .failed(let message):
#if DEBUG && !MIGRATION_EXPORT
            StartupFailureView(
                message: message,
                retry: startup.retry,
                resetDatabase: startup.resetDatabase
            )
#else
            StartupFailureView(
                message: message,
                retry: startup.retry,
                resetDatabase: nil
            )
#endif
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
        let syncEngine: SyncEngine?
    }

    struct PendingStartup {
        let database: any DatabaseWriter
        let persistence: AppPersistence?
        let requirement: BloggerSelectionRequirement
        let isUITesting: Bool
        let syncStatusOverride: BlogItemSyncStatus?
        let photoAvailabilityOverride: BlogItemPhotoAvailability?
        let cloudSyncEnabled: Bool
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
#if DEBUG && !MIGRATION_EXPORT
            if DevelopmentCloudKitSchemaBootstrapper.isRequested {
                bootstrapDevelopmentCloudKitSchema()
                return
            }
#endif
            prepareDatabase()
        }

#if DEBUG && !MIGRATION_EXPORT
        private func bootstrapDevelopmentCloudKitSchema() {
            Task {
                do {
                    let result = try await DevelopmentCloudKitSchemaBootstrapper.run()
                    let recordTypes = result.recordTypes.sorted().joined(separator: ", ")
                    let message = "Development CloudKit schema initialized: \(recordTypes). "
                        + "Temporary zone deleted: \(result.deletedZoneName)."
                    print("[cloud.schema] \(message)")
                    state = .failed(message)
                } catch {
                    AppTelemetry.capture(
                        error,
                        message: "Development CloudKit schema initialization failed",
                        category: "cloud.schema"
                    )
                    state = .failed(
                        "Development CloudKit schema initialization failed. See the console for details."
                    )
                }
            }
        }
#endif

        var debugResetDatabase: (() -> Void)? {
#if DEBUG && !MIGRATION_EXPORT
            resetDatabase
#else
            nil
#endif
        }

        func retry() {
            recoveryErrorMessage = nil
            state = .preparing
            prepareDatabase()
        }

        func eraseAndImportArchive(_ archiveURL: URL) {
            guard case .ready(let runtime) = state else { return }
            runtime.syncEngine?.stop()
            let databaseToClose = runtime.database
            releaseRuntime()
            state = .preparing

            Task {
                defer {
                    try? FileManager.default.removeItem(
                        at: archiveURL.deletingLastPathComponent()
                    )
                }
                await Task.yield()
                do {
                    try databaseToClose.close()
                    let resetService = AppDataResetService()
                    try await resetService.eraseCloudData()
                    try resetService.eraseLocalData()

                    let database = try AppDatabase.makeLive()
                    let persistence = try Self.makePausedPersistence(
                        database: database,
                        isUITesting: isUITesting
                    )
                    try await Self.reconcileCloudResetBeforeLocalData(persistence)
                    _ = try await BlogArchiveService(database: database).importBlog(from: archiveURL)
                    try finishPreparing(
                        database: database,
                        persistence: persistence,
                        cloudSyncEnabled: false
                    )
                } catch {
                    AppTelemetry.capture(
                        error,
                        message: "Destructive archive import failed",
                        category: "data.transfer"
                    )
                    state = .failed(
                        "Erase and import did not complete. Use Reset Database, then try the import again."
                    )
                }
            }
        }

#if DEBUG && !MIGRATION_EXPORT
        func resetDatabase() {
            let databaseToClose: (any DatabaseWriter)?
            switch state {
            case .ready(let runtime):
                runtime.syncEngine?.stop()
                databaseToClose = runtime.database
            case .bloggerSelectionRequired(let pending):
                databaseToClose = pending.database
            case .preparing, .failed:
                databaseToClose = nil
            }
            releaseRuntime()
            state = .preparing
            Task {
                await Task.yield()
                do {
                    try databaseToClose?.close()
                    let resetService = AppDataResetService()
                    try await resetService.eraseCloudData()
                    try resetService.eraseLocalData()
                    let database = try AppDatabase.makeLive()
                    let persistence = try Self.makePausedPersistence(
                        database: database,
                        isUITesting: isUITesting
                    )
                    try await Self.reconcileCloudResetBeforeLocalData(persistence)
                    try finishPreparing(
                        database: database,
                        persistence: persistence,
                        cloudSyncEnabled: false
                    )
                } catch {
                    AppTelemetry.capture(
                        error,
                        message: "Debug database reset failed",
                        category: "app.startup"
                    )
                    state = .failed(
                        "InstaBlog could not reset its local and iCloud data. Please try again."
                    )
                }
            }
        }
#endif

        private func prepareDatabase() {
            Task {
                await prepareDatabaseNow()
            }
        }

        private func prepareDatabaseNow() async {
            var databaseToClose: (any DatabaseWriter)?
            var persistenceToStop: AppPersistence?
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
                databaseToClose = database
                let persistence = try Self.makePausedPersistence(
                    database: database,
                    isUITesting: isUITesting
                )
                persistenceToStop = persistence
#if DEBUG
                if isUITesting {
                    if ProcessInfo.processInfo.arguments.contains("-ui-testing-stale-blogger-identity") {
                        try Self.prepareBloggerRecoveryUITest(database: database)
                    } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-missing-active-blog") {
                        try Self.prepareMissingActiveBlogUITest(database: database)
                    }
                }
#endif
                if let persistence {
                    do {
                        let recovered = try await StartupCloudRecoveryService(
                            database: database,
                            operations: .init(syncEngine: persistence.syncEngine)
                        ).recoverIfNeeded()
                        if recovered {
                            AppTelemetry.log(
                                "Initial CloudKit recovery completed before first local blog creation",
                                category: "app.startup"
                            )
                        }
                    } catch {
                        AppTelemetry.log(
                            "Initial CloudKit recovery was unavailable; continuing offline",
                            category: "app.startup",
                            level: .warning,
                            error: error
                        )
                    }
                }
                let preparation = try BlogBootstrapService(database: database).prepare(
                    seed: Self.seed(isUITesting: isUITesting)
                )
                try finishPreparing(
                    database: database,
                    persistence: persistence,
                    preparation: preparation,
                    syncStatusOverride: syncStatusOverride,
                    photoAvailabilityOverride: photoAvailabilityOverride
                )
                databaseToClose = nil
                persistenceToStop = nil
            } catch {
                persistenceToStop?.syncEngine.stop()
                try? databaseToClose?.close()
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

        private func finishPreparing(
            database: any DatabaseWriter,
            persistence: AppPersistence?,
            cloudSyncEnabled: Bool = true
        ) throws {
            let syncStatusOverride = ProcessInfo.processInfo.environment["UI_TEST_SYNC_STATUS"]
                .flatMap(BlogItemSyncStatus.init(rawValue:))
            let photoAvailabilityOverride = ProcessInfo.processInfo.environment["UI_TEST_PHOTO_AVAILABILITY"]
                .flatMap(BlogItemPhotoAvailability.init(rawValue:))
            let preparation = try BlogBootstrapService(database: database).prepare(
                seed: Self.seed(isUITesting: isUITesting)
            )
            try finishPreparing(
                database: database,
                persistence: persistence,
                preparation: preparation,
                syncStatusOverride: syncStatusOverride,
                photoAvailabilityOverride: photoAvailabilityOverride,
                cloudSyncEnabled: cloudSyncEnabled
            )
        }

        private func finishPreparing(
            database: any DatabaseWriter,
            persistence: AppPersistence?,
            preparation: BootstrapPreparation,
            syncStatusOverride: BlogItemSyncStatus?,
            photoAvailabilityOverride: BlogItemPhotoAvailability?,
            cloudSyncEnabled: Bool = true
        ) throws {
            switch preparation {
                case .ready(let workspace):
                    let runtime = try Self.makeRuntime(
                        database: database,
                        persistence: persistence,
                        workspace: workspace,
                        isUITesting: isUITesting,
                        syncStatusOverride: syncStatusOverride,
                        photoAvailabilityOverride: photoAvailabilityOverride,
                        cloudSyncEnabled: cloudSyncEnabled
                    )
                    activate(runtime, cloudSyncEnabled: cloudSyncEnabled)
                case .bloggerSelectionRequired(let requirement):
                    state = .bloggerSelectionRequired(PendingStartup(
                        database: database,
                        persistence: persistence,
                        requirement: requirement,
                        isUITesting: isUITesting,
                        syncStatusOverride: syncStatusOverride,
                        photoAvailabilityOverride: photoAvailabilityOverride,
                        cloudSyncEnabled: cloudSyncEnabled
                    ))
            }
        }

        private func releaseRuntime() {
            CloudKitSceneBridge.shareAcceptanceHandler = nil
            InstaBlogAppDelegate.remoteNotificationHandler = nil
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
                let runtime = try Self.makeRuntime(
                    database: pending.database,
                    persistence: pending.persistence,
                    workspace: workspace,
                    isUITesting: pending.isUITesting,
                    syncStatusOverride: pending.syncStatusOverride,
                    photoAvailabilityOverride: pending.photoAvailabilityOverride,
                    cloudSyncEnabled: pending.cloudSyncEnabled
                )
                activate(runtime, cloudSyncEnabled: pending.cloudSyncEnabled)
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

        private func activate(_ runtime: Runtime, cloudSyncEnabled: Bool) {
            state = .ready(runtime)
            guard cloudSyncEnabled, let syncEngine = runtime.syncEngine else { return }
            Task {
                do {
                    try await syncEngine.start()
                } catch {
                    AppTelemetry.log(
                        "CloudKit synchronization could not start",
                        category: "cloud.sync",
                        level: .error,
                        error: error
                    )
                }
            }
        }

        private static func makeRuntime(
            database: any DatabaseWriter,
            persistence: AppPersistence?,
            workspace: BootstrapWorkspace,
            isUITesting: Bool,
            syncStatusOverride: BlogItemSyncStatus?,
            photoAvailabilityOverride: BlogItemPhotoAvailability?,
            cloudSyncEnabled: Bool = true
        ) throws -> Runtime {
            let initialWorkspace = try InstaBlogApp.loadActiveWorkspace(
                from: database,
                fallback: workspace
            )
            let sharingService: any BlogSharingServiceProtocol
            let mediaAssetSyncService: MediaAssetSyncService?
            let syncEngine: SyncEngine?
            if !cloudSyncEnabled || !SharingServiceAvailability.isEnabled(
                containerIdentifier: AppCloudKitConfiguration.containerIdentifier,
                isUITesting: isUITesting
            ) {
                sharingService = UnavailableBlogSharingService(database: database)
                mediaAssetSyncService = nil
                syncEngine = persistence?.syncEngine
            } else {
                guard let persistence else {
                    throw RuntimeConfigurationError.missingPersistence
                }
                sharingService = BlogSharingService(persistence: persistence)
                mediaAssetSyncService = MediaAssetSyncService(persistence: persistence)
                syncEngine = persistence.syncEngine
            }
            let shareAcceptanceCoordinator = ShareAcceptanceCoordinator(
                sharingService: sharingService
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
                mediaAssetSyncService: mediaAssetSyncService,
                syncEngine: syncEngine
            )
        }

        private static func makePausedPersistence(
            database: any DatabaseWriter,
            isUITesting: Bool
        ) throws -> AppPersistence? {
            guard SharingServiceAvailability.isEnabled(
                containerIdentifier: AppCloudKitConfiguration.containerIdentifier,
                isUITesting: isUITesting
            ) else { return nil }
            return try AppPersistence(
                database: database,
                containerIdentifier: AppCloudKitConfiguration.containerIdentifier,
                startImmediately: false
            )
        }

        private static func reconcileCloudResetBeforeLocalData(
            _ persistence: AppPersistence?
        ) async throws {
            guard let syncEngine = persistence?.syncEngine else { return }
            defer { syncEngine.stop() }

            AppTelemetry.log(
                "Reconciling empty CloudKit state after destructive reset",
                category: "cloud.reset"
            )
            try await syncEngine.start()
            try await syncEngine.syncChanges()
            try await syncEngine.syncChanges()
            AppTelemetry.log(
                "Empty CloudKit state is ready for local data",
                category: "cloud.reset"
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
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-inline-editing") {
                return DevelopmentSampleData.inlineEditingUITestSeed
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
    let resetDatabase: (() -> Void)?

    @State private var showsResetConfirmation = false

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Open InstaBlog", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
            if resetDatabase != nil {
                Button("Reset Database", role: .destructive) {
                    showsResetConfirmation = true
                }
                .buttonStyle(.bordered)
            }
        }
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
    }
}

private struct BloggerSelectionRecoveryView: View {
    let requirement: BloggerSelectionRequirement
    let errorMessage: String?
    let onSelect: (Blogger) -> Void
    let onCreate: (String) -> Void
    let resetDatabase: (() -> Void)?

    @State private var isShowingSelection = true
    @State private var isCreatingBlogger = false
    @State private var showsResetConfirmation = false
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
#if DEBUG && !MIGRATION_EXPORT
            if resetDatabase != nil {
                Button("Reset Database", role: .destructive) {
                    showsResetConfirmation = true
                }
                .buttonStyle(.bordered)
            }
#endif
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
#if DEBUG && !MIGRATION_EXPORT
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

nonisolated struct StartupCloudRecoveryOperations: Sendable {
    let start: @Sendable () async throws -> Void
    let synchronize: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void

    init(syncEngine: SyncEngine) {
        start = {
            try await syncEngine.start()
        }
        synchronize = {
            try await syncEngine.syncChanges()
        }
        stop = {
            syncEngine.stop()
        }
    }

    init(
        start: @escaping @Sendable () async throws -> Void,
        synchronize: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.synchronize = synchronize
        self.stop = stop
    }
}

nonisolated struct StartupCloudRecoveryService: Sendable {
    let database: any DatabaseWriter
    let operations: StartupCloudRecoveryOperations

    func recoverIfNeeded() async throws -> Bool {
        let hasLocalBlog = try await database.read { db in
            try Blog.fetchCount(db) > 0
        }
        guard !hasLocalBlog else { return false }

        do {
            try await operations.start()
            try await operations.synchronize()
            await operations.stop()
            return true
        } catch {
            await operations.stop()
            throw error
        }
    }
}

private enum ActiveWorkspaceError: Error {
    case missingBlog
    case missingBlogger
}

private enum RuntimeConfigurationError: Error {
    case missingPersistence
}
