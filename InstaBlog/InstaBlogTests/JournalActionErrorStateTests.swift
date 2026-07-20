import Foundation
import Testing
@testable import InstaBlog

@MainActor
struct JournalActionErrorStateTests {
    @Test(arguments: [
        "no such column: blogItems.lastEditorID",
        "no such table: blogItems",
        "database schema migration required",
    ])
    func missingMigrationErrorsAreRecognized(description: String) {
        #expect(JournalDatabaseFailure.isMissingMigration(TestFailure(description: description)))
    }

    @Test
    func unrelatedDatabaseErrorsAreNotRecognizedAsMissingMigration() {
        #expect(!JournalDatabaseFailure.isMissingMigration(TestFailure(description: "database is locked")))
    }

    @Test(arguments: JournalUserAction.allCases)
    func mutationFailurePresentsModalAndLogsUnderlyingError(action: JournalUserAction) {
        var logs: [String] = []
        let state = JournalActionErrorState(logFailure: { logs.append($0) })

        state.reportMutationFailure(TestFailure(), action: action)

        #expect(state.modal == action.failureNotice)
        #expect(state.toast == nil)
        #expect(logs.count == 1)
        #expect(logs[0].contains(action.logName))
        #expect(logs[0].contains("expected failure"))
    }

    @Test
    func refreshFailurePresentsToastWithoutClaimingMutationFailed() {
        var logs: [String] = []
        let state = JournalActionErrorState(logFailure: { logs.append($0) })

        state.reportRefreshFailure(TestFailure(), after: .deleteEntry)

        #expect(state.modal == nil)
        #expect(state.toast?.message == "Entry deleted, but the journal could not be refreshed.")
        #expect(logs.count == 1)
        #expect(logs[0].contains("refresh after delete entry"))
    }

    @Test
    func dismissClearsPresentedNotice() {
        let state = JournalActionErrorState(logFailure: { _ in })
        state.reportMutationFailure(TestFailure(), action: .createTrip)

        state.dismissModal()

        #expect(state.modal == nil)
    }

    @Test
    func alreadyLoggedFailureCanPresentToastWithoutLoggingAgain() {
        var logs: [String] = []
        let state = JournalActionErrorState(logFailure: { logs.append($0) })
        let notice = JournalNotice(title: "Journal Not Refreshed", message: "Please try again.")

        state.presentToast(notice)

        #expect(state.toast == notice)
        #expect(logs.isEmpty)
    }

    @Test
    func unavailableWeatherNoticeExplainsThatOnlyAutomaticWeatherWasNotUpdated() {
        let state = JournalActionErrorState()

        state.presentToast(.weatherUpdateUnavailable)

        #expect(state.modal == nil)
        #expect(state.toast?.title == "Weather Not Updated")
        #expect(
            state.toast?.message
                == "Weather conditions could not be updated automatically for the new location"
        )
    }

    @Test
    func systemFailureCanBeLoggedAndPresentedAsModal() {
        var logs: [String] = []
        let state = JournalActionErrorState(logFailure: { logs.append($0) })
        let notice = JournalNotice(title: "Could Not Refresh Blog", message: "Please try again.")

        state.reportFailure(TestFailure(), context: "startup workspace refresh", as: .modal(notice))

        #expect(state.modal == notice)
        #expect(state.toast == nil)
        #expect(logs.first?.contains("startup workspace refresh") == true)
        #expect(logs.first?.contains("expected failure") == true)
    }

    @Test
    func systemFailureCanBeLoggedAndPresentedAsToast() {
        var logs: [String] = []
        let state = JournalActionErrorState(logFailure: { logs.append($0) })
        let notice = JournalNotice(title: "Updates Paused", message: "Retrying automatically.")

        state.reportFailure(TestFailure(), context: "journal observation", as: .toast(notice))

        #expect(state.modal == nil)
        #expect(state.toast == notice)
        #expect(logs.first?.contains("journal observation") == true)
    }

    @Test
    func blogUpdateRetriesNotifyOnceAndBackOffIndependently() {
        var state = BlogUpdateRetryState(initialDelaySeconds: 5, maximumDelaySeconds: 20)

        let firstJournalFailure = state.registerFailure(for: .journal)
        let secondJournalFailure = state.registerFailure(for: .journal)
        let firstWorkspaceFailure = state.registerFailure(for: .workspace)

        #expect(firstJournalFailure.shouldShowPausedNotice)
        #expect(firstJournalFailure.delay == .seconds(5))
        #expect(!secondJournalFailure.shouldShowPausedNotice)
        #expect(secondJournalFailure.delay == .seconds(10))
        #expect(!firstWorkspaceFailure.shouldShowPausedNotice)
        #expect(firstWorkspaceFailure.delay == .seconds(5))
    }

    @Test
    func blogUpdateRetryNoticeRearmsOnlyAfterAllObservationsRecover() {
        var state = BlogUpdateRetryState()
        _ = state.registerFailure(for: .journal)
        _ = state.registerFailure(for: .workspace)

        state.registerRecovery(for: .journal)
        let workspaceStillFailing = state.registerFailure(for: .workspace)
        #expect(!workspaceStillFailing.shouldShowPausedNotice)

        state.registerRecovery(for: .workspace)
        let laterFailure = state.registerFailure(for: .journal)
        #expect(laterFailure.shouldShowPausedNotice)
        #expect(laterFailure.delay == .seconds(5))
    }
}

private struct TestFailure: LocalizedError {
    let description: String

    init(description: String = "expected failure") {
        self.description = description
    }

    var errorDescription: String? { description }
}
