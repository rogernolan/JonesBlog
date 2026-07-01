import SwiftUI

@main
struct InstaBlogApp: App {
    private let journalService: JournalService
    private let initialTrip: TripDisplay?

    init() {
        do {
            let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
            let database = try isUITesting
                ? AppDatabase.makeInMemory()
                : AppDatabase.makeLive()
            let bootstrap = BlogBootstrapService(database: database)
#if DEBUG
            _ = try bootstrap.bootstrap(seed: DevelopmentSampleData.firstRunSeed)
#else
            _ = try bootstrap.bootstrap()
#endif
            let journalService = JournalService(database: database)
            self.journalService = journalService
            self.initialTrip = try journalService.loadCurrentTrip()
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
