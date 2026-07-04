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

private enum TripDeletionMode: Equatable {
    case tripOnly
    case tripAndEntries

    var confirmationMessage: String {
        switch self {
        case .tripOnly:
            "You are deleting this trip. This cannot be undone. Are you sure?"
        case .tripAndEntries:
            "You are deleting this trip and ALL its blog entries. This cannot be undone. Are you sure?"
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
    @State private var tripPendingDeletion: TripDisplay?
    @State private var tripDeletionMode: TripDeletionMode?
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
                .id(journalTrip.id)
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
                onSelect: selectTrip,
                onCreate: startNewTrip,
                onEdit: beginEditingTrip,
                onDelete: beginDeletingTrip
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
                mode: isCreatingTrip ? .create : .edit,
                trip: trip,
                existingTrips: trips,
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
        .confirmationDialog(
            "Do you want to delete just this trip, or the trip and all its blog entries?",
            isPresented: tripDeletionChoicePresented,
            titleVisibility: .visible
        ) {
            Button("Trip only") {
                tripDeletionMode = .tripOnly
            }
            Button("Trip and all entries", role: .destructive) {
                tripDeletionMode = .tripAndEntries
            }
            Button("Cancel", role: .cancel) {
                clearTripDeletionState()
            }
        }
        .alert(
            "Delete trip?",
            isPresented: tripDeletionConfirmationPresented,
            presenting: tripDeletionMode
        ) { mode in
            Button("Delete trip", role: .destructive) {
                confirmTripDeletion(mode)
            }
            Button("Cancel", role: .cancel) {
                clearTripDeletionState()
            }
        } message: { mode in
            Text(mode.confirmationMessage)
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
            title: "",
            description: "",
            startLocalDay: localDay(from: Date()),
            endLocalDay: nil,
            days: []
        )
    }

    private func beginEditingTrip(_ trip: TripDisplay) {
        guard !trip.isUnassigned else { return }
        isCreatingTrip = false
        editingTrip = trip
    }

    private func beginDeletingTrip(_ trip: TripDisplay) {
        guard !trip.isUnassigned else { return }
        tripPendingDeletion = trip
        tripDeletionMode = nil
    }

    private func confirmTripDeletion(_ mode: TripDeletionMode) {
        guard let trip = tripPendingDeletion else { return }
        guard let journalService else {
            trips.removeAll { $0.id == trip.id }
            clearTripDeletionState()
            return
        }

        do {
            try journalService.deleteTrip(id: trip.id, includingEntries: mode == .tripAndEntries)
            if browsedTripID == trip.id {
                browsedTripID = nil
                journalPath = []
            }
            clearTripDeletionState()
            onReloadTrips()
        } catch {
            clearTripDeletionState()
            return
        }
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

    private func clearTripDeletionState() {
        tripPendingDeletion = nil
        tripDeletionMode = nil
    }

    private var tripDeletionChoicePresented: Binding<Bool> {
        Binding(
            get: { tripPendingDeletion != nil && tripDeletionMode == nil },
            set: { isPresented in
                if !isPresented && tripDeletionMode == nil {
                    clearTripDeletionState()
                }
            }
        )
    }

    private var tripDeletionConfirmationPresented: Binding<Bool> {
        Binding(
            get: { tripPendingDeletion != nil && tripDeletionMode != nil },
            set: { isPresented in
                if !isPresented {
                    clearTripDeletionState()
                }
            }
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
    let onCreate: () -> Void
    let onEdit: (TripDisplay) -> Void
    let onDelete: (TripDisplay) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Spacer()

                    Text("Trips")
                        .font(.title2.weight(.semibold))

                    Spacer()

                    Button(action: onCreate) {
                        Image(systemName: "plus")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.green)
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Create trip")
                }
                .padding(.leading, 44)
                .padding(.trailing, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !trip.isUnassigned {
                            Button {
                                onEdit(trip)
                            } label: {
                                Label("Edit", systemImage: "square.and.pencil")
                            }

                            Button(role: .destructive) {
                                onDelete(trip)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
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
    enum Mode {
        case create
        case edit

        var navigationTitle: String {
            switch self {
            case .create: "New Trip"
            case .edit: "Edit Trip"
            }
        }

        var saveTitle: String {
            switch self {
            case .create: "Save"
            case .edit: "Save"
            }
        }
    }

    let mode: Mode
    let trip: TripDisplay
    let existingTrips: [TripDisplay]
    let onCancel: () -> Void
    let onSave: (String, String, String, String?) -> Void

    @State private var title: String
    @State private var description: String
    @State private var startDate: Date
    @State private var isOpenTrip: Bool
    @State private var endDate: Date

    init(
        mode: Mode,
        trip: TripDisplay,
        existingTrips: [TripDisplay],
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String, String, String?) -> Void
    ) {
        self.mode = mode
        self.trip = trip
        self.existingTrips = existingTrips
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: trip.title)
        _description = State(initialValue: trip.description)
        let resolvedStartDate = Self.date(from: trip.startLocalDay) ?? Date()
        _startDate = State(initialValue: resolvedStartDate)
        _isOpenTrip = State(initialValue: trip.endLocalDay == nil)
        _endDate = State(
            initialValue: trip.endLocalDay.flatMap(Self.date(from:)) ?? resolvedStartDate
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Title")
                                .font(.headline)
                            TextField("", text: $title)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .background(Color.white, in: .rect(cornerRadius: 16))
                                .overlay(alignment: .leading) {
                                    if title.isEmpty {
                                        Text("My lovely trip")
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 14)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .accessibilityLabel("Title")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description")
                                .font(.headline)
                            TextEditor(text: $description)
                                .frame(minHeight: 120)
                                .padding(10)
                                .background(Color.white, in: .rect(cornerRadius: 16))
                                .overlay(alignment: .topLeading) {
                                    if description.isEmpty {
                                        Text("All about my lovely trip")
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 18)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .accessibilityLabel("Description")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Start date")
                                .font(.headline)
                            DatePicker(
                                "Start date",
                                selection: $startDate,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(10)
                            .background(Color.white, in: .rect(cornerRadius: 16))
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("End date")
                                .font(.headline)
                            Toggle("Open", isOn: $isOpenTrip)
                                .onChange(of: isOpenTrip) { _, isOpen in
                                    if isOpen {
                                        endDate = startDate
                                    }
                                }

                            DatePicker(
                                "End date",
                                selection: $endDate,
                                in: startDate...,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(10)
                            .background(Color.white, in: .rect(cornerRadius: 16))
                            .opacity(isOpenTrip ? 0.45 : 1)
                            .disabled(isOpenTrip)
                            .onChange(of: endDate) { _, _ in
                                isOpenTrip = false
                            }
                        }
                    }
                    .padding(20)
                    .padding(.top, 8)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .onChange(of: startDate) { _, newStartDate in
                if endDate < newStartDate {
                    endDate = newStartDate
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
    }

    private var editorHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Cancel", action: onCancel)
                    .font(.headline)
                    .frame(minWidth: 84, minHeight: 44)
                    .buttonStyle(.glass)

                Spacer()

                Text(mode.navigationTitle)
                    .font(.title3.weight(.semibold))

                Spacer()

                Button("Save") {
                    save()
                }
                .font(.headline)
                .foregroundStyle(canSave ? .green : .secondary)
                .frame(minWidth: 84, minHeight: 44)
                .buttonStyle(.glass)
                .disabled(!canSave)
            }

            Text(validationStatus.statusText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(validationStatus == .valid ? .green : .red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && validationStatus == .valid
    }

    private func save() {
        onSave(
            trimmedTitle,
            description.trimmingCharacters(in: .whitespacesAndNewlines),
            Self.localDay(from: startDate),
            isOpenTrip ? nil : Self.localDay(from: endDate)
        )
    }

    private var hasChanges: Bool {
        let isCreatingEmpty = mode == .create
            && title.isEmpty
            && description.isEmpty
            && Self.localDay(from: startDate) == trip.startLocalDay
            && currentEndLocalDay == trip.endLocalDay
        if isCreatingEmpty {
            return false
        }
        return title != trip.title
            || description != trip.description
            || Self.localDay(from: startDate) != trip.startLocalDay
            || currentEndLocalDay != trip.endLocalDay
    }

    private var currentEndLocalDay: String? {
        isOpenTrip ? nil : Self.localDay(from: endDate)
    }

    private var validationStatus: TripValidationStatus {
        TripValidation.validate(
            candidate: TripValidationCandidate(
                id: mode == .edit ? trip.id : nil,
                startLocalDay: Self.localDay(from: startDate),
                endLocalDay: currentEndLocalDay
            ),
            against: existingTrips
                .filter { !$0.isUnassigned }
                .map {
                    TripValidationCandidate(
                        id: $0.id,
                        startLocalDay: $0.startLocalDay,
                        endLocalDay: $0.endLocalDay
                    )
                },
            todayLocalDay: Self.localDay(from: Date())
        )
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
