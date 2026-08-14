import Foundation
import Testing
@testable import InstaBlog

struct TripDetailsEditorTests {
    @Test
    func editingAnOpenTripDefaultsEndDateToToday() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2026-08-01",
            endLocalDay: nil,
            days: []
        )
        let startDate = Date(timeIntervalSince1970: 0)
        let today = Date(timeIntervalSince1970: 1_786_089_600)

        let endDate = TripDetailsEditor.initialEndDate(
            for: trip,
            mode: .edit,
            startDate: startDate,
            today: today
        )

        #expect(Calendar.current.isDate(endDate, inSameDayAs: today))
    }

    @Test
    func creatingAnOpenTripKeepsEndDateAtStartDate() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2026-08-01",
            endLocalDay: nil,
            days: []
        )
        let startDate = Date(timeIntervalSince1970: 0)

        let endDate = TripDetailsEditor.initialEndDate(
            for: trip,
            mode: .create,
            startDate: startDate
        )

        #expect(endDate == startDate)
    }

    @Test
    func editingAnOpenTripWithFutureStartDateDefaultsEndDateToStartDate() {
        let trip = TripDisplay(
            title: "Scotland",
            startLocalDay: "2033-05-18",
            endLocalDay: nil,
            days: []
        )
        let startDate = Date(timeIntervalSince1970: 2_000_000_000)
        let today = Date(timeIntervalSince1970: 1_786_089_600)

        let endDate = TripDetailsEditor.initialEndDate(
            for: trip,
            mode: .edit,
            startDate: startDate,
            today: today
        )

        #expect(endDate == startDate)
    }
}
