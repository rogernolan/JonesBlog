import Foundation

nonisolated struct TripClosingRequest: Identifiable {
    let trip: TripDisplay
    let plan: TripClosurePlan

    var id: UUID { trip.id }
}

nonisolated struct TripEditorPresentation: Identifiable {
    let trip: TripDisplay
    let isCreating: Bool

    var id: UUID { trip.id }
}

nonisolated struct TripReplacementRequest: Identifiable {
    let oldTrip: TripDisplay
    let title: String
    let description: String
    let startLocalDay: String
    let affectedEntryCount: Int

    var id: UUID { oldTrip.id }

    var confirmationMessage: String {
        let oldEndLocalDay = TripClosingWorkflow.previousLocalDay(before: startLocalDay) ?? startLocalDay
        let oldEndDate = TripClosingWorkflow.formattedLocalDay(oldEndLocalDay)
        let newTripName = "\u{201c}\(title)\u{201d}"
        let oldTripName = "\u{201c}\(oldTrip.title)\u{201d}"
        let closure = "This will close \(oldTripName) on \(oldEndDate), the day before \(newTripName) starts."

        var message = closure
        if oldTrip.days.flatMap(\.blogItems).isEmpty {
            message += " Closing this trip will leave it with no entries."
        }
        guard affectedEntryCount > 0 else {
            return "\(message) No entries will move into \(newTripName)."
        }
        let noun = affectedEntryCount == 1 ? "entry" : "entries"
        return "\(message) \(affectedEntryCount) \(noun) will move into \(newTripName)."
    }
}

nonisolated enum TripClosingWorkflow {
    static func closureRequest(for trip: TripDisplay, todayLocalDay: String) -> TripClosingRequest? {
        let plan = TripClosurePlanner.endPlan(
            entryLocalDays: trip.days.map(\.localDay),
            todayLocalDay: todayLocalDay
        )
        let validChoices = plan.choices.filter { $0.localDay >= trip.startLocalDay }
        let filteredPlan = TripClosurePlan(
            choices: validChoices,
            warning: plan.warning,
            automaticallySelectedDay: plan.automaticallySelectedDay
        )
        return filteredPlan.choices.isEmpty && filteredPlan.automaticallySelectedDay == nil
            ? nil
            : TripClosingRequest(trip: trip, plan: filteredPlan)
    }

    static func replacementRequest(
        oldTrip: TripDisplay,
        title: String,
        description: String,
        startLocalDay: String
    ) -> TripReplacementRequest? {
        guard startLocalDay > oldTrip.startLocalDay,
              previousLocalDay(before: startLocalDay) != nil else {
            return nil
        }
        let affectedEntryCount = oldTrip.days
            .filter { $0.localDay >= startLocalDay }
            .reduce(into: 0) { count, day in
                count += day.blogItems.count
            }
        return TripReplacementRequest(
            oldTrip: oldTrip,
            title: title,
            description: description,
            startLocalDay: startLocalDay,
            affectedEntryCount: affectedEntryCount
        )
    }

    static func invalidEndMessage(for trip: TripDisplay) -> String {
        "\(trip.title) starts on \(formattedLocalDay(trip.startLocalDay)), so choose an end date on or after that day."
    }

    static func invalidReplacementMessage(for oldTrip: TripDisplay) -> String {
        "Start the new trip after \(oldTrip.title) began on \(formattedLocalDay(oldTrip.startLocalDay)) so it can close the day before."
    }

    static func previousLocalDay(before localDay: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let date = date(from: localDay, calendar: calendar),
              let previous = calendar.date(byAdding: .day, value: -1, to: date) else {
            return nil
        }
        return JournalDayProgress.localDay(from: previous, calendar: calendar)
    }

    static func formattedLocalDay(_ localDay: String) -> String {
        guard let date = date(from: localDay, calendar: .autoupdatingCurrent) else { return localDay }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    private static func date(from localDay: String, calendar: Calendar) -> Date? {
        let parts = localDay.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              JournalDayProgress.localDay(from: date, calendar: calendar) == localDay else {
            return nil
        }
        return date
    }
}
