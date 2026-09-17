import SwiftUI
import CoreLocation

enum IPhoneTab: Hashable, CaseIterable {
    case journal
    case trips
    case compose
    case share
    case settings

    var title: String {
        switch self {
        case .journal: "Journal"
        case .trips: "Trips"
        case .compose: "New entry"
        case .share: "Share"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .journal: "text.book.closed"
        case .trips: "suitcase"
        case .compose: "square.and.pencil"
        case .share: "square.and.arrow.up"
        case .settings: "gearshape"
        }
    }

}

enum TripDeletionMode: Equatable {
    case tripOnly

    var confirmationMessage: String {
        "You are deleting this trip. Its posts will remain available by date. This cannot be undone. Are you sure?"
    }
}

struct IPhoneShell: View {
    private let journalService: JournalService?
    private let recipientStore: EmailRecipientStore?
    private let blog: Blog?
    private let blogger: Blogger?
    private let sharingService: (any BlogSharingServiceProtocol)?
    private let draftStore: JournalEditorDraftStore?
    @State private var selectedTab: IPhoneTab = .journal
    @State private var isEditingSettings = false
    @State private var capturePresentation: PhotoPostCaptureStartMode?
    @State private var journalPath: [JournalDestination] = []
    @State private var isShowingTripSubdetail = false
    @State private var tripsNavigationResetToken = UUID()
    @Binding private var trips: [TripDisplay]
    private let hasResolvedCurrentTrip: Bool
    private let isLoadingAllTrips: Bool
    private let isLoadingUnassigned: Bool
    private let isLoadingShareTrips: Bool
    @State private var browsedTripID: TripDisplay.ID?
    @State private var tripEditorPresentation: TripEditorPresentation?
    @State private var tripPendingDeletion: TripDisplay?
    @State private var tripDeletionMode: TripDeletionMode?
    @State private var tripClosingRequest: TripClosingRequest?
    @State private var tripReplacementRequest: TripReplacementRequest?
    @State private var tripClosingValidationMessage: String?
    @State private var actionErrors = JournalActionErrorState()
    @State private var journalSortOrders: [TripDisplay.ID: JournalSortOrder] = [:]
    @State private var journalScrollTrigger = UUID()
    @State private var hasAttemptedDraftRestoration = false
    @State private var hasAttemptedComposeAutoPresentation = false
    @State private var hasAttemptedUITestDeepLinkApplication = false
    private let onReloadTrips: () -> Void
    private let onReloadUnassigned: () -> Void
    private let onLoadAllTrips: () -> Void
    private let onRefresh: () async -> Void
    private let eraseAndImportArchive: (URL) -> Void

    init(
        trips: Binding<[TripDisplay]>,
        hasResolvedCurrentTrip: Bool = true,
        isLoadingAllTrips: Bool = false,
        isLoadingUnassigned: Bool = false,
        isLoadingShareTrips: Bool = false,
        journalService: JournalService? = nil,
        recipientStore: EmailRecipientStore? = nil,
        blog: Blog? = nil,
        blogger: Blogger? = nil,
        sharingService: (any BlogSharingServiceProtocol)? = nil,
        draftStore: JournalEditorDraftStore? = nil,
        eraseAndImportArchive: @escaping (URL) -> Void = { _ in },
        onReloadTrips: @escaping () -> Void = {},
        onReloadUnassigned: @escaping () -> Void = {},
        onLoadAllTrips: @escaping () -> Void = {},
        onRefresh: @escaping () async -> Void = {}
    ) {
        self.journalService = journalService
        self.recipientStore = recipientStore
        self.blog = blog
        self.blogger = blogger
        self.sharingService = sharingService
        self.draftStore = draftStore
        self.eraseAndImportArchive = eraseAndImportArchive
        _trips = trips
        self.hasResolvedCurrentTrip = hasResolvedCurrentTrip
        self.isLoadingAllTrips = isLoadingAllTrips
        self.isLoadingUnassigned = isLoadingUnassigned
        self.isLoadingShareTrips = isLoadingShareTrips
        self.onReloadTrips = onReloadTrips
        self.onReloadUnassigned = onReloadUnassigned
        self.onLoadAllTrips = onLoadAllTrips
        self.onRefresh = onRefresh
    }

