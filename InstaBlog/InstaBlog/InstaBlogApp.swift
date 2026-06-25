import SwiftUI

@main
struct InstaBlogApp: App {
    private let journalService: JournalService
    private let initialTrip: TripDisplay

    init() {
        do {
            let database = try AppDatabase.makeLive()
            let bootstrap = BlogBootstrapService(database: database)
#if DEBUG
            let workspace = try bootstrap.bootstrap(seed: DevelopmentSampleData.firstRunSeed)
#else
            let workspace = try bootstrap.bootstrap()
#endif
            let journalService = JournalService(database: database)
            self.journalService = journalService
            self.initialTrip = try journalService.loadCurrentTrip()
                ?? TripDisplay(title: workspace.blog.title, days: [])
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
