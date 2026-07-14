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
        case .search: "Share"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .journal: "text.book.closed"
        case .trips: "suitcase"
        case .search: "square.and.arrow.up"
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

enum TripDeletionMode: Equatable {
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

private struct AutomaticGalleryNotice: Equatable {
    let itemID: BlogItem.ID
    let galleryID: Gallery.ID
}

struct IPhoneShell: View {
    private let journalService: JournalService?
    private let blog: Blog?
    private let blogger: Blogger?
    private let sharingService: (any BlogSharingServiceProtocol)?
    @State private var selectedTab: IPhoneTab = .journal
    @State private var isPresentingCapture = false
    @State private var captureStartMode: PhotoPostCaptureStartMode = .photoPicker
    @State private var captureDestinationGalleryID: Gallery.ID?
    @State private var galleryDayPendingCreation: DayPostDisplay?
    @State private var automaticGalleryNotice: AutomaticGalleryNotice?
    @State private var journalPath: [JournalDestination] = []
    @State private var isShowingTripSubdetail = false
    @State private var tripsNavigationResetToken = UUID()
    @Binding private var trips: [TripDisplay]
    private let isLoadingTrips: Bool
    @State private var browsedTripID: TripDisplay.ID?
    @State private var editingTrip: TripDisplay?
    @State private var isCreatingTrip = false
    @State private var tripPendingDeletion: TripDisplay?
    @State private var tripDeletionMode: TripDeletionMode?
    private let onReloadTrips: () -> Void
    private let onRefresh: () async -> Void

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
        self.journalService = journalService
        self.blog = blog
        self.blogger = blogger
        self.sharingService = sharingService
        _trips = trips
        self.isLoadingTrips = isLoadingTrips
        self.onReloadTrips = onReloadTrips
        self.onRefresh = onRefresh
    }

