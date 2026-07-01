import SwiftUI

struct ContentView: View {
    let trip: TripDisplay?
    let journalService: JournalService?

    var body: some View {
        IPhoneShell(trip: trip, journalService: journalService)
    }
}

#Preview {
    ContentView(trip: DevelopmentSampleData.currentTrip, journalService: nil)
}