    var body: some View {
        TabView(selection: tabSelection) {
            journalView(
                for: .allEntries(from: trips),
                path: $journalPath,
                embedsNavigationStack: true,
                presentationMode: .allEntries
            )
            .tabItem { Label(IPhoneTab.journal.title, systemImage: IPhoneTab.journal.systemImage) }
            .tag(IPhoneTab.journal)

            TripsListView(
                trips: trips,
                isLoading: isLoadingAllTrips,
                onSelectCurrentTrip: {},
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
                            showsNavigationBackButton: true,
                            onTripSubdetailVisibilityChange: { isVisible in
                                isShowingTripSubdetail = isVisible
                            }
                        )
                    }
                }
            )
            .id(tripsNavigationResetToken)
            .tabItem { Label(IPhoneTab.trips.title, systemImage: IPhoneTab.trips.systemImage) }
            .tag(IPhoneTab.trips)

            Color.clear
                .tabItem { Label(IPhoneTab.compose.title, systemImage: IPhoneTab.compose.systemImage) }
                .tag(IPhoneTab.compose)

            DayPostShareView(
                trips: trips,
                recipientStore: recipientStore,
                isLoadingTrips: isLoadingShareTrips
            )
                .tabItem { Label(IPhoneTab.share.title, systemImage: IPhoneTab.share.systemImage) }
                .tag(IPhoneTab.share)

            Group {
                if let blog, let blogger {
                    SettingsView(
                        blog: blog,
                        blogger: blogger,
                        sharingService: sharingService,
                        journalService: journalService,
                        eraseAndImportArchive: eraseAndImportArchive,
                        isActive: selectedTab == .settings,
                        onEditingDisplayNameChange: { isEditingSettings = $0 }
                    )
                } else {
                    PlaceholderDestinationView(
                        title: "Settings",
                        systemImage: "gearshape",
                        message: "Settings are unavailable in this preview."
                    )
                }
            }
            .tabItem { Label(IPhoneTab.settings.title, systemImage: IPhoneTab.settings.systemImage) }
            .tag(IPhoneTab.settings)
        }
        .tint(AppColors.controlTint)
        .toolbar(shouldShowTabBar ? .visible : .hidden, for: .tabBar)
        .overlay(alignment: .bottom) {
            if shouldShowTabBar && !(selectedTab == .settings && isEditingSettings) {
                composeButton
                    .padding(.bottom, 4)
                    .offset(y: 16)
                    .zIndex(1)
            }
        }
        .fullScreenCover(item: $capturePresentation) { startMode in
            captureFlow(for: startMode)
        }
        .sheet(item: $tripEditorPresentation) { presentation in
            let trip = presentation.trip
            TripDetailsEditor(
                mode: presentation.isCreating ? .create : .edit,
                trip: trip,
                existingTrips: trips,
                replacementTrip: presentation.isCreating ? currentOpenTrip : nil,
                onCancel: {
                    tripEditorPresentation = nil
                },
                onSave: { title, description, startLocalDay, endLocalDay in
                    updateTripDetails(
                        trip,
                        title: title,
                        description: description,
                        startLocalDay: startLocalDay,
                        endLocalDay: endLocalDay,
                        createsTrip: presentation.isCreating
                    )
                }
            )
            .alert(
                "Start new trip?",
                isPresented: tripReplacementRequestPresented,
                presenting: tripReplacementRequest
            ) { request in
                Button("Start Trip") {
                    tripReplacementRequest = nil
                    replaceOpenTrip(with: request)
                }
                Button("Cancel", role: .cancel) {
                    tripReplacementRequest = nil
                }
            } message: { request in
                Text(request.confirmationMessage)
            }
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
        .onAppear {
            onLoadAllTrips()
            restorePendingDraftIfNeeded()
            autoPresentComposeIfRequested()
            applyUITestDeepLinksIfRequested()
        }
        .onChange(of: trips) {
            restorePendingDraftIfNeeded()
            autoPresentComposeIfRequested()
            applyUITestDeepLinksIfRequested()
        }
        .confirmationDialog(
            "Delete this trip? Its posts will remain available by date.",
            isPresented: tripDeletionChoicePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Trip", role: .destructive) {
                tripDeletionMode = .tripOnly
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
        .confirmationDialog(
            tripClosingDialogTitle,
            isPresented: tripClosingRequestPresented,
            titleVisibility: .visible
        ) {
            if let request = tripClosingRequest {
                ForEach(request.plan.choices, id: \.localDay) { choice in
                    Button(choice.title) {
                        tripClosingRequest = nil
                        finishEndingTrip(request.trip, on: choice.localDay)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                tripClosingRequest = nil
            }
        } message: {
            if let warning = tripClosingRequest?.plan.warning {
                Text(warning)
            }
        }
        .alert(
            "Cannot End Trip",
            isPresented: tripClosingValidationPresented
        ) {
            Button("OK") {
                tripClosingValidationMessage = nil
            }
        } message: {
            Text(tripClosingValidationMessage ?? "")
        }
        .journalActionErrors(actionErrors)
    }

    private var journalTrip: TripDisplay? {
        if let browsedTripID {
            return trips.first { $0.id == browsedTripID }
        }
        return trips.first(where: \.isCurrent)
    }

    private var currentOpenTrip: TripDisplay? {
        trips.first { !$0.isUnassigned && $0.isCurrent }
    }

    private var tripClosingRequestPresented: Binding<Bool> {
        Binding(
            get: { tripClosingRequest != nil },
            set: { if !$0 { tripClosingRequest = nil } }
        )
    }

    private var tripClosingDialogTitle: String {
        let title = tripClosingRequest?.trip.title ?? "this trip"
        return "When should \(title) end?"
    }

    private var tripReplacementRequestPresented: Binding<Bool> {
        Binding(
            get: { tripReplacementRequest != nil },
            set: { if !$0 { tripReplacementRequest = nil } }
        )
    }

    private var tripClosingValidationPresented: Binding<Bool> {
        Binding(
            get: { tripClosingValidationMessage != nil },
            set: { if !$0 { tripClosingValidationMessage = nil } }
        )
    }

    private var tabSelection: Binding<IPhoneTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                if newTab == .compose {
                    return
                }
                if newTab == .journal {
                    if selectedTab == .journal {
                        journalScrollTrigger = UUID()
                    }
                    journalPath = []
                } else if newTab == .trips {
                    onLoadAllTrips()
                    isShowingTripSubdetail = false
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        tripsNavigationResetToken = UUID()
                    }
                } else {
                    if newTab == .share {
                        onLoadAllTrips()
                    }
                    isShowingTripSubdetail = false
                }
                selectedTab = newTab
            }
        )
    }

    private func sortBinding(for trip: TripDisplay) -> Binding<JournalSortOrder> {
        Binding(
            get: { journalSortOrders[trip.id] ?? (trip.isCurrent ? .newestFirst : .oldestFirst) },
            set: { journalSortOrders[trip.id] = $0 }
        )
    }

    private var composeButton: some View {
        IPhoneComposeButton(
            onCompose: { presentCompose(startMode: .photoPicker) },
            onComposeLongPress: { presentCompose(startMode: .camera) }
        )
    }

    private func presentCompose(startMode: PhotoPostCaptureStartMode) {
        capturePresentation = startMode
    }

    private func captureFlow(for startMode: PhotoPostCaptureStartMode) -> some View {
        PhotoPostCaptureFlow(
            journalService: journalService,
            startMode: startMode,
            onSave: { savedTrip in
                trips = replaceTrip(savedTrip, in: trips)
                onReloadTrips()
            },
            trips: trips,
            onEntrySaved: presentEntryPlacementToast
        )
    }

    private func presentEntryPlacementToast(_ placement: JournalTripPlacement) {
        if let notice = JournalNotice.entrySaved(placement: placement) {
            actionErrors.presentToast(notice)
        }
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

    private func restorePendingDraftIfNeeded() {
        guard let draftStore, !hasAttemptedDraftRestoration, !trips.isEmpty else { return }
        let drafts = draftStore.pendingDrafts().sorted { $0.updatedAt > $1.updatedAt }
        guard let draft = drafts.first else {
            hasAttemptedDraftRestoration = true
            return
        }
        guard
              let restored = draftStore.restoredJournalDestination(
                  for: draft,
                  in: trips,
                  makeBlankAfterSource: { source in
                      guard let journalService else { return nil }
                      do {
                          return try journalService.makeBlankBlogItemDraft(after: source)
                      } catch {
                          actionErrors.reportMutationFailure(error, action: .startEntry)
                          return nil
                      }
                  }
              )
        else { return }
        hasAttemptedDraftRestoration = true

        browsedTripID = restored.trip.id
        selectedTab = .journal
        journalPath = [restored.destination]
    }

    private func autoPresentComposeIfRequested() {
        guard !hasAttemptedComposeAutoPresentation else { return }
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-open-compose") else { return }
        guard !trips.isEmpty || ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-photo-post-draft") else { return }
        hasAttemptedComposeAutoPresentation = true
        capturePresentation = .photoPicker
    }

    private func applyUITestDeepLinksIfRequested() {
        guard !hasAttemptedUITestDeepLinkApplication else { return }
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("-ui-testing-open-detail") {
            guard journalPath.isEmpty else { return }
            guard let trip = journalTrip,
                  let firstItem = firstJournalItem(of: trip) else { return }
            hasAttemptedUITestDeepLinkApplication = true
            browsedTripID = nil
            selectedTab = .journal
            journalPath = [.blogItem(firstItem)]
            return
        }

        if let tabValue = uiTestingArgumentValue("ui-testing-open-tab") {
            hasAttemptedUITestDeepLinkApplication = true
            switch tabValue {
            case "journal": selectedTab = .journal
            case "trips": selectedTab = .trips
            case "share":
                onLoadAllTrips()
                selectedTab = .share
            case "settings": selectedTab = .settings
            default: break
            }
            return
        }

        if arguments.contains("-ui-testing-open-trip-editor") {
            guard let trip = journalTrip else { return }
            hasAttemptedUITestDeepLinkApplication = true
            tripEditorPresentation = TripEditorPresentation(trip: trip, isCreating: false)
        }
    }

    private func uiTestingArgumentValue(_ name: String) -> String? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("-\(name)=") }
            .map { String($0.dropFirst("-\(name)=".count)) }
    }

    private func firstJournalItem(of trip: TripDisplay) -> BlogItemDisplay? {
        TripDisplay.re_sorted(trip, newestFirst: true).days.first?.blogItems.first
    }

    @ViewBuilder
    private func journalView(
        for trip: TripDisplay,
        path: Binding<[JournalDestination]>,
        embedsNavigationStack: Bool,
        presentationMode: JournalPresentationMode = .trip,
        showsNavigationBackButton: Bool = false,
        onTripSubdetailVisibilityChange: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        JournalView(
            trip: trip,
            trips: trips,
            presentationMode: presentationMode,
            isLoadingUnassigned: isLoadingUnassigned,
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
                return try await journalService.historicalWeather(for: location, near: date)
            },
            onRefresh: onRefresh,
            path: path,
            onUpdate: { request in update(request, sourceTrip: trip) },
            onCreateBlogItem: { source, request in createNewBlogItem(request, timeZoneIdentifier: source.timeZoneIdentifier) },
            onDelete: delete,
            onAddBlogItem: { newBlogItemDestination(after: $0) },
            onNewEntry: { presentCompose(startMode: .photoPicker) },
            onEditTrip: {
                tripEditorPresentation = TripEditorPresentation(trip: trip, isCreating: false)
            },
            embedsNavigationStack: embedsNavigationStack,
            centersHeaderTitle: true,
            showsNavigationBackButton: showsNavigationBackButton,
            onTripSubdetailVisibilityChange: onTripSubdetailVisibilityChange,
            onEndTrip: { endTrip(trip) },
            sortOrder: presentationMode == .allEntries
                ? .constant(.newestFirst)
                : sortBinding(for: trip),
            scrollTrigger: $journalScrollTrigger,
            draftStore: draftStore
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

    private func update(_ request: BlogItemUpdateRequest, sourceTrip: TripDisplay? = nil) {
        guard let journalService else { return }
        Task {
            do {
                try await JournalMutationRunner.run {
                    try journalService.updateBlogItem(request)
                }
                journalPath.removeAll {
                    let item: BlogItemDisplay
                    switch $0 {
                    case .blogItem(let value), .newBlogItem(let value, _):
                        item = value
                    }
                    return item.id == request.id
                }
                let placement = JournalTripPlacement.resolveAfterUpdate(
                    request,
                    sourceItem: sourceTrip?.journalItem(withID: request.id),
                    in: trips
                )
                if sourceTrip?.isUnassigned == true, placement == .unassigned {
                    onReloadUnassigned()
                } else {
                    onReloadTrips()
                }
            } catch {
                actionErrors.reportMutationFailure(error, action: .updateEntry)
            }
        }
    }

    private func createNewBlogItem(_ request: BlogItemUpdateRequest, timeZoneIdentifier: String?) {
        guard let journalService else { return }
        let photos = request.photos.compactMap { update -> BlogItemPhotoAssetDraft? in
            guard case .added(let draft) = update else { return nil }
            return draft
        }
        Task {
            do {
                _ = try await JournalMutationRunner.run {
                    try journalService.createBlogItem(
                        blogText: request.blogText,
                        date: request.date,
                        timeZoneIdentifier: timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier,
                        photos: photos,
                        latitude: request.latitude,
                        longitude: request.longitude,
                        showElevation: request.showElevation,
                        locationName: request.location
                    )
                }
                actionErrors.reportEntryPlacement(
                    date: request.date,
                    timeZoneIdentifier: timeZoneIdentifier,
                    photos: photos,
                    in: trips
                )
                onReloadTrips()
            } catch {
                actionErrors.reportMutationFailure(error, action: .createEntry)
            }
        }
    }

    private func newBlogItemDestination(after item: BlogItemDisplay) -> JournalDestination? {
        guard let journalService else { return nil }
        do {
            let draft = try journalService.makeBlankBlogItemDraft(after: item)
            return .newBlogItem(draft, after: item)
        } catch {
            actionErrors.reportMutationFailure(error, action: .startEntry)
            return nil
        }
    }

    private func delete(_ item: BlogItemDisplay) {
        guard let journalService else { return }
        Task {
            do {
                try await JournalMutationRunner.run {
                    try journalService.deleteBlogItem(id: item.id)
                }
                onReloadTrips()
            } catch {
                actionErrors.reportMutationFailure(error, action: .deleteEntry)
            }
        }
    }

    private func updateTripDetails(
        _ trip: TripDisplay,
        title: String,
        description: String,
        startLocalDay: String,
        endLocalDay: String?,
        createsTrip: Bool
    ) {
        if createsTrip {
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
            tripEditorPresentation = nil
            return
        }
        Task {
            do {
                try await JournalMutationRunner.run {
                    try journalService.updateTripDetails(
                        id: trip.id,
                        title: title,
                        description: description,
                        startLocalDay: startLocalDay,
                        endLocalDay: endLocalDay
                    )
                }
                tripEditorPresentation = nil
                onReloadTrips()
            } catch {
                actionErrors.reportMutationFailure(error, action: .updateTrip)
            }
        }
    }

    private func endTrip(_ trip: TripDisplay) {
        let todayLocalDay = localDay(from: Date())
        let plan = TripClosurePlanner.endPlan(
            entryLocalDays: trip.days.map(\.localDay),
            todayLocalDay: todayLocalDay
        )
        if let automaticallySelectedDay = plan.automaticallySelectedDay {
            guard automaticallySelectedDay >= trip.startLocalDay else {
                tripClosingValidationMessage = TripClosingWorkflow.invalidEndMessage(for: trip)
                return
            }
            finishEndingTrip(trip, on: automaticallySelectedDay)
            return
        }
        guard let request = TripClosingWorkflow.closureRequest(for: trip, todayLocalDay: todayLocalDay) else {
            tripClosingValidationMessage = TripClosingWorkflow.invalidEndMessage(for: trip)
            return
        }
        tripClosingRequest = request
    }

    private func finishEndingTrip(_ trip: TripDisplay, on endLocalDay: String) {
        guard let journalService else { return }
        Task {
            do {
                try await JournalMutationRunner.run {
                    try journalService.endTrip(id: trip.id, endLocalDay: endLocalDay)
                }
                browsedTripID = nil
                journalPath = []
                onReloadTrips()
            } catch {
                if error as? JournalServiceError == .invalidTripRange {
                    tripClosingValidationMessage = TripClosingWorkflow.invalidEndMessage(for: trip)
                } else {
                    actionErrors.reportMutationFailure(error, action: .endTrip)
                }
            }
        }
    }

    private func startNewTrip() {
        let trip = TripDisplay(
            title: "",
            description: "",
            startLocalDay: localDay(from: Date()),
            endLocalDay: nil,
            days: []
        )
        tripEditorPresentation = TripEditorPresentation(trip: trip, isCreating: true)
    }

    private func beginEditingTrip(_ trip: TripDisplay) {
        guard !trip.isUnassigned else { return }
        tripEditorPresentation = TripEditorPresentation(trip: trip, isCreating: false)
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

        Task {
            do {
                try await JournalMutationRunner.run {
                    try journalService.deleteTrip(id: trip.id)
                }
                if browsedTripID == trip.id {
                    browsedTripID = nil
                    journalPath = []
                }
                clearTripDeletionState()
                onReloadTrips()
            } catch {
                clearTripDeletionState()
                actionErrors.reportMutationFailure(error, action: .deleteTrip)
            }
        }
    }

    private func createTrip(
        title: String,
        description: String,
        startLocalDay: String,
        endLocalDay: String?
    ) {
        guard journalService != nil else {
            tripEditorPresentation = nil
            return
        }
        if endLocalDay == nil, let currentOpenTrip {
            guard let request = TripClosingWorkflow.replacementRequest(
                oldTrip: currentOpenTrip,
                title: title,
                description: description,
                startLocalDay: startLocalDay
            ) else {
                tripClosingValidationMessage = TripClosingWorkflow.invalidReplacementMessage(for: currentOpenTrip)
                return
            }
            tripReplacementRequest = request
            return
        }
        guard let journalService else { return }
        Task {
            do {
                _ = try await JournalMutationRunner.run {
                    try journalService.createTrip(
                        title: title,
                        description: description,
                        startLocalDay: startLocalDay,
                        endLocalDay: endLocalDay
                    )
                }
                tripEditorPresentation = nil
                browsedTripID = nil
                onReloadTrips()
            } catch {
                actionErrors.reportMutationFailure(error, action: .createTrip)
            }
        }
    }

    private func replaceOpenTrip(with request: TripReplacementRequest) {
        guard let journalService else { return }
        Task {
            do {
                _ = try await JournalMutationRunner.run {
                    try journalService.replaceOpenTrip(
                        id: request.oldTrip.id,
                        title: request.title,
                        description: request.description,
                        startLocalDay: request.startLocalDay
                    )
                }
                tripEditorPresentation = nil
                browsedTripID = nil
                onReloadTrips()
            } catch {
                if error as? JournalServiceError == .invalidTripRange {
                    tripClosingValidationMessage = TripClosingWorkflow.invalidReplacementMessage(for: request.oldTrip)
                } else {
                    actionErrors.reportMutationFailure(error, action: .createTrip)
                }
            }
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
            VStack(spacing: 0) {
                IPhoneScreenHeader(title: "Journal")

                ContentUnavailableView {
                    Label("No Current Trip", systemImage: "suitcase")
                } description: {
                    Text("Start a trip to add new journal entries.")
                } actions: {
                    Button("Start new trip", systemImage: "plus", action: onStartTrip)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct IPhoneScreenHeader: View {
    let title: String
    var trailingSystemImage: String?
    var trailingAccessibilityLabel: String?
    var onTrailingAction: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(AppTypography.screenTitle)
                .accessibilityIdentifier("Primary screen header title")

            Spacer()

            if let trailingSystemImage, let onTrailingAction {
                Button(action: onTrailingAction) {
                    Image(systemName: trailingSystemImage)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppColors.controlTint)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel(trailingAccessibilityLabel ?? "Action")
            } else {
                Color.clear
                    .frame(width: 48, height: 48)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct TripsListView<Destination: View>: View {
    let trips: [TripDisplay]
    let isLoading: Bool
    let onSelectCurrentTrip: () -> Void
    let onCreate: () -> Void
    let onEdit: (TripDisplay) -> Void
    let onDelete: (TripDisplay) -> Void
    let onRefresh: () async -> Void
    let destination: (TripDisplay) -> Destination

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                IPhoneScreenHeader(
                    title: "Trips",
                    trailingSystemImage: "plus",
                    trailingAccessibilityLabel: "Create trip",
                    onTrailingAction: onCreate
                )

                if isLoading {
                    ProgressView("Loading trips…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if orderedTrips.isEmpty {
                    EmptyBlogPlaceholderView(
                        title: "No trips",
                        message: "You will see a list of your blog trips here",
                        actionTitle: "New Trip",
                        onAction: onCreate
                    )
                } else {
                    List(orderedTrips) { trip in
                        NavigationLink {
                            destination(trip)
                        } label: {
                            tripRow(for: trip)
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
                    .font(AppTypography.listTitle)
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
    let replacementTrip: TripDisplay?
    let onCancel: () -> Void
    let onSave: (String, String, String, String?) -> Void

    @State private var title: String
    @State private var description: String
    @State private var startDate: Date
    @State private var isOpenTrip: Bool
    @State private var endDate: Date
    @FocusState private var focusedTextField: TextFieldFocus?

    private enum TextFieldFocus: Hashable {
        case title
        case description
    }

    init(
        mode: Mode,
        trip: TripDisplay,
        existingTrips: [TripDisplay],
        replacementTrip: TripDisplay? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String, String, String?) -> Void
    ) {
        self.mode = mode
        self.trip = trip
        self.existingTrips = existingTrips
        self.replacementTrip = replacementTrip
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: trip.title)
        _description = State(initialValue: trip.description)
        let resolvedStartDate = Self.date(from: trip.startLocalDay) ?? Date()
        _startDate = State(initialValue: resolvedStartDate)
        _isOpenTrip = State(initialValue: trip.endLocalDay == nil)
        _endDate = State(initialValue: Self.initialEndDate(
            for: trip,
            mode: mode,
            startDate: resolvedStartDate
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorHeader

                Form {
                    Section("Trip") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Title")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                TextField("My lovely trip", text: $title)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled()
                                    .submitLabel(.done)
                                    .focused($focusedTextField, equals: .title)
                                    .onSubmit {
                                        focusedTextField = nil
                                    }
                                    .accessibilityLabel("Title")
                                    .accessibilityIdentifier("Trip title")
                                JournalClearTextButton(
                                    accessibilityLabel: "Clear trip title",
                                    isVisible: focusedTextField == .title && !title.isEmpty
                                ) {
                                    title = ""
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 8) {
                                TextEditor(text: $description)
                                    .frame(minHeight: 96)
                                    .focused($focusedTextField, equals: .description)
                                    .overlay(alignment: .topLeading) {
                                        if description.isEmpty {
                                            Text("All about my lovely trip")
                                                .foregroundStyle(.tertiary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 8)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .accessibilityLabel("Description")
                                    .accessibilityIdentifier("Trip description")
                                JournalClearTextButton(
                                    accessibilityLabel: "Clear trip description",
                                    isVisible: focusedTextField == .description
                                        && !description.isEmpty
                                ) {
                                    description = ""
                                }
                                .padding(.top, 8)
                            }
                        }
                    }

                    Section("Dates") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Start date")
                                .font(.headline)
                            if let validationMessage {
                                Text(validationMessage)
                                    .font(.headline)
                                    .foregroundStyle(.red)
                            }
                            DatePicker(
                                "Start date",
                                selection: $startDate,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .accessibilityIdentifier("Trip start date")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("End date")
                                .font(.headline)
                            Toggle("Open", isOn: $isOpenTrip)

                            DatePicker(
                                "End date",
                                selection: $endDate,
                                in: startDate...,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .accessibilityIdentifier("Trip end date")
                            .opacity(isOpenTrip ? 0.45 : 1)
                            .disabled(isOpenTrip)
                            .onChange(of: endDate) { _, _ in
                                isOpenTrip = false
                            }
                        }
                    }
                }
                .environment(\.defaultMinListRowHeight, 44)
                .listSectionSpacing(.compact)
                .scrollDismissesKeyboard(.interactively)
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
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.headline)
                        .frame(minWidth: 84, minHeight: 44)
                }
                .buttonStyle(.glass)

                Spacer()

                Text(mode.navigationTitle)
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    save()
                } label: {
                    Text("Save")
                        .font(.headline)
                        .foregroundStyle(AppColors.controlTint)
                        .frame(minWidth: 84, minHeight: 44)
                }
                .buttonStyle(.glass)
                .disabled(!canSave)
            }

        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && validationMessage == nil
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

    private var validationMessage: String? {
        if let replacementTrip, isReplacingOpenTrip,
           Self.localDay(from: startDate) <= replacementTrip.startLocalDay {
            return TripClosingWorkflow.invalidReplacementMessage(for: replacementTrip)
        }
        return validationStatus == .valid ? nil : validationStatus.statusText
    }

    private var isReplacingOpenTrip: Bool {
        mode == .create && isOpenTrip && replacementTrip != nil
    }

    private var validationStatus: TripValidationStatus {
        TripValidation.validate(
            candidate: TripValidationCandidate(
                id: mode == .edit ? trip.id : nil,
                startLocalDay: Self.localDay(from: startDate),
                endLocalDay: currentEndLocalDay
            ),
            against: existingTrips
                .filter { trip in
                    !trip.isUnassigned
                        && (!isReplacingOpenTrip || trip.id != replacementTrip?.id)
                }
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

    static func initialEndDate(
        for trip: TripDisplay,
        mode: Mode,
        startDate: Date,
        today: Date = Date()
    ) -> Date {
        if let endLocalDay = trip.endLocalDay {
            return date(from: endLocalDay) ?? startDate
        }

        switch mode {
        case .create:
            return startDate
        case .edit:
            return max(startDate, Calendar.current.startOfDay(for: today))
        }
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

private struct IPhoneComposeButton: View {
    let onCompose: () -> Void
    let onComposeLongPress: () -> Void

    @State private var isPressActive = false
    @State private var didTriggerLongPress = false
    @State private var longPressWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: IPhoneTab.compose.systemImage)
                .font(.body.weight(.semibold))
            Text(IPhoneTab.compose.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.black)
        .frame(width: 68, height: 60)
        .background(AppColors.controlTint, in: .rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 14))
        .highPriorityGesture(pressGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New BlogItem")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onCompose() }
        .accessibilityAction(named: "Open Camera") { onComposeLongPress() }
        .onDisappear {
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
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

#Preview("iPhone shell") {
    IPhoneShell(trips: .constant([DevelopmentSampleData.currentTrip]))
}
