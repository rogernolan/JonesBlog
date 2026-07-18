import GRDB
import SQLiteData
import StructuredQueriesCore
import SwiftUI

@main
struct InstaBlogApp: App {
    @UIApplicationDelegateAdaptor(InstaBlogAppDelegate.self) private var appDelegate

    private let database: any DatabaseWriter
    private let sharingService: any BlogSharingServiceProtocol
    private let initialWorkspace: ActiveWorkspace
    private let shareAcceptanceCoordinator: ShareAcceptanceCoordinator
    private let syncStatusOverride: BlogItemSyncStatus?
    private let photoAvailabilityOverride: BlogItemPhotoAvailability?
    private let mediaAssetSyncService: MediaAssetSyncService?

    init() {
        do {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
            let syncStatusOverride = ProcessInfo.processInfo.environment["UI_TEST_SYNC_STATUS"]
                .flatMap(BlogItemSyncStatus.init(rawValue:))
            let photoAvailabilityOverride = ProcessInfo.processInfo.environment["UI_TEST_PHOTO_AVAILABILITY"]
                .flatMap(BlogItemPhotoAvailability.init(rawValue:))
            let database = try isUITesting
                ? AppDatabase.makeInMemory()
                : AppDatabase.makeLive()
            let bootstrap = BlogBootstrapService(database: database)
#if DEBUG
            let isEmptyBlogUITest = ProcessInfo.processInfo.arguments.contains("-ui-testing-empty-blog")
            let seed: FirstRunSeed? = if isEmptyBlogUITest {
                nil
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-empty-current-trip") {
                DevelopmentSampleData.emptyCurrentTripUITestSeed
            } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-gallery") {
                DevelopmentSampleData.galleryUITestSeed
            } else {
                DevelopmentSampleData.firstRunSeed
            }
            let workspace = try bootstrap.bootstrap(
                seed: isUITesting ? seed : nil
            )
#else
            let workspace = try bootstrap.bootstrap()
#endif
            let sharingService: any BlogSharingServiceProtocol
            let mediaAssetSyncService: MediaAssetSyncService?
            if !SharingServiceAvailability.isEnabled(
                containerIdentifier: AppCloudKitConfiguration.containerIdentifier,
                isUITesting: isUITesting
            ) {
                sharingService = UnavailableBlogSharingService(database: database)
                mediaAssetSyncService = nil
            } else {
                let persistence = try AppPersistence(
                    database: database,
                    containerIdentifier: AppCloudKitConfiguration.containerIdentifier
                )
                prepareDependencies {
                    $0.defaultSyncEngine = persistence.syncEngine
                }
                sharingService = BlogSharingService(persistence: persistence)
                mediaAssetSyncService = MediaAssetSyncService(persistence: persistence)
            }
            let shareAcceptanceCoordinator = ShareAcceptanceCoordinator(
                sharingService: sharingService
            )
            let initialWorkspace = try Self.loadActiveWorkspace(
                from: database,
                fallback: workspace
            )
            self.database = database
            self.sharingService = sharingService
            self.initialWorkspace = initialWorkspace
            self.shareAcceptanceCoordinator = shareAcceptanceCoordinator
            self.syncStatusOverride = syncStatusOverride
            self.photoAvailabilityOverride = photoAvailabilityOverride
            self.mediaAssetSyncService = mediaAssetSyncService
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
        } catch {
            fatalError("Unable to prepare the InstaBlog database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                workspace: initialWorkspace,
                sharingService: sharingService,
                shareAcceptanceCoordinator: shareAcceptanceCoordinator,
                loadWorkspace: {
                    try Self.loadActiveWorkspace(from: database)
                },
                observeWorkspace: {
                    Self.observeActiveWorkspace(from: database)
                },
                observeJournalChanges: { blogID in
                    Self.observeJournalChanges(from: database, blogID: blogID)
                },
                makeJournalService: { workspace in
                    JournalService(
                        database: database,
                        blogID: workspace.blog.id,
                        bloggerID: workspace.blogger.id,
                        syncStatusOverride: syncStatusOverride,
                        photoAvailabilityOverride: photoAvailabilityOverride,
                        mediaAssetSyncService: mediaAssetSyncService
                    )
                }
            )
        }
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

private enum ActiveWorkspaceError: Error {
    case missingBlog
    case missingBlogger
}
