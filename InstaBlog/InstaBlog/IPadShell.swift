import CoreLocation
import SwiftUI
import UIKit

@MainActor
enum IPadWindowChrome {
    static var hasVisibleTrafficLights: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) else {
            return false
        }

        let sceneSize = scene.effectiveGeometry.coordinateSpace.bounds.size
        let screenSize = scene.screen.coordinateSpace.bounds.size
        let sizeDifference = abs(sceneSize.width - screenSize.width)
            + abs(sceneSize.height - screenSize.height)

        return sizeDifference > 1
    }
}

private enum IPadPrimarySelection: Hashable {
    case journal
    case trips
    case share
    case settings
}

struct IPadShell: View {
    @Binding private var trips: [TripDisplay]
    private let isLoadingTrips: Bool
    private let journalService: JournalService?
    private let blog: Blog?
    private let blogger: Blogger?
    private let sharingService: (any BlogSharingServiceProtocol)?
    private let onReloadTrips: () -> Void
    private let onRefresh: () async -> Void

    @State private var primarySelection: IPadPrimarySelection = .journal
    @State private var isShowingMenu = false
    @State private var selectedTripID: TripDisplay.ID?
    @State private var journalPath: [JournalDestination] = []
    @State private var isShowingJournalSubdetail = false
    @State private var isPresentingCapture = false
    @State private var captureStartMode: PhotoPostCaptureStartMode = .photoPicker
    @State private var editingTrip: TripDisplay?
    @State private var isCreatingTrip = false
    @State private var tripPendingDeletion: TripDisplay?
    @State private var tripDeletionMode: TripDeletionMode?
    @State private var actionErrors = JournalActionErrorState()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(
        trips: Binding<[TripDisplay]>,
        isLoadingTrips: Bool = false,
        journalService: JournalService? = nil,
        blog: Blog? = nil,
        blogger: Blogger? = nil,
        sharingService: (any BlogSharingServiceProtocol)? = nil,
        onReloadTrips: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {}
    ) {
        _trips = trips
        self.isLoadingTrips = isLoadingTrips
        self.journalService = journalService
        self.blog = blog
        self.blogger = blogger
        self.sharingService = sharingService
        self.onReloadTrips = onReloadTrips
        self.onRefresh = onRefresh
    }

    var body: some View {
        ipadLayout
        .fullScreenCover(isPresented: $isPresentingCapture) {
            PhotoPostCaptureFlow(
                journalService: journalService,
                startMode: captureStartMode,
                onSave: { savedTrip in
                    trips = replaceTrip(savedTrip, in: trips)
                    onReloadTrips()
                }
            )
            .onDisappear {
                captureStartMode = .photoPicker
            }
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
        .confirmationDialog(
            "Delete Trip?",
            isPresented: tripDeletionChoicePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Trip", role: .destructive) {
                tripDeletionMode = .tripOnly
            }

            Button("Cancel", role: .cancel) {
                clearTripDeletionState()
            }
        } message: {
            Text("The posts will remain available by date and may become unassigned.")
        }
        .alert(
            "Are you sure?",
            isPresented: tripDeletionConfirmationPresented,
            presenting: tripDeletionMode
        ) { mode in
            Button("Delete", role: .destructive) {
                confirmTripDeletion(mode)
            }
            Button("Cancel", role: .cancel) {
                clearTripDeletionState()
            }
        } message: { mode in
            Text(mode.confirmationMessage)
        }
        .journalActionErrors(actionErrors)
        .onChange(of: primarySelection) {
            journalPath = []
        }
        .onChange(of: trips.map(\.id)) {
            if let selectedTripID,
               !trips.contains(where: { $0.id == selectedTripID }) {
                if selectedTripID != TripDisplay.unassignedID {
                    self.selectedTripID = nil
                }
            }
        }
        .onChange(of: selectedJournalTrip) { _, refreshedTrip in
            guard let refreshedTrip else {
                journalPath = []
                return
            }
            journalPath = reconciledJournalPath(journalPath, with: refreshedTrip)
        }
        .onAppear {
            if verticalSizeClass == .compact {
                isShowingMenu = true
            }
        }
        .onChange(of: verticalSizeClass) { _, newSizeClass in
            if newSizeClass == .compact {
                withTransaction(Transaction(animation: nil)) {
                    isShowingMenu = true
                }
            }
        }
    }

