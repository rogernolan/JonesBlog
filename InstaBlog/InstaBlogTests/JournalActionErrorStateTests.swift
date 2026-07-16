import Foundation
import Testing
@testable import InstaBlog

@MainActor
struct JournalActionErrorStateTests {
    @Test(arguments: JournalUserAction.allCases)
    func mutationFailurePresentsModalAndLogsUnderlyingError(action: JournalUserAction) {
        var logs: [String] = []
        let state = JournalActionErrorState(logFailure: { logs.append($0) })

        state.reportMutationFailure(TestFailure.expected, action: action)

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

        state.reportRefreshFailure(TestFailure.expected, after: .deleteEntry)

        #expect(state.modal == nil)
        #expect(state.toast?.message == "Entry deleted, but the journal could not be refreshed.")
        #expect(logs.count == 1)
        #expect(logs[0].contains("refresh after delete entry"))
    }

    @Test
    func dismissClearsPresentedNotice() {
        let state = JournalActionErrorState(logFailure: { _ in })
        state.reportMutationFailure(TestFailure.expected, action: .createTrip)

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
    func systemFailureCanBeLoggedAndPresentedAsModal() {
        var logs: [String] = []
        let state = JournalActionErrorState(logFailure: { logs.append($0) })
        let notice = JournalNotice(title: "Could Not Refresh Blog", message: "Please try again.")

        state.reportFailure(TestFailure.expected, context: "startup workspace refresh", as: .modal(notice))

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

        state.reportFailure(TestFailure.expected, context: "journal observation", as: .toast(notice))

        #expect(state.modal == nil)
        #expect(state.toast == notice)
        #expect(logs.first?.contains("journal observation") == true)
    }
}

private enum TestFailure: LocalizedError {
    case expected

    var errorDescription: String? { "expected failure" }
}
