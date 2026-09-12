import Testing
@testable import InstaBlog

struct TripClosurePlanTests {
    @Test
    func todayEntryOffersTodayAndYesterday() {
        let plan = TripClosurePlanner.endPlan(
            entryLocalDays: ["2026-09-12"],
            todayLocalDay: "2026-09-12"
        )

        #expect(plan.choices == [
            TripClosureChoice(localDay: "2026-09-12", title: "Today"),
            TripClosureChoice(localDay: "2026-09-11", title: "Yesterday"),
        ])
        #expect(plan.automaticallySelectedDay == nil)
        #expect(plan.warning == nil)
    }

    @Test
    func yesterdayEntryIsAutomaticallySelected() {
        let plan = TripClosurePlanner.endPlan(
            entryLocalDays: ["2026-09-11"],
            todayLocalDay: "2026-09-12"
        )

        #expect(plan.choices.isEmpty)
        #expect(plan.automaticallySelectedDay == "2026-09-11")
        #expect(plan.warning == nil)
    }

    @Test
    func olderLastEntryIsAnAdditionalChoice() {
        let plan = TripClosurePlanner.endPlan(
            entryLocalDays: ["2026-09-01", "2026-09-10", "2026-09-10"],
            todayLocalDay: "2026-09-12"
        )

        #expect(plan.choices.map(\.localDay) == ["2026-09-12", "2026-09-11", "2026-09-10"])
        #expect(plan.choices.last?.title == "Last entry: 10 September")
        #expect(plan.automaticallySelectedDay == nil)
    }

    @Test
    func emptyTripWarnsAndOmitsLastEntry() {
        let plan = TripClosurePlanner.endPlan(entryLocalDays: [], todayLocalDay: "2026-09-12")

        #expect(plan.choices.map(\.localDay) == ["2026-09-12", "2026-09-11"])
        #expect(plan.warning == "Closing this trip will leave it with no entries.")
    }

    @Test
    func invalidTodayKeepsOnlyTheUsableTodayChoice() {
        let plan = TripClosurePlanner.endPlan(entryLocalDays: [], todayLocalDay: "not-a-day")

        #expect(plan.choices == [TripClosureChoice(localDay: "not-a-day", title: "Today")])
        #expect(plan.automaticallySelectedDay == nil)
    }
}