    private var ipadLayout: some View {
        GeometryReader { proxy in
            let menuWidth = min(max(proxy.size.width * 0.30, 300), 390)
            let detailWidth = isShowingMenu ? max(0, proxy.size.width - menuWidth) : proxy.size.width

            ZStack(alignment: .leading) {
                NavigationStack {
                    primarySidebar
                }
                .frame(width: menuWidth)
                .frame(maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .ignoresSafeArea()

                ZStack(alignment: .leading) {
                    Color(uiColor: .systemGroupedBackground)
                        .ignoresSafeArea()

                    detail
                        .frame(width: detailWidth)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            if !isShowingJournalSubdetail {
                                IPadComposeButton(
                                    onCompose: {
                                        captureStartMode = .photoPicker
                                        isPresentingCapture = true
                                    },
                                    onComposeLongPress: {
                                        captureStartMode = .camera
                                        isPresentingCapture = true
                                    }
                                )
                                .frame(width: 220)
                                .padding(.bottom, 28)
                            }
                        }
                }
                .clipShape(.rect)
                .shadow(color: .black.opacity(isShowingMenu ? 0.18 : 0), radius: 18, x: -8, y: 0)
                .offset(x: isShowingMenu ? menuWidth : 0)
                .animation(.snappy, value: isShowingMenu)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var primarySidebar: some View {
        List {
            Section {
                IPadPrimarySidebarRow(
                    title: "Journal",
                    systemImage: "text.book.closed",
                    isSelected: primarySelection == .journal
                ) {
                    primarySelection = .journal
                    selectedTripID = nil
                    closeMenu()
                }
                .listRowBackground(primarySelection == .journal ? AppColors.controlOrange.opacity(0.32) : nil)

                IPadPrimarySidebarRow(
                    title: "Trips",
                    systemImage: "suitcase",
                    isSelected: primarySelection == .trips
                ) {
                    primarySelection = .trips
                    selectedTripID = nil
                    closeMenu()
                }
                .listRowBackground(primarySelection == .trips ? AppColors.controlOrange.opacity(0.32) : nil)

                IPadPrimarySidebarRow(
                    title: "Share",
                    systemImage: "square.and.arrow.up",
                    isSelected: primarySelection == .share
                ) {
                    primarySelection = .share
                    selectedTripID = nil
                    closeMenu()
                }
                .listRowBackground(primarySelection == .share ? AppColors.controlOrange.opacity(0.32) : nil)

            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IPadPrimarySidebarRow(
                title: "Settings",
                systemImage: "gearshape",
                isSelected: primarySelection == .settings
            ) {
                primarySelection = .settings
                selectedTripID = nil
                closeMenu()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var tripsList: some View {
        NavigationStack {
            VStack(spacing: 0) {
                IPadScreenHeader(
                    title: "Trips",
                    titleSize: 25.5,
                    trailingSystemImage: "plus",
                    trailingAccessibilityLabel: "Create trip",
                    onOpenSidebar: toggleMenu,
                    onTrailingAction: startNewTrip
                )

                List {
                    Section {
                        ForEach(orderedTrips) { trip in
                            Button {
                                if trip.isCurrent {
                                    primarySelection = .journal
                                    selectedTripID = nil
                                } else {
                                    selectedTripID = trip.id
                                }
                                journalPath = []
                            } label: {
                                IPadTripSidebarRow(trip: trip)
                            }
                            .buttonStyle(.plain)
                            .contentShape(.rect)
                            .listRowBackground(selectedTripID == trip.id ? AppColors.controlOrange.opacity(0.32) : nil)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !trip.isUnassigned {
                                    Button {
                                        beginEditingTrip(trip)
                                    } label: {
                                        Label("Edit", systemImage: "square.and.pencil")
                                    }

                                    Button(role: .destructive) {
                                        beginDeletingTrip(trip)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                if !trip.isUnassigned {
                                    Button("Edit Trip Details", systemImage: "square.and.pencil") {
                                        beginEditingTrip(trip)
                                    }
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    await onRefresh()
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch primarySelection {
        case .journal:
            if let currentTrip {
                journalView(for: currentTrip)
            } else if isLoadingTrips {
                IPadPlaceholderView(
                    title: "Loading Journal",
                    systemImage: "text.book.closed",
                    message: "Loading your latest trip entries.",
                    onOpenSidebar: toggleMenu
                )
            } else {
                IPadPlaceholderView(
                    title: "No Current Trip",
                    systemImage: "suitcase",
                    message: "Start a trip to add new journal entries.",
                    onOpenSidebar: toggleMenu,
                    actionTitle: "Start new trip",
                    onAction: startNewTrip
                )
            }
        case .trips:
            if let trip = selectedTrip {
                journalView(for: trip)
            } else {
                tripsList
            }
        case .share:
            NavigationStack {
                VStack(spacing: 0) {
                    IPadScreenHeader(
                        title: "Share",
                        titleSize: 25.5,
                        onOpenSidebar: toggleMenu
                    )

                    DayPostShareView(
                        trips: trips,
                        embedsNavigationStack: false
                    )
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
        case .settings:
            if let blog, let blogger {
                NavigationStack {
                    VStack(spacing: 0) {
                        IPadScreenHeader(
                            title: "Settings",
                            titleSize: 25.5,
                            onOpenSidebar: toggleMenu
                        )

                        SettingsView(
                            blog: blog,
                            blogger: blogger,
                            sharingService: sharingService,
                            journalService: journalService,
                            embedsNavigationStack: false
                        )
                        .padding(.top, 18)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            } else {
                IPadPlaceholderView(
                    title: "Settings",
                    systemImage: "gearshape",
                    message: "Settings are unavailable in this preview.",
                    onOpenSidebar: toggleMenu
                )
            }
        }
    }

    private var currentTrip: TripDisplay? {
        trips.first(where: \.isCurrent)
    }

    private var selectedTrip: TripDisplay? {
        if let selectedTripID,
           let trip = trips.first(where: { $0.id == selectedTripID }) {
            return trip
        }
        if selectedTripID == TripDisplay.unassignedID {
            return .emptyUnassigned
        }
        return nil
    }

    private var selectedJournalTrip: TripDisplay? {
        switch primarySelection {
        case .journal:
            currentTrip
        case .trips:
            selectedTrip
        case .share, .settings:
            nil
        }
    }

    private var currentTripTitle: String {
        currentTrip?.title ?? "Current Trip"
    }

    private var orderedTrips: [TripDisplay] {
        trips.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent {
                return lhs.isCurrent
            }
            if lhs.isUnassigned != rhs.isUnassigned {
                return !lhs.isUnassigned
            }
            if lhs.startLocalDay != rhs.startLocalDay {
                return lhs.startLocalDay > rhs.startLocalDay
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func journalView(for trip: TripDisplay) -> some View {
        JournalView(
            trip: trip,
            currentLocationProvider: {
                guard let journalService else { throw IPadShellLocationError.unavailable }
                let location = try await journalService.currentLocation()
                return CLLocationCoordinate2D(
                    latitude: location.latitude,
                    longitude: location.longitude
                )
            },
            reverseGeocodeProvider: { coordinate in
                guard let journalService else { throw IPadShellLocationError.unavailable }
                return try await journalService.placeName(
                    for: WeatherLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                )
            },
            historicalWeatherProvider: { location, date in
                guard let journalService else { throw IPadShellLocationError.unavailable }
                return try await journalService.weatherProvider.weather(for: location, near: date)
            },
            onRefresh: onRefresh,
            path: $journalPath,
            onUpdate: update,
            onCreateBlogItem: { source, request in createNewBlogItem(request, timeZoneIdentifier: source.timeZoneIdentifier) },
            onDelete: delete,
            onAddBlogItem: addBlogItem,
            onEditTrip: {
                isCreatingTrip = false
                editingTrip = trip
            },
            embedsNavigationStack: true,
            centersHeaderTitle: true,
            onOpenSidebar: toggleMenu,
            onTripSubdetailVisibilityChange: { isVisible in
                isShowingJournalSubdetail = isVisible
            },
            onEndTrip: { endTrip(trip) }
        )
    }

    private func replaceTrip(_ trip: TripDisplay, in trips: [TripDisplay]) -> [TripDisplay] {
        var updatedTrips = trips.filter { $0.id != trip.id }
        updatedTrips.append(trip)
        return updatedTrips.sorted {
            if $0.isCurrent != $1.isCurrent {
                return $0.isCurrent
            }
            if $0.isUnassigned != $1.isUnassigned {
                return !$0.isUnassigned
            }
            return $0.startLocalDay > $1.startLocalDay
        }
    }

    private func update(_ request: BlogItemUpdateRequest) {
        guard let journalService else { return }
        do {
            try journalService.updateBlogItem(request)
        } catch {
            actionErrors.reportMutationFailure(error, action: .updateEntry)
            return
        }
        journalPath.removeAll {
            let item: BlogItemDisplay
            switch $0 {
            case .blogItem(let value), .newBlogItem(let value, _):
                item = value
            }
            return item.id == request.id
        }
        do {
            trips = try journalService.loadTrips()
        } catch {
            actionErrors.reportRefreshFailure(error, after: .updateEntry)
        }
        onReloadTrips()
    }

    private func createNewBlogItem(_ request: BlogItemUpdateRequest, timeZoneIdentifier: String?) {
        guard let journalService else { return }
        do {
            let photos = request.photos.compactMap { update -> BlogItemPhotoAssetDraft? in
                guard case .added(let draft) = update else { return nil }
                return draft
            }
            _ = try journalService.createBlogItem(
                blogText: request.blogText,
                date: request.date,
                timeZoneIdentifier: timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier,
                photos: photos,
                latitude: request.latitude,
                longitude: request.longitude,
                locationName: request.location
            )
        } catch {
            actionErrors.reportMutationFailure(error, action: .createEntry)
            return
        }
        do {
            trips = try journalService.loadTrips()
        } catch {
            actionErrors.reportRefreshFailure(error, after: .createEntry)
        }
        onReloadTrips()
    }

    private func addBlogItem(after item: BlogItemDisplay) {
        guard let journalService else { return }
        do {
            let draft = try journalService.makeBlankBlogItemDraft(after: item)
            journalPath.append(.newBlogItem(draft, after: item))
        } catch {
            actionErrors.reportMutationFailure(error, action: .startEntry)
        }
    }

    private func delete(_ item: BlogItemDisplay) {
        guard let journalService else { return }
        do {
            try journalService.deleteBlogItem(id: item.id)
        } catch {
            actionErrors.reportMutationFailure(error, action: .deleteEntry)
            return
        }
        do {
            trips = try journalService.loadTrips()
        } catch {
            actionErrors.reportRefreshFailure(error, after: .deleteEntry)
        }
        onReloadTrips()
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
            actionErrors.reportMutationFailure(error, action: .updateTrip)
            return
        }
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
            try journalService.deleteTrip(id: trip.id)
            if selectedTripID == trip.id {
                selectedTripID = nil
                journalPath = []
            }
            clearTripDeletionState()
            onReloadTrips()
        } catch {
            clearTripDeletionState()
            actionErrors.reportMutationFailure(error, action: .deleteTrip)
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
            primarySelection = .journal
            isShowingMenu = false
            selectedTripID = nil
            onReloadTrips()
        } catch {
            actionErrors.reportMutationFailure(error, action: .createTrip)
            return
        }
    }

    private func endTrip(_ trip: TripDisplay) {
        guard let journalService else { return }
        do {
            try journalService.endTrip(id: trip.id)
            primarySelection = .journal
            isShowingMenu = false
            selectedTripID = nil
            journalPath = []
            onReloadTrips()
        } catch {
            actionErrors.reportMutationFailure(error, action: .endTrip)
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

    private func closeMenu() {
        guard verticalSizeClass != .compact else { return }
        withTransaction(Transaction(animation: nil)) {
            isShowingMenu = false
        }
    }

    private func toggleMenu() {
        withTransaction(Transaction(animation: nil)) {
            isShowingMenu.toggle()
        }
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

private enum IPadShellLocationError: Error {
    case unavailable
}

private struct IPadScreenHeader: View {
    let title: String
    let titleSize: Double
    var trailingSystemImage: String?
    var trailingAccessibilityLabel: String?
    let onOpenSidebar: () -> Void
    var onTrailingAction: (() -> Void)?
    @State private var menuLeadingPadding: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 12) {
                Button {
                    onOpenSidebar()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppColors.controlOrange)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .accessibilityLabel("Show menu")
                .padding(.leading, menuLeadingPadding)

                Text(title)
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity, alignment: .center)

                if let trailingSystemImage, let onTrailingAction {
                    Button {
                        onTrailingAction()
                    } label: {
                        Image(systemName: trailingSystemImage)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(AppColors.controlOrange)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel(trailingAccessibilityLabel ?? "Action")
                } else {
                    Color.clear
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .safeAreaPadding(.top, 8)
            .onChange(of: proxy.size) { _, _ in
                updateMenuLeadingPadding(animated: true, value: 42)
            }
        }
        .frame(height: 60)
        .onAppear {
            updateMenuLeadingPadding(animated: false, value: 42)
        }
    }

    private func updateMenuLeadingPadding(animated: Bool, value: CGFloat) {
        let newPadding = IPadWindowChrome.hasVisibleTrafficLights ? value : 0
        if animated {
            withAnimation(.easeInOut(duration: 0.5)) {
                menuLeadingPadding = newPadding
            }
        } else {
            menuLeadingPadding = newPadding
        }
    }
}

private struct IPadPrimarySidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.black : Color.primary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct IPadComposeButton: View {
    let onCompose: () -> Void
    let onComposeLongPress: () -> Void
    @State private var isPressActive = false
    @State private var didTriggerLongPress = false
    @State private var longPressWorkItem: DispatchWorkItem?

    var body: some View {
        Label("New Entry", systemImage: "square.and.pencil")
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(AppColors.controlOrange, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
            .highPriorityGesture(pressGesture)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onCompose()
            }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressActive else { return }
                isPressActive = true
                didTriggerLongPress = false
                scheduleLongPress()
            }
            .onEnded { _ in
                longPressWorkItem?.cancel()
                longPressWorkItem = nil

                defer {
                    isPressActive = false
                    didTriggerLongPress = false
                }

                guard !didTriggerLongPress else { return }
                onCompose()
            }
    }

    private func scheduleLongPress() {
        longPressWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            guard isPressActive, !didTriggerLongPress else { return }
            didTriggerLongPress = true
            onComposeLongPress()
        }
        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }
}

private struct IPadTripSidebarRow: View {
    let trip: TripDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(trip.isUnassigned ? AppColors.alertRed : .primary)
                .lineLimit(1)

            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.72))
                    .lineLimit(2)
            }

            if let dateSummary {
                Text(dateSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private var title: String {
        trip.isUnassigned ? "Unassigned entries" : trip.title
    }

    private var description: String? {
        if trip.isUnassigned {
            return "Entries outside any trip"
        }
        return trip.description.isEmpty ? nil : trip.description
    }

    private var dateSummary: String? {
        if trip.isUnassigned {
            return nil
        }

        guard let startDate = Self.tripRowDate(from: trip.startLocalDay) else {
            return nil
        }

        if trip.isCurrent || trip.endLocalDay == nil {
            return "Started on \(Self.formattedTripRowDate(startDate, includeYear: true))"
        }

        guard let endLocalDay = trip.endLocalDay,
              let endDate = Self.tripRowDate(from: endLocalDay) else {
            return "Started on \(Self.formattedTripRowDate(startDate, includeYear: true))"
        }

        let includeYear = !Calendar.autoupdatingCurrent.isDate(startDate, equalTo: endDate, toGranularity: .year)
        return "Started on \(Self.formattedTripRowDate(startDate, includeYear: includeYear)), ended on \(Self.formattedTripRowDate(endDate, includeYear: includeYear))"
    }

    private static func tripRowDate(from localDay: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: localDay)
    }

    private static func formattedTripRowDate(_ date: Date, includeYear: Bool) -> String {
        date.formatted(
            .dateTime
                .day()
                .month(.wide)
                .year(includeYear ? .defaultDigits : .omitted)
        )
    }
}

private struct IPadPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String
    let onOpenSidebar: () -> Void
    let actionTitle: String?
    let onAction: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        message: String,
        onOpenSidebar: @escaping () -> Void,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.onOpenSidebar = onOpenSidebar
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                IPadScreenHeader(
                    title: title,
                    titleSize: 25.5,
                    onOpenSidebar: onOpenSidebar
                )

                ContentUnavailableView {
                    Label(title, systemImage: systemImage)
                } description: {
                    Text(message)
                } actions: {
                    if let actionTitle, let onAction {
                        Button(actionTitle, systemImage: "plus", action: onAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct IPadSecondaryPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
        .navigationTitle(title)
    }
}
