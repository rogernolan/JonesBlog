import Foundation
import Observation
import SwiftUI

nonisolated struct JournalNotice: Equatable, Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message
    }
}

nonisolated enum JournalFailurePresentation: Sendable {
    case modal(JournalNotice)
    case toast(JournalNotice)
}

nonisolated enum JournalUserAction: CaseIterable, Sendable {
    case updateEntry
    case createEntry
    case startEntry
    case deleteEntry
    case updateTrip
    case endTrip
    case deleteTrip
    case createTrip

    var logName: String {
        switch self {
        case .updateEntry: "update entry"
        case .createEntry: "create entry"
        case .startEntry: "start entry"
        case .deleteEntry: "delete entry"
        case .updateTrip: "update trip"
        case .endTrip: "end trip"
        case .deleteTrip: "delete trip"
        case .createTrip: "create trip"
        }
    }

    var failureNotice: JournalNotice {
        switch self {
        case .updateEntry:
            JournalNotice(title: "Could Not Save Entry", message: "Your changes were not saved. Please try again.")
        case .createEntry:
            JournalNotice(title: "Could Not Create Entry", message: "The new entry was not saved. Please try again.")
        case .startEntry:
            JournalNotice(title: "Could Not Start Entry", message: "A new entry could not be prepared. Please try again.")
        case .deleteEntry:
            JournalNotice(title: "Could Not Delete Entry", message: "The entry was not deleted. Please try again.")
        case .updateTrip:
            JournalNotice(title: "Could Not Save Trip", message: "Your trip changes were not saved. Please try again.")
        case .endTrip:
            JournalNotice(title: "Could Not End Trip", message: "The trip was not ended. Please try again.")
        case .deleteTrip:
            JournalNotice(title: "Could Not Delete Trip", message: "The trip was not deleted. Please try again.")
        case .createTrip:
            JournalNotice(title: "Could Not Create Trip", message: "The new trip was not saved. Please try again.")
        }
    }

    var refreshFailureMessage: String {
        switch self {
        case .updateEntry: "Entry saved, but the journal could not be refreshed."
        case .createEntry: "Entry created, but the journal could not be refreshed."
        case .startEntry: "The entry was prepared, but the journal could not be refreshed."
        case .deleteEntry: "Entry deleted, but the journal could not be refreshed."
        case .updateTrip: "Trip saved, but the journal could not be refreshed."
        case .endTrip: "Trip ended, but the journal could not be refreshed."
        case .deleteTrip: "Trip deleted, but the journal could not be refreshed."
        case .createTrip: "Trip created, but the journal could not be refreshed."
        }
    }
}

@MainActor
@Observable
final class JournalActionErrorState {
    private(set) var modal: JournalNotice?
    private(set) var toast: JournalNotice?
    @ObservationIgnored private let logFailure: (String) -> Void

    init(logFailure: @escaping (String) -> Void = { _ in }) {
        self.logFailure = logFailure
    }

    func reportMutationFailure(_ error: any Error, action: JournalUserAction) {
        logFailure("Failed to \(action.logName): \(error.localizedDescription)")
        AppTelemetry.record(
            "Journal mutation failed",
            category: "journal.mutation",
            level: .error,
            error: error,
            data: ["action": action.logName]
        )
        modal = action.failureNotice
    }

    func reportRefreshFailure(_ error: any Error, after action: JournalUserAction) {
        logFailure("Failed to refresh after \(action.logName): \(error.localizedDescription)")
        AppTelemetry.record(
            "Journal refresh failed",
            category: "journal.refresh",
            level: .error,
            error: error,
            data: ["action": action.logName]
        )
        toast = JournalNotice(title: "Journal Not Refreshed", message: action.refreshFailureMessage)
    }

    func presentToast(_ notice: JournalNotice) {
        toast = notice
    }

    func reportFailure(
        _ error: any Error,
        context: String,
        as presentation: JournalFailurePresentation
    ) {
        logFailure("Failed during \(context): \(error.localizedDescription)")
        AppTelemetry.record(
            "Journal operation failed",
            category: "journal.operation",
            level: .error,
            error: error,
            data: ["context": context]
        )
        switch presentation {
        case .modal(let notice):
            modal = notice
        case .toast(let notice):
            toast = notice
        }
    }

    func dismissModal() {
        modal = nil
    }

    func dismissToast() {
        toast = nil
    }
}

private struct JournalActionErrorModifier: ViewModifier {
    let state: JournalActionErrorState

    func body(content: Content) -> some View {
        content
            .alert(
                state.modal?.title ?? "Journal Error",
                isPresented: Binding(
                    get: { state.modal != nil },
                    set: { isPresented in
                        if !isPresented { state.dismissModal() }
                    }
                )
            ) {
                Button("OK") { state.dismissModal() }
            } message: {
                Text(state.modal?.message ?? "")
            }
            .overlay(alignment: .top) {
                if let toast = state.toast {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(toast.title).font(.headline)
                        Text(toast.message).font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 14))
                    .shadow(radius: 6, y: 3)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast.id) {
                        do {
                            try await Task.sleep(for: .seconds(4))
                            state.dismissToast()
                        } catch {
                            // Cancellation means the toast was replaced or the view disappeared.
                        }
                    }
                }
            }
            .animation(.easeInOut, value: state.toast?.id)
    }
}

extension View {
    func journalActionErrors(_ state: JournalActionErrorState) -> some View {
        modifier(JournalActionErrorModifier(state: state))
    }
}