    var body: some View {
        ZStack {
            if let journalTrip {
                journalView(for: journalTrip, path: $journalPath, embedsNavigationStack: true)
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
                onSelectCurrentTrip: selectCurrentTrip,
                onCreate: startNewTrip,
                onEdit: beginEditingTrip,
                onDelete: beginDeletingTrip,
                onRefresh: onRefresh,
                destination: { trip in
                    TripEntriesContainer(trip: trip, trips: $trips) { refreshedTrip, path in
                        journalView(
                            for: refreshedTrip,
                            path: path,
                            embedsNavigationStack: false,
                            onTripSubdetailVisibilityChange: { isVisible in
                                isShowingTripSubdetail = isVisible
                            }
                        )
                    }
                }
            )
            .id(tripsNavigationResetToken)
            .destinationState(isActive: selectedTab == .trips)

            DayPostShareView(trips: trips)
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
            if shouldShowTabBar {
                IPhoneTabBar(
                    selection: tabSelection,
                    onCompose: {
                        captureStartMode = .photoPicker
                        isPresentingCapture = true
                    },
                    onComposeLongPress: {
                        captureStartMode = .camera
                        isPresentingCapture = true
                    }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .fullScreenCover(isPresented: $isPresentingCapture) {
            PhotoPostCaptureFlow(
                journalService: journalService,
                startMode: captureStartMode,
                destinationGalleryID: captureDestinationGalleryID,
                onAutomaticGalleryPlacement: { itemID, galleryID in
                    automaticGalleryNotice = AutomaticGalleryNotice(
                        itemID: itemID,
                        galleryID: galleryID
                    )
                },
                onSave: { savedTrip in
                    trips = replaceTrip(savedTrip, in: trips)
                    onReloadTrips()
                }
            )
            .onDisappear {
                captureDestinationGalleryID = nil
                captureStartMode = .photoPicker
            }
        }
        .sheet(item: $galleryDayPendingCreation) { day in
            GalleryCreationSheet(
                day: day,
                onCancel: { galleryDayPendingCreation = nil },
                onSave: { draft in
                    createGallery(draft, day: day)
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
        .overlay(alignment: .top) {
            if let notice = automaticGalleryNotice {
                HStack {
                    Text("Added to Gallery")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("View") { viewAutomaticGallery(notice) }
                    Button("Undo") { undoAutomaticGallery(notice) }
                }
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
                .shadow(radius: 8)
                .padding()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: automaticGalleryNotice)
        .task(id: automaticGalleryNotice) {
            guard let notice = automaticGalleryNotice else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, automaticGalleryNotice == notice else { return }
            withAnimation {
                automaticGalleryNotice = nil
            }
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
                } else if newTab == .trips {
                    isShowingTripSubdetail = false
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        tripsNavigationResetToken = UUID()
                    }
                } else {
                    isShowingTripSubdetail = false
                }
                selectedTab = newTab
            }
        )
    }

    private var shouldShowTabBar: Bool {
        if selectedTab == .journal {
            return journalPath.isEmpty
        }
        if selectedTab == .trips {
            return !isShowingTripSubdetail
        }
        return true
    }

    private func selectTrip(_ trip: TripDisplay) {
        browsedTripID = trip.id
        journalPath = []
        selectedTab = .journal
    }

    private func selectCurrentTrip() {
        browsedTripID = nil
        journalPath = []
        isShowingTripSubdetail = false
        selectedTab = .journal
    }

    @ViewBuilder
    private func journalView(
        for trip: TripDisplay,
        path: Binding<[JournalDestination]>,
        embedsNavigationStack: Bool,
        onTripSubdetailVisibilityChange: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        JournalView(
            trip: trip,
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
            onRefresh: onRefresh,
            path: path,
            onUpdate: update,
            onCreateBlogItem: { source, request in createNewBlogItem(request, timeZoneIdentifier: source.timeZoneIdentifier) },
            onDelete: delete,
            onAddBlogItem: { addBlogItem(after: $0, path: path) },
            onAddGallery: { galleryDayPendingCreation = $0 },
            onCreateEntryInGallery: { gallery in
                captureStartMode = .camera
                captureDestinationGalleryID = gallery.id
                isPresentingCapture = true
            },
            onMoveItemsToGallery: moveItemsToGallery,
            onMoveItemOutOfGallery: moveItemOutOfGallery,
            onUpdateGallery: updateGallery,
            onReorderGallery: reorderGallery,
            onDeleteGallery: deleteGallery,
            onEditTrip: {
                isCreatingTrip = false
                editingTrip = trip
            },
            embedsNavigationStack: embedsNavigationStack,
            centersHeaderTitle: true,
            onTripSubdetailVisibilityChange: onTripSubdetailVisibilityChange,
            onEndTrip: { endTrip(trip) }
        )
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
            journalPath.removeAll {
                let item: BlogItemDisplay
                switch $0 {
                case .blogItem(let value), .newBlogItem(let value, _):
                    item = value
                case .gallery:
                    return false
                }
                return item.id == request.id
            }
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func createNewBlogItem(_ request: BlogItemUpdateRequest, timeZoneIdentifier: String?) {
        guard let journalService else { return }
        do {
            let photo: BlogItemPhotoAssetDraft?
            if case .replaced(let replacement) = request.photoChange {
                photo = replacement
            } else {
                photo = nil
            }
            _ = try journalService.createBlogItem(
                caption: request.caption,
                date: request.date,
                timeZoneIdentifier: timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier,
                imageData: photo?.imageData,
                mimeType: photo?.mimeType,
                photoLibraryAssetIdentifier: photo?.photoLibraryAssetIdentifier,
                pixelWidth: photo?.pixelWidth,
                pixelHeight: photo?.pixelHeight,
                latitude: request.latitude,
                longitude: request.longitude,
                locationName: request.location
            )
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func addBlogItem(
        after item: BlogItemDisplay,
        path: Binding<[JournalDestination]>
    ) {
        guard let journalService else { return }
        let draft = journalService.makeBlankBlogItemDraft(after: item)
        path.wrappedValue.append(.newBlogItem(draft, after: item))
    }

    private func delete(_ item: BlogItemDisplay) {
        guard let journalService else { return }
        do {
            try journalService.deleteBlogItem(id: item.id)
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func createGallery(_ draft: GalleryCreationDraft, day: DayPostDisplay) {
        guard let journalService else { return }
        do {
            let galleryID = try journalService.createGallery(
                title: draft.title,
                description: draft.description,
                placementDate: draft.placementDate,
                timeZoneIdentifier: draft.timeZoneIdentifier,
                locationName: draft.location,
                temperatureCelsius: draft.temperatureCelsius,
                weatherConditionCode: draft.weatherConditionCode
            )
            trips = try journalService.loadTrips()
            galleryDayPendingCreation = nil
            if let gallery = trips
                .flatMap(\.days)
                .flatMap(\.entries)
                .compactMap({ entry -> GalleryDisplay? in
                    guard case .gallery(let gallery) = entry else { return nil }
                    return gallery
                })
                .first(where: { $0.id == galleryID }) {
                journalPath.append(.gallery(gallery))
            }
            onReloadTrips()
        } catch {
            return
        }
    }

    private func moveItemsToGallery(_ itemIDs: [BlogItem.ID], _ galleryID: Gallery.ID) {
        guard let journalService else { return }
        do {
            try journalService.moveBlogItems(itemIDs, toGallery: galleryID)
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func moveItemOutOfGallery(_ itemID: BlogItem.ID) {
        guard let journalService else { return }
        do {
            try journalService.moveBlogItemOutOfGallery(itemID)
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func updateGallery(_ gallery: GalleryDisplay) {
        guard let journalService else { return }
        do {
            try journalService.updateGallery(
                id: gallery.id,
                title: gallery.title,
                description: gallery.description,
                locationName: gallery.location,
                latitude: gallery.latitude,
                longitude: gallery.longitude,
                temperatureCelsius: gallery.weather.temperatureCelsius,
                weatherConditionCode: gallery.weather.conditionCode
            )
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func reorderGallery(_ galleryID: Gallery.ID, _ itemIDs: [BlogItem.ID]) {
        guard let journalService else { return }
        do {
            try journalService.reorderGallery(galleryID, itemIDs: itemIDs)
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func deleteGallery(_ galleryID: Gallery.ID, _ deletingEntries: Bool) {
        guard let journalService else { return }
        do {
            try journalService.deleteGallery(id: galleryID, deletingEntries: deletingEntries)
            journalPath.removeAll {
                guard case .gallery(let gallery) = $0 else { return false }
                return gallery.id == galleryID
            }
            trips = try journalService.loadTrips()
            onReloadTrips()
        } catch {
            return
        }
    }

    private func viewAutomaticGallery(_ notice: AutomaticGalleryNotice) {
        let gallery = trips
            .flatMap(\.days)
            .flatMap(\.entries)
            .compactMap { entry -> GalleryDisplay? in
                guard case .gallery(let gallery) = entry else { return nil }
                return gallery
            }
            .first { $0.id == notice.galleryID }
        if let gallery {
            journalPath.append(.gallery(gallery))
        }
        automaticGalleryNotice = nil
    }

    private func undoAutomaticGallery(_ notice: AutomaticGalleryNotice) {
        guard let journalService else { return }
        do {
            try journalService.moveBlogItemOutOfGallery(notice.itemID)
            trips = try journalService.loadTrips()
            automaticGalleryNotice = nil
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
    let onComposeLongPress: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isComposePressActive = false
    @State private var didTriggerComposeLongPress = false
    @State private var composeLongPressWorkItem: DispatchWorkItem?

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
            .padding(3)
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
                .fill(AppColors.controlOrange.opacity(0.32))
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
            .foregroundStyle(selection == tab ? .black : .secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var composeButton: some View {
        VStack(spacing: 2) {
            Image(systemName: "square.and.pencil")
                .font(.body.weight(.semibold))
            Text("New entry")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(AppColors.controlOrange, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
            .highPriorityGesture(composePressGesture)
        .zIndex(1)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onCompose()
        }
        .accessibilityLabel("New BlogItem")
    }

    private var composePressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isComposePressActive else { return }
                isComposePressActive = true
                didTriggerComposeLongPress = false
                scheduleComposeLongPress()
            }
            .onEnded { _ in
                composeLongPressWorkItem?.cancel()
                composeLongPressWorkItem = nil

                defer {
                    isComposePressActive = false
                    didTriggerComposeLongPress = false
                }

                guard !didTriggerComposeLongPress else { return }
                onCompose()
            }
    }

    private func scheduleComposeLongPress() {
        composeLongPressWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            guard isComposePressActive, !didTriggerComposeLongPress else { return }
            didTriggerComposeLongPress = true
            onComposeLongPress()
        }
        composeLongPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
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

private struct TripsListView<Destination: View>: View {
    let trips: [TripDisplay]
    let onSelectCurrentTrip: () -> Void
    let onCreate: () -> Void
    let onEdit: (TripDisplay) -> Void
    let onDelete: (TripDisplay) -> Void
    let onRefresh: () async -> Void
    let destination: (TripDisplay) -> Destination

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
                            .foregroundStyle(AppColors.controlOrange)
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Create trip")
                }
                .padding(.leading, 44)
                .padding(.trailing, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                List(orderedTrips) { trip in
                    Group {
                        if trip.isCurrent {
                            Button {
                                onSelectCurrentTrip()
                            } label: {
                                tripRow(for: trip)
                            }
                        } else {
                            NavigationLink {
                                destination(trip)
                            } label: {
                                tripRow(for: trip)
                            }
                        }
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
                .refreshable {
                    await onRefresh()
                }
                .navigationTitle("Trips")
                .toolbar(.hidden, for: .navigationBar)
                .listStyle(.plain)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
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

    private func tripRow(for trip: TripDisplay) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(trip.isUnassigned ? "Unassigned entries" : trip.title)
                    .font(.headline)
                    .foregroundStyle(trip.isUnassigned ? AppColors.alertRed : .primary)

                if let descriptionText = descriptionText(for: trip) {
                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.72))
                        .lineLimit(2)
                }

                if let dateSummary = dateSummaryText(for: trip) {
                    Text(dateSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(.rect)
    }

    private func descriptionText(for trip: TripDisplay) -> String? {
        if trip.isUnassigned {
            return "Entries outside any trip"
        }
        return trip.description.isEmpty ? nil : trip.description
    }

    private func dateSummaryText(for trip: TripDisplay) -> String? {
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

private struct TripEntriesContainer<Content: View>: View {
    let trip: TripDisplay
    @Binding var trips: [TripDisplay]
    @ViewBuilder let content: (TripDisplay, Binding<[JournalDestination]>) -> Content
    @State private var path: [JournalDestination] = []

    var body: some View {
        content(refreshedTrip, $path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
    }

    private var refreshedTrip: TripDisplay {
        trips.first(where: { $0.id == trip.id })
            ?? (trip.isUnassigned ? .emptyUnassigned : trip)
    }
}

struct TripDetailsEditor: View {
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
