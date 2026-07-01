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
    private let journalService: JournalService?
    @State private var selectedTab: IPhoneTab = .journal
    @State private var isPresentingCapture = false
    @State private var journalPath: [JournalDestination] = []
    @State private var trip: TripDisplay

    init(trip: TripDisplay, journalService: JournalService? = nil) {
        self.journalService = journalService
        _trip = State(initialValue: trip)
    }

    var body: some View {
        ZStack {
            JournalView(
                trip: trip,
                path: $journalPath,
                onUpdate: update
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
            PhotoPostCaptureFlow(
                journalService: journalService,
                onSave: { trip = $0 }
            )
        }
    }

    private func update(_ item: BlogItemDisplay) {
        guard let journalService else { return }
        do {
            try journalService.updateBlogItem(
                id: item.id,
                caption: item.caption,
                date: item.date,
                location: item.location,
                temperatureCelsius: item.weather.temperatureCelsius,
                weatherCondition: item.weather.condition
            )
            if let reloadedTrip = try journalService.loadCurrentTrip() {
                trip = reloadedTrip
            }
        } catch {
            return
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

#Preview("iPhone shell") {
    IPhoneShell(trip: DevelopmentSampleData.currentTrip)
}
