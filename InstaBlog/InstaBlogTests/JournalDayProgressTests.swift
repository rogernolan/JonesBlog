import Foundation
import Testing
@testable import InstaBlog

@Suite("Journal day progress")
struct JournalDayProgressTests {
    @Test("Counts calendar days rather than journal entries")
    func countsCalendarDays() throws {
        let progress = try #require(
            JournalDayProgress(
                startLocalDay: "2026-07-01",
                dayLocalDay: "2026-07-03",
                endLocalDay: "2026-07-05"
            )
        )

        #expect(progress.dayNumber == 3)
        #expect(progress.totalDays == 5)
    }

    @Test("Includes the first day of the trip")
    func includesFirstDay() throws {
        let progress = try #require(
            JournalDayProgress(
                startLocalDay: "2026-07-04",
                dayLocalDay: "2026-07-04",
                endLocalDay: "2026-07-04"
            )
        )

        #expect(progress.dayNumber == 1)
        #expect(progress.totalDays == 1)
    }

    @Test("Rejects days outside the trip range")
    func rejectsInvalidRange() {
        #expect(
            JournalDayProgress(
                startLocalDay: "2026-07-04",
                dayLocalDay: "2026-07-03",
                endLocalDay: "2026-07-05"
            ) == nil
        )
    }
}
