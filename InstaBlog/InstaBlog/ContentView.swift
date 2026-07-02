import SwiftUI

struct ContentView: View {
    let trip: TripDisplay?
    let journalService: JournalService?

    var body: some View {
        IPhoneShell(trip: trip, journalService: journalService)
            .task {
                guard let journalService, !Self.isRunningUITests else { return }
                await journalService.requestLocationPermissionIfNeeded()
            }
    }

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
    }
}

#Preview {
    ContentView(trip: DevelopmentSampleData.currentTrip, journalService: nil)
}
