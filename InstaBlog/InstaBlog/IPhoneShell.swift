import SwiftUI

enum IPhoneTab: Hashable, CaseIterable {
    case journal
    case trips
    case search
    case settings

    var title: String {
        switch self {
        case .journal: "Journal"
        case .trips: "Trips"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .journal: "text.book.closed"
        case .trips: "suitcase"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }

    var tabBarSlot: Int {
        switch self {
        case .journal: 0
        case .trips: 1
        case .search: 3
        case .settings: 4
        }
    }
}

struct IPhoneShell: View {
    @State private var selectedTab: IPhoneTab = .journal
    @State private var isPresentingCapture = false
    @State private var journalPath: [JournalDestination] = []

    var body: some View {
        ZStack {
            JournalView(
                trip: DevelopmentSampleData.currentTrip,
                path: $journalPath
            )
            .destinationState(isActive: selectedTab == .journal)

            PlaceholderDestinationView(
                title: "Trips",
                systemImage: "suitcase",
                message: "Completed Trips and unassigned BlogItems will appear here."
            )
            .destinationState(isActive: selectedTab == .trips)

            PlaceholderDestinationView(
                title: "Search",
                systemImage: "magnifyingglass",
                message: "Search by text, place, date, author, or Trip."
            )
            .destinationState(isActive: selectedTab == .search)

            PlaceholderDestinationView(
                title: "Settings",
                systemImage: "gearshape",
                message: "Gallery rules, subscribers, sharing, deleted items, and identity."
            )
            .destinationState(isActive: selectedTab == .settings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedTab != .journal || journalPath.isEmpty {
                IPhoneTabBar(
                    selection: $selectedTab,
                    onCompose: { isPresentingCapture = true }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $isPresentingCapture) {
            CaptureWorkspace()
        }
    }
}

private extension View {
    func destinationState(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

private struct IPhoneTabBar: View {
    @Binding var selection: IPhoneTab
    let onCompose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            selectionHighlight

            HStack(spacing: 4) {
                tabButton(.journal)
                tabButton(.trips)
                composeButton
                tabButton(.search)
                tabButton(.settings)
            }
            .padding(5)
        }
        .frame(height: 62)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 25))
        .accessibilityElement(children: .contain)
    }

    private var selectionHighlight: some View {
        GeometryReader { geometry in
            let spacing = 4.0
            let inset = 5.0
            let slotWidth = (geometry.size.width - (inset * 2) - (spacing * 4)) / 5

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.primary.opacity(0.78))
                .frame(width: slotWidth, height: 52)
                .offset(
                    x: inset + ((slotWidth + spacing) * CGFloat(selection.tabBarSlot)),
                    y: inset
                )
                .animation(
                    reduceMotion ? nil : .spring(duration: 0.48, bounce: 0.24),
                    value: selection
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tabButton(_ tab: IPhoneTab) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage)
                    .font(.body.weight(.semibold))
                Text(tab.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selection == tab ? .white : .secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var composeButton: some View {
        Button(action: onCompose) {
            Image(systemName: "square.and.pencil")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(.green, in: .rect(cornerRadius: 18))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .zIndex(1)
        .accessibilityLabel("New BlogItem")
    }
}

private struct PlaceholderDestinationView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text(message)
            )
            .navigationTitle(title)
        }
    }
}

private struct CaptureWorkspace: View {
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Capture the moment now; details can be enriched later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $caption)
                    .font(.body)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                    .accessibilityLabel("Caption")
                    .accessibilityIdentifier("Caption")
            }
            .padding(18)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("New BlogItem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(!caption.isEmpty)
    }
}

#Preview("iPhone shell") {
    IPhoneShell()
}
