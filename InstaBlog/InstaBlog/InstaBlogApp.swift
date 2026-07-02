import GRDB
import SQLiteData
import StructuredQueriesCore
import SwiftUI

@main
struct InstaBlogApp: App {
    @UIApplicationDelegateAdaptor(InstaBlogAppDelegate.self) private var appDelegate

    private let journalService: JournalService
    private let initialTrip: TripDisplay?
    private let shareAcceptanceCoordinator: ShareAcceptanceCoordinator

    init() {
        do {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
            let database = try isUITesting
                ? AppDatabase.makeInMemory()
                : AppDatabase.makeLive()
            let bootstrap = BlogBootstrapService(database: database)
#if DEBUG
            let workspace = try bootstrap.bootstrap(seed: DevelopmentSampleData.firstRunSeed)
#else
            let workspace = try bootstrap.bootstrap()
#endif
            let journalService = JournalService(database: database)
            let persistence = try AppPersistence(database: database)
            let shareAcceptanceCoordinator = ShareAcceptanceCoordinator(
                sharingService: BlogSharingService(persistence: persistence)
            )
            self.journalService = journalService
            self.initialTrip = try journalService.loadCurrentTrip()
            self.shareAcceptanceCoordinator = shareAcceptanceCoordinator
            CloudKitSceneBridge.shareAcceptanceHandler = { metadata in
                Task {
                    let persistedBlogID = try? await database.read { db in
                        try AppWorkspace
                            .find(AppWorkspace.singletonID)
                            .select(\.activeBlogID)
                            .fetchOne(db)
                            ?? nil
                    }
                    await shareAcceptanceCoordinator.receive(
                        metadata,
                        activeBlogID: persistedBlogID ?? workspace.blog.id
                    )
                }
            }
        } catch {
            fatalError("Unable to prepare the InstaBlog database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(trip: initialTrip, journalService: journalService)
        }
    }
}
