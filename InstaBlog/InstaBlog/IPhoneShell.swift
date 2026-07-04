import SwiftUI
import CoreLocation

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
    private let blog: Blog?
    private let blogger: Blogger?
    private let sharingService: (any BlogSharingServiceProtocol)?
    @State private var selectedTab: IPhoneTab = .journal
    @State private var isPresentingCapture = false
    @State private var journalPath: [JournalDestination] = []
    @Binding private var trips: [TripDisplay]
    private let isLoadingTrips: Bool
    @State private var browsedTripID: TripDisplay.ID?
    @State private var editingTrip: TripDisplay?
    @State private var isCreatingTrip = false
    private let onReloadTrips: () -> Void

    init(
        trips: Binding<[TripDisplay]>,
        isLoadingTrips: Bool = false,
        journalService: JournalService? = nil,
        blog: Blog? = nil,
        blogger: Blogger? = nil,
        sharingService: (any BlogSharingServiceProtocol)? = nil,
        onReloadTrips: @escaping () -> Void = {}
    ) {
        self.journalService = journalService
        self.blog = blog
        self.blogger = blogger
        self.sharingService = sharingService
        _trips = trips
        self.isLoadingTrips = isLoadingTrips
        self.onReloadTrips = onReloadTrips
    }

    var body: some View {
        ZStack {
            if let journalTrip {
                JournalView(
                    trip: journalTrip,
                    weatherAttributionProvider: journalService?.weatherAttributionProvider,
                    currentLocationProvider: {
                        guard let journalService else { throw ShellLocationError.unavailable }
                        let location = try await journalService.currentLocation()
                        return CLLocationCoordinate2D(
                            latitude: location.latitude,
                            longitude: location.longitude
                        )
                    },
                    reverseGeocodeProvider: { coordinate in
                        guard let journalService else { throw ShellLocationError.unavailable }
                        return try await journalService.placeName(
                            for: WeatherLocation(
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude
                            )
                        )
                    },
                    historicalWeatherProvider: { location, date in
                        guard let journalService else { throw ShellLocationError.unavailable }
                        return try await journalService.weatherProvider.weather(for: location, near: date)
                    },
                    path: $journalPath,
                    onUpdate: update,
                    onDelete: delete,
                    onEditTrip: {
                        isCreatingTrip = false
                        editingTrip = journalTrip
                    },
                    onEndTrip: { endTrip(journalTrip) }
                )
                .destinationState(isActive: selectedTab == .journal)
            } else if isLoadingTrips {
                JournalLoadingView()
                    .destinationState(isActive: selectedTab == .journal)
            } else {
                NoCurrentTripView(
                    onStartTrip: startNewTrip
                )
                .destinationState(isActive: selectedTab == .journal)
            }

            TripsListView(
                trips: trips,
                onSelect: selectTrip
            )
            .destinationState(isActive: selectedTab == .trips)

            PlaceholderDestinationView(
                title: "Search",
                systemImage: "magnifyingglass",
                message: "Search by text, place, date, author, or Trip."
            )
            .destinationState(isActive: selectedTab == .search)

            Group {
                if let blog, let blogger {
                    SettingsView(
                        blog: blog,
                        blogger: blogger,
                        sharingService: sharingService,
                        journalService: journalService,
                        onGallerySettingsChanged: onReloadTrips
                    )
                } else {
                    PlaceholderDestinationView(
                        title: "Settings",
                        systemImage: "gearshape",
                        message: "Settings are unavailable in this preview."
                    )
                }
            }
            .destinationState(isActive: selectedTab == .settings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedTab != .journal || journalPath.isEmpty {
                IPhoneTabBar(
                    selection: tabSelection,
                    onCompose: { isPresentingCapture = true }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $isPresentingCapture) {
            PhotoPostCaptureFlow(
                journalService: journalService,
                onSave: { savedTrip in
                    trips = replaceTrip(savedTrip, in: trips)
                }
            )
        }
        .sheet(item: $editingTrip) { trip in
            TripDetailsEditor(
                trip: trip,
                onCancel: {
                    editingTrip = nil
                    isCreatingTrip = false
                },
                onSave: { title, description, startLocalDay, endLocalDay in
                    updateTripDetails(
                        trip,
                        title: title,
                        description: description,
                        startLocalDay: startLocalDay,
                        endLocalDay: endLocalDay
                    )
                }
            )
        }
        .onChange(of: trips.map(\.id)) {
            if let browsedTripID,
               !trips.contains(where: { $0.id == browsedTripID }) {
                self.browsedTripID = nil
            }
        }
        .onChange(of: journalTrip) { _, refreshedTrip in
            guard let refreshedTrip else {
                journalPath = []
                return
            }
            journalPath = reconciledJournalPath(journalPath, with: refreshedTrip)
        }
    }

    private var journalTrip: TripDisplay? {
        if let browsedTripID {
            return trips.first { $0.id == browsedTripID }
        }
        return trips.first(where: \.isCurrent)
    }

    private var tabSelection: Binding<IPhoneTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .journal {
                    browsedTripID = nil
                    journalPath = []
                }
                selectedTab = newTab
            }
        )
    }

    private func selectTrip(_ trip: TripDisplay) {
        browsedTripID = trip.id
        journalPath = []
        selectedTab = .journal
    }

    private func replaceTrip(_ trip: TripDisplay, in trips: [TripDisplay]) -> [TripDisplay] {
        var updatedTrips = trips.filter { $0.id != trip.id }
        updatedTrips.append(trip)
        return updatedTrips.sorted {
            if $0.isUnassigned != $1.isUnassigned {
                return $0.isUnassigned
            }
            if $0.isCurrent != $1.isCurrent {
                return $0.isCurrent
            }
            return $0.startLocalDay > $1.startLocalDay
        }
    }

    private func update(_ request: BlogItemUpdateRequest) {
        guard let journalService else { return }
        do {
            try journalService.updateBlogItem(request)
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func delete(_ item: BlogItemDisplay) {
        guard let journalService else { return }
        do {
            try journalService.deleteBlogItem(id: item.id)
            onReloadTrips()
        } catch {
            return
        }
    }

    private func updateTripDetails(
        _ trip: TripDisplay,
        title: String,
        description: String,
        startLocalDay: String,
        endLocalDay: String?
    ) {
        if isCreatingTrip {
            createTrip(
                title: title,
                description: description,
                startLocalDay: startLocalDay,
                endLocalDay: endLocalDay
            )
            return
        }
        guard let journalService else {
            if let index = trips.firstIndex(where: { $0.id == trip.id }) {
                trips[index].title = title
                trips[index].description = description
                trips[index].startLocalDay = startLocalDay
                trips[index].endLocalDay = endLocalDay
            }
            editingTrip = nil
            return
        }
        do {
            try journalService.updateTripDetails(
                id: trip.id,
                title: title,
                description: description,
                startLocalDay: startLocalDay,
                endLocalDay: endLocalDay
            )
            editingTrip = nil
            onReloadTrips()
        } catch {
            return
        }
    }

    private func endTrip(_ trip: TripDisplay) {
        guard let journalService else { return }
        do {
            try journalService.endTrip(id: trip.id)
            browsedTripID = nil
            journalPath = []
            onReloadTrips()
        } catch {
            return
        }
    }

    private func startNewTrip() {
        isCreatingTrip = true
        editingTrip = TripDisplay(
            title: "new trip",
            description: "",
            startLocalDay: localDay(from: Date()),
            endLocalDay: nil,
            days: []
        )
    }

    private func createTrip(
        title: String,
        description: String,
        startLocalDay: String,
        endLocalDay: String?
    ) {
        guard let journalService else {
            editingTrip = nil
            isCreatingTrip = false
            return
        }
        do {
            try journalService.createTrip(
                title: title,
                description: description,
                startLocalDay: startLocalDay,
                endLocalDay: endLocalDay
            )
            editingTrip = nil
            isCreatingTrip = false
            browsedTripID = nil
            onReloadTrips()
        } catch {
            return
        }
    }

    private func localDay(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private enum ShellLocationError: Error {
    case unavailable
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

private struct NoCurrentTripView: View {
    let onStartTrip: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No Current Trip", systemImage: "suitcase")
            } description: {
                Text("Start a trip to add new journal entries.")
            } actions: {
                Button("Start new trip", systemImage: "plus", action: onStartTrip)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Journal")
        }
    }
}

private struct JournalLoadingView: View {
    var body: some View {
        NavigationStack {
            ProgressView("Loading Journal…")
                .navigationTitle("Journal")
        }
    }
}

private struct TripsListView: View {
    let trips: [TripDisplay]
    let onSelect: (TripDisplay) -> Void

    var body: some View {
        NavigationStack {
            List(trips) { trip in
                Button {
                    onSelect(trip)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                if trip.isUnassigned {
                                    Text("Unassigned entries")
                                        .font(.headline)
                                        .foregroundStyle(.orange)
                                } else if trip.isCurrent {
                                    Text("Current trip:")
                                        .font(.headline)
                                        .foregroundStyle(.green)
                                }
                                if !trip.isUnassigned {
                                    Text(trip.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                }
                            }
                            if !trip.description.isEmpty {
                                Text(trip.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(summary(for: trip))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Trip")
            }
            .navigationTitle("Trips")
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private func summary(for trip: TripDisplay) -> String {
        if trip.isUnassigned {
            let itemCount = trip.days.reduce(0) { partialResult, day in
                partialResult + day.entries.reduce(0) { entryCount, entry in
                    switch entry {
                    case .blogItem:
                        entryCount + 1
                    case .gallery(let gallery):
                        entryCount + gallery.items.count
                    }
                }
            }
            return itemCount == 1 ? "1 entry" : "\(itemCount) entries"
        }
        let dayCount = trip.days.count
        let dayText = dayCount == 1 ? "1 day" : "\(dayCount) days"
        if trip.isCurrent {
            return "\(dayText) so far"
        }
        return dayText
    }
}

private struct TripDetailsEditor: View {
    let trip: TripDisplay
    let onCancel: () -> Void
    let onSave: (String, String, String, String?) -> Void

    @State private var title: String
    @State private var description: String
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date

    init(
        trip: TripDisplay,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String, String, String?) -> Void
    ) {
        self.trip = trip
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: trip.title)
        _description = State(initialValue: trip.description)
        _startDate = State(initialValue: Self.date(from: trip.startLocalDay) ?? Date())
        _hasEndDate = State(initialValue: trip.endLocalDay != nil)
        _endDate = State(
            initialValue: trip.endLocalDay.flatMap(Self.date(from:)) ?? Self.date(from: trip.startLocalDay) ?? Date()
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title")
                            .font(.subheadline.weight(.semibold))
                        TextField("Title", text: $title)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Title")
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $description)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel("Description")
                    }
                    .padding(.vertical, 4)
                }

                Section("Dates") {
                    DatePicker(
                        "Start",
                        selection: $startDate,
                        displayedComponents: .date
                    )

                    Toggle("End date", isOn: $hasEndDate)

                    if hasEndDate {
                        DatePicker(
                            "End",
                            selection: $endDate,
                            in: startDate...,
                            displayedComponents: .date
                        )
                    }
                }
            }
            .onChange(of: startDate) {
                if endDate < startDate {
                    endDate = startDate
                }
            }
            .navigationTitle("Edit Trip Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(
                            title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description.trimmingCharacters(in: .whitespacesAndNewlines),
                            Self.localDay(from: startDate),
                            hasEndDate ? Self.localDay(from: endDate) : nil
                        )
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
    }

    private var hasChanges: Bool {
        title != trip.title
            || description != trip.description
            || Self.localDay(from: startDate) != trip.startLocalDay
            || currentEndLocalDay != trip.endLocalDay
    }

    private var currentEndLocalDay: String? {
        hasEndDate ? Self.localDay(from: endDate) : nil
    }

    private nonisolated static func date(from localDay: String) -> Date? {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date
    }

    private nonisolated static func localDay(from date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
#Preview("iPhone shell") {
    IPhoneShell(trips: .constant([DevelopmentSampleData.currentTrip]))
}
