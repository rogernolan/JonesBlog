import Foundation
import Testing
@testable import InstaBlog

struct TripClosingWorkflowTests {
    @Test
    func yesterdayOnlyPlanIsAvailableForAutomaticClosure() {
        let trip = TripDisplay(
            title: "Cornwall",
            startLocalDay: "2026-09-01",
            days: [day("2026-09-11")]
        )

        let request = TripClosingWorkflow.closureRequest(for: trip, todayLocalDay: "2026-09-12")

        #expect(request?.plan.automaticallySelectedDay == "2026-09-11")
        #expect(request?.plan.choices.isEmpty == true)
    }

    @Test
    func closureDoesNotOfferDatesBeforeTheTripStarted() {
        let trip = TripDisplay(
            title: "Weekend",
            startLocalDay: "2026-09-12",
            days: []
        )

        let request = TripClosingWorkflow.closureRequest(for: trip, todayLocalDay: "2026-09-12")

        #expect(request?.plan.choices.map(\.localDay) == ["2026-09-12"])
    }

    @Test
    func replacementCountsEntriesFromTheNewStartDayAndExplainsTheChange() {
        let oldTrip = TripDisplay(
            title: "Cornwall",
            startLocalDay: "2026-09-01",
            days: [
                day("2026-09-09", entryCount: 1),
                day("2026-09-10", entryCount: 2),
            ]
        )

        let request = TripClosingWorkflow.replacementRequest(
            oldTrip: oldTrip,
            title: "Devon",
            description: "",
            startLocalDay: "2026-09-10"
        )

        #expect(request?.affectedEntryCount == 2)
        #expect(request?.confirmationMessage.contains("close \u{201c}Cornwall\u{201d} on 9 September 2026") == true)
        #expect(request?.confirmationMessage.contains("2 entries will move into \u{201c}Devon\u{201d}") == true)
    }

    @Test
    func replacementWithNoAffectedEntriesUsesTheExplicitWarning() {
        let oldTrip = TripDisplay(
            title: "Cornwall",
            startLocalDay: "2026-09-01",
            days: [day("2026-09-09", entryCount: 1)]
        )

        let request = TripClosingWorkflow.replacementRequest(
            oldTrip: oldTrip,
            title: "Devon",
            description: "",
            startLocalDay: "2026-09-10"
        )

        #expect(request?.confirmationMessage.contains("No entries will move into \u{201c}Devon\u{201d}.") == true)
    }

    @Test
    func replacementRejectsAStartDateThatCannotLeaveAValidOldTrip() {
        let oldTrip = TripDisplay(title: "Cornwall", startLocalDay: "2026-09-10", days: [])

        let request = TripClosingWorkflow.replacementRequest(
            oldTrip: oldTrip,
            title: "Devon",
            description: "",
            startLocalDay: "2026-09-10"
        )

        #expect(request?.oldTrip.id == nil)
        #expect(TripClosingWorkflow.invalidReplacementMessage(for: oldTrip).contains("after Cornwall began") == true)
    }

    private func day(_ localDay: String, entryCount: Int = 0) -> DayPostDisplay {
        let date = ISO8601DateFormatter().date(from: "\(localDay)T12:00:00Z")!
        return DayPostDisplay(
            date: date,
            localDay: localDay,
            route: [],
            blogItems: (0..<entryCount).map { _ in
                BlogItemDisplay(
                    author: "Rog",
                    date: date,
                    timeZoneIdentifier: "UTC",
                    blogText: "Entry",
                    location: "",
                    weather: WeatherDisplay()
                )
            }
        )
    }
}
