import SwiftUI
import UIKit
import ImageIO
import MapKit
import CoreLocation
import OSLog
import WeatherKit

struct JournalHeaderPresentation: Equatable {
    let progress: CGFloat

    init(scrollOffset: CGFloat, collapseDistance: CGFloat = 120) {
        progress = min(max(scrollOffset / max(collapseDistance, 1), 0), 1)
    }

    var sizeProgress: CGFloat {
        min(progress * 2, 1)
    }

    var positionProgress: CGFloat {
        max((progress - 0.5) * 2, 0)
    }
}

struct JournalView: View {
    let trip: TripDisplay
    let currentLocationProvider: @MainActor () async throws -> CLLocationCoordinate2D
    let reverseGeocodeProvider: (CLLocationCoordinate2D) async throws -> String?
    let historicalWeatherProvider: (WeatherLocation, Date) async throws -> WeatherCapture?
    let onRefresh: () async -> Void
    let onUpdate: (BlogItemUpdateRequest) -> Void
    let onCreateBlogItem: (BlogItemDisplay, BlogItemUpdateRequest) -> Void
    let onDelete: (BlogItemDisplay) -> Void
    let onAddBlogItem: (BlogItemDisplay) -> Void
    let onNewEntry: () -> Void
    let onEditTrip: () -> Void
    let onEndTrip: () -> Void
    let embedsNavigationStack: Bool
    let centersHeaderTitle: Bool
    let onOpenSidebar: (() -> Void)?
    let onTripSubdetailVisibilityChange: (Bool) -> Void
    @Binding var path: [JournalDestination]

    @State private var scrollOffset = CGFloat.zero

    init(
        trip: TripDisplay,
        currentLocationProvider: @escaping @MainActor () async throws -> CLLocationCoordinate2D = {
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        },
        reverseGeocodeProvider: @escaping (CLLocationCoordinate2D) async throws -> String? = { _ in nil },
        historicalWeatherProvider: @escaping (WeatherLocation, Date) async throws -> WeatherCapture? = { _, _ in nil },
        onRefresh: @escaping () async -> Void = {},
        path: Binding<[JournalDestination]> = .constant([]),
        onUpdate: @escaping (BlogItemUpdateRequest) -> Void = { _ in },
        onCreateBlogItem: @escaping (BlogItemDisplay, BlogItemUpdateRequest) -> Void = { _, _ in },
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in },
        onAddBlogItem: @escaping (BlogItemDisplay) -> Void = { _ in },
        onNewEntry: @escaping () -> Void = {},
        onEditTrip: @escaping () -> Void = {},
        embedsNavigationStack: Bool = true,
        centersHeaderTitle: Bool = false,
        onOpenSidebar: (() -> Void)? = nil,
        onTripSubdetailVisibilityChange: @escaping (Bool) -> Void = { _ in },
        onEndTrip: @escaping () -> Void = {}
    ) {
        self.trip = trip
        self.currentLocationProvider = currentLocationProvider
        self.reverseGeocodeProvider = reverseGeocodeProvider
        self.historicalWeatherProvider = historicalWeatherProvider
        self.onRefresh = onRefresh
        self.onUpdate = onUpdate
        self.onCreateBlogItem = onCreateBlogItem
        self.onDelete = onDelete
        self.onAddBlogItem = onAddBlogItem
        self.onNewEntry = onNewEntry
        self.onEditTrip = onEditTrip
        self.embedsNavigationStack = embedsNavigationStack
        self.centersHeaderTitle = centersHeaderTitle
        self.onOpenSidebar = onOpenSidebar
        self.onTripSubdetailVisibilityChange = onTripSubdetailVisibilityChange
        self.onEndTrip = onEndTrip
        _path = path
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack(path: $path) {
                    content
                        .navigationDestination(for: JournalDestination.self) { destination in
                            destinationView(destination)
                        }
                }
            } else {
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            if trip.isUnassigned && trip.days.isEmpty {
                ContentUnavailableView(
                    "No Unassigned Entries",
                    systemImage: "tray",
                    description: Text("All entries belong to a trip.")
                )
                .containerRelativeFrame(.vertical)
            } else if trip.days.isEmpty {
                EmptyBlogPlaceholderView(
                    title: "No entries",
                    message: "You will see a list of your blog entries here",
                    actionTitle: "New Entry",
                    onAction: onNewEntry
                )
                .containerRelativeFrame(.vertical)
            } else {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(Array(trip.days.enumerated()), id: \.element.id) { index, day in
                        let progress = JournalDayProgress(
                            startLocalDay: trip.startLocalDay,
                            dayLocalDay: day.localDay,
                            endLocalDay: trip.endLocalDay ?? JournalDayProgress.localDay(from: Date())
                        )
                        DayPostSection(
                            dayPost: day,
                            dayNumber: progress?.dayNumber ?? index + 1,
                            totalDays: progress?.totalDays ?? trip.days.count,
                            showsNewestFirst: false,
                            showsActions: !trip.isUnassigned,
                            blogItemDestination: embedsNavigationStack ? nil : { item in
                                AnyView(destinationView(.blogItem(item)))
                            },
                            onAddBlogItem: trip.isUnassigned ? nil : onAddBlogItem
                        )
                        if index < trip.days.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .refreshable { await onRefresh() }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, newOffset in
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollOffset = newOffset
            }
        }
        .safeAreaInset(edge: .top) { tripHeader.padding(.horizontal, 18) }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if !embedsNavigationStack {
                onTripSubdetailVisibilityChange(false)
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: JournalDestination) -> some View {
        switch destination {
        case .blogItem(let item):
            BlogItemDetailView(
                item: item,
                currentLocationProvider: currentLocationProvider,
                reverseGeocodeProvider: reverseGeocodeProvider,
                historicalWeatherProvider: historicalWeatherProvider,
                onUpdate: onUpdate,
                onDelete: onDelete
            )
            .toolbar(.hidden, for: .tabBar)
            .onAppear { onTripSubdetailVisibilityChange(true) }
        case .newBlogItem(let item, let source):
            BlogItemDetailView(
                item: item,
                currentLocationProvider: currentLocationProvider,
                reverseGeocodeProvider: reverseGeocodeProvider,
                historicalWeatherProvider: historicalWeatherProvider,
                onUpdate: onUpdate,
                onCreate: { onCreateBlogItem(source, $0) },
                onDelete: onDelete,
                isNewItem: true
            )
            .toolbar(.hidden, for: .tabBar)
            .onAppear { onTripSubdetailVisibilityChange(true) }
        }
    }

    private var tripHeader: some View {
        GeometryReader { proxy in
            let presentation = JournalHeaderPresentation(scrollOffset: headerScrollOffset)
            let progress = presentation.progress
            let sizeProgress = presentation.sizeProgress
            let positionProgress = presentation.positionProgress
            let actionReservation: CGFloat = 52
            let reservesLeadingAction = onOpenSidebar != nil
            let availableWidth = max(
                0,
                proxy.size.width - (actionReservation * (reservesLeadingAction ? 2 : 1))
            )
            let measuredTitleWidth = ceil(
                (trip.title as NSString).size(
                    withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .bold)]
                ).width
            ) + 28
            let compactTitleWidth = min(availableWidth, max(44, measuredTitleWidth))
            let compactTotalWidth = min(250, max(0, availableWidth - 8))
            let compactContentWidth = max(0, compactTotalWidth - 28)
            let titleWidth = reservesLeadingAction
                ? availableWidth + (compactTitleWidth - availableWidth) * sizeProgress
                : availableWidth + (compactContentWidth - availableWidth) * sizeProgress
            let titleOffset = reservesLeadingAction
                ? actionReservation + (availableWidth - compactTitleWidth) / 2 * positionProgress
                : (availableWidth - compactTotalWidth) / 2 * positionProgress

            ZStack(alignment: .topLeading) {
                Color.clear

                if let onOpenSidebar {
                    Button(action: onOpenSidebar) {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppColors.controlOrange)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .accessibilityLabel("Show menu")
                }

            Text(trip.title)
                .font(
                    sizeProgress == 0
                        ? AppTypography.screenTitle
                        : .system(
                            size: 34 - (17 * sizeProgress),
                            weight: .bold,
                            design: .rounded
                        )
                )
                .multilineTextAlignment(.leading)
                .lineLimit(sizeProgress < 1 ? nil : 1)
                .frame(width: titleWidth, alignment: .leading)
                .padding(.horizontal, 14 * sizeProgress)
                .padding(.vertical, 9 * sizeProgress)
                .background(.regularMaterial.opacity(progress), in: .capsule)
                .offset(x: titleOffset)
                .accessibilityIdentifier("Journal trip title")

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if !trip.isUnassigned {
                    Menu {
                        Button("Edit Trip", systemImage: "square.and.pencil", action: onEditTrip)
                        if trip.isCurrent {
                            Button("End Trip", systemImage: "flag.checkered", action: onEndTrip)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: .circle)
                    }
                    .accessibilityLabel("Trip actions")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: presentation)
        }
        .frame(height: 92)
        .padding(.vertical, 8)
    }

    private var headerScrollOffset: CGFloat {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-collapsed-journal-header") {
            return 120
        }
        return scrollOffset
    }
}

struct BlogItemDetailView: View {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InstaBlog",
        category: "BlogItemEnrichment"
    )

    private struct EditablePhoto: Identifiable {
        let id: UUID
        var existing: PhotoItemDisplay?
        var draft: BlogItemPhotoAssetDraft?
        var preview: UIImage?

        var caption: String {
            get { existing?.caption ?? draft?.photoCaption ?? "" }
            set {
                if existing != nil { existing?.caption = newValue }
                if draft != nil { draft?.photoCaption = newValue }
            }
        }

        var date: Date {
            existing?.date ?? draft?.photoDate ?? Date()
        }
    }

    private let originalItem: BlogItemDisplay
    private let currentLocationProvider: @MainActor () async throws -> CLLocationCoordinate2D
    private let reverseGeocodeProvider: (CLLocationCoordinate2D) async throws -> String?
    private let historicalWeatherProvider: (WeatherLocation, Date) async throws -> WeatherCapture?
    private let onUpdate: (BlogItemUpdateRequest) -> Void
    private let onCreate: ((BlogItemUpdateRequest) -> Void)?
    private let onDelete: (BlogItemDisplay) -> Void
    private let isNewItem: Bool
    private let allowsDeletion: Bool
    private let canSave: Bool
    private let isSaving: Bool
    private let dismissAfterSave: Bool
    private let usesCurrentLocationForNewItem: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var blogText: String
    @State private var date: Date
    @State private var location: String
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var temperature: Double
    @State private var temperatureText: String
    @State private var condition: String
    @State private var photos: [EditablePhoto]
    @State private var isShowingPhotoPicker = false
    @State private var isShowingDatePickerSheet = false
    @State private var isShowingTimePickerSheet = false
    @State private var selectedMapCoordinate: LocationPickerCoordinate?
    @State private var isLoadingLocationPicker = false
    @State private var isResolvingPlaceName = false
    @State private var isShowingDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var locationErrorMessage: String?
    @State private var hasLoadedInitialMetadata = false
    @FocusState private var isBlogTextFocused: Bool

    init(
        item: BlogItemDisplay,
        currentLocationProvider: @escaping @MainActor () async throws -> CLLocationCoordinate2D = {
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        },
        reverseGeocodeProvider: @escaping (CLLocationCoordinate2D) async throws -> String? = { _ in nil },
        historicalWeatherProvider: @escaping (WeatherLocation, Date) async throws -> WeatherCapture? = { _, _ in nil },
        onUpdate: @escaping (BlogItemUpdateRequest) -> Void = { _ in },
        onCreate: ((BlogItemUpdateRequest) -> Void)? = nil,
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in },
        isNewItem: Bool = false,
        allowsDeletion: Bool = true,
        canSave: Bool = true,
        isSaving: Bool = false,
        dismissAfterSave: Bool = true,
        usesCurrentLocationForNewItem: Bool = false,
        initialPhotoDraft: BlogItemPhotoAssetDraft? = nil,
        initialPreviewImage: UIImage? = nil,
        initialPhotoDrafts: [BlogItemPhotoAssetDraft] = [],
        initialPreviewImages: [UIImage?] = []
    ) {
        originalItem = item
        self.currentLocationProvider = currentLocationProvider
        self.reverseGeocodeProvider = reverseGeocodeProvider
        self.historicalWeatherProvider = historicalWeatherProvider
        self.onUpdate = onUpdate
        self.onCreate = onCreate
        self.onDelete = onDelete
        self.isNewItem = isNewItem
        self.allowsDeletion = allowsDeletion
        self.canSave = canSave
        self.isSaving = isSaving
        self.dismissAfterSave = dismissAfterSave
        self.usesCurrentLocationForNewItem = usesCurrentLocationForNewItem
        _blogText = State(initialValue: item.blogText)
        _date = State(initialValue: item.date)
        _location = State(initialValue: item.location)
        _latitude = State(initialValue: item.latitude)
        _longitude = State(initialValue: item.longitude)
        _temperature = State(initialValue: item.weather.temperatureCelsius ?? 0)
        _temperatureText = State(
            initialValue: item.weather.temperatureCelsius.map {
                $0.formatted(.number.precision(.fractionLength(0...1)))
            } ?? ""
        )
        _condition = State(initialValue: item.weather.conditionCode ?? "")
        var initialPhotos = item.photos.map {
            EditablePhoto(id: $0.id, existing: $0, draft: nil, preview: nil)
        }
        if let initialPhotoDraft {
            initialPhotos.append(
                EditablePhoto(
                    id: UUID(),
                    existing: nil,
                    draft: initialPhotoDraft,
                    preview: initialPreviewImage
                )
            )
        }
        for (index, draft) in initialPhotoDrafts.enumerated() {
            initialPhotos.append(
                EditablePhoto(
                    id: UUID(),
                    existing: nil,
                    draft: draft,
                    preview: index < initialPreviewImages.count ? initialPreviewImages[index] : nil
                )
            )
        }
        _photos = State(initialValue: initialPhotos)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            Form {
                Section("Photos") {
                    if photos.isEmpty {
                        Button("Add Photo", systemImage: "photo.badge.plus") {
                            isShowingPhotoPicker = true
                        }
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach($photos) { $photo in
                                    photoEditor(photo: $photo)
                                        .frame(width: 290)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        Button("Add Another Photo", systemImage: "photo.badge.plus") {
                            isShowingPhotoPicker = true
                        }
                    }
                }

                Section("Post") {
                    TextEditor(text: $blogText)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("BlogItem blog text")
                        .focused($isBlogTextFocused)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                scrollProxy.scrollTo("BlogItem blog text", anchor: .center)
                            }
                        )
                }
                .id("BlogItem blog text")

                Section("Details") {
                    dateTimeEditor
                    JournalLocationEditor(
                        location: $location,
                        isLoading: isLoadingLocationPicker,
                        isResolving: isResolvingPlaceName,
                        onAdjustLocation: presentLocationPicker,
                        accessibilityIdentifier: "BlogItem location"
                    )
                    JournalTemperatureEditor(
                        temperature: $temperature,
                        temperatureText: $temperatureText
                    )
                    JournalWeatherConditionEditor(
                        condition: $condition,
                        accessibilityIdentifier: "BlogItem weather condition"
                    )
                    LabeledContent("Author", value: originalItem.author)
                        .foregroundStyle(.secondary)
                }

                if allowsDeletion && !isNewItem {
                    Section {
                        Button("Delete Post", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isBlogTextFocused) { _, focused in
                guard focused else { return }
                scrollProxy.scrollTo("BlogItem blog text", anchor: .center)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard isBlogTextFocused else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.15)) {
                        scrollProxy.scrollTo("BlogItem blog text", anchor: .center)
                    }
                }
            }
        }
        .navigationTitle(location.isEmpty ? "Post" : location)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .tint(AppColors.controlOrange)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(AppColors.controlOrange)
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .foregroundStyle(AppColors.controlOrange)
                    .disabled(isSaving || !canSave || !hasContent)
            }
        }
        .sheet(isPresented: $isShowingPhotoPicker) {
            SharedMultiPhotoLibraryPicker { result in
                isShowingPhotoPicker = false
                switch result {
                case .success(let selections):
                    addPhotos(selections)
                case .failure:
                    errorMessage = "The selected photo could not be loaded."
                }
            }
        }
        .sheet(item: $selectedMapCoordinate) { selectedMapCoordinate in
            NavigationStack {
                BlogItemLocationPickerSheet(
                    coordinate: selectedMapCoordinate.coordinate,
                    onCancel: { self.selectedMapCoordinate = nil },
                    onConfirm: applySelectedMapCoordinate
                )
            }
        }
        .sheet(isPresented: $isShowingDatePickerSheet) {
            NavigationStack {
                VStack {
                    DatePicker(
                        "Date",
                        selection: $date,
                        in: ...Date(),
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    Spacer()
                }
                .navigationTitle("Choose date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isShowingDatePickerSheet = false
                            refreshHistoricalWeatherForCurrentSelection()
                        }
                    }
                }
            }
            .environment(\.timeZone, editingTimeZone)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingTimePickerSheet) {
            NavigationStack {
                VStack {
                    DatePicker(
                        "Time",
                        selection: $date,
                        in: ...Date(),
                        displayedComponents: [.hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding()
                    Spacer()
                }
                .navigationTitle("Choose time")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isShowingTimePickerSheet = false
                            refreshHistoricalWeatherForCurrentSelection()
                        }
                    }
                }
            }
            .environment(\.timeZone, editingTimeZone)
            .presentationDetents([.medium])
        }
        .alert("Are you sure?", isPresented: $isShowingDeleteConfirmation) {
            Button("Yes", role: .destructive) {
                onDelete(originalItem)
                dismiss()
            }
            Button("No", role: .cancel) {}
        } message: {
            Text("You can recover this post later from Deleted entries in Settings.")
        }
        .alert("Photo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Unable to update location", isPresented: Binding(
            get: { locationErrorMessage != nil },
            set: { if !$0 { locationErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(locationErrorMessage ?? "")
        }
        .task {
            await loadInitialMetadataIfNeeded()
        }
        .task {
            guard isNewItem else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Unable to schedule initial post focus: \(error.localizedDescription, privacy: .public)")
                return
            }
            isBlogTextFocused = true
        }
    }

    private var dateTimeEditor: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Button {
                    isShowingDatePickerSheet = true
                } label: {
                    Text(dateDisplayText)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: .rect(cornerRadius: 16)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change date")

                Button {
                    isShowingTimePickerSheet = true
                } label: {
                    Text(timeDisplayText)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: .rect(cornerRadius: 16)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change time")
            }
        } label: {
            Text("Date and time")
        }
    }

    private var editingTimeZone: TimeZone {
        originalItem.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    private var dateDisplayText: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = editingTimeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private var timeDisplayText: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = editingTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func presentLocationPicker() {
        if let latitude, let longitude {
            selectedMapCoordinate = LocationPickerCoordinate(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
            return
        }

        isLoadingLocationPicker = true
        Task {
            do {
                let coordinate = try await currentLocationProvider()
                selectedMapCoordinate = LocationPickerCoordinate(coordinate: coordinate)
                isLoadingLocationPicker = false
            } catch {
                isLoadingLocationPicker = false
                locationErrorMessage = "The current location could not be loaded."
            }
        }
    }

    private func applySelectedMapCoordinate(_ coordinate: CLLocationCoordinate2D) {
        selectedMapCoordinate = nil
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        isResolvingPlaceName = true

        Task {
            do {
                let placeName = try await reverseGeocodeProvider(coordinate)
                if let placeName, !placeName.isEmpty {
                    location = placeName
                }
                isResolvingPlaceName = false
            } catch {
                isResolvingPlaceName = false
                locationErrorMessage = "The selected location could not be reverse geocoded."
            }
            refreshHistoricalWeatherForCurrentSelection()
        }
    }

    private func refreshHistoricalWeatherForCurrentSelection() {
        guard let latitude, let longitude else { return }
        Task {
            do {
                guard let weather = try await historicalWeatherProvider(
                    WeatherLocation(latitude: latitude, longitude: longitude),
                    date
                ) else { return }
                updateTemperature(to: Double(weather.temperatureCelsius))
                condition = weather.conditionCode
            } catch {
                Self.logger.error(
                    "Unable to load historical weather after an explicit selection: \(error.localizedDescription, privacy: .public)"
                )
                locationErrorMessage = "The weather for the selected location and date could not be loaded."
            }
        }
    }

    private func updateTemperature(to value: Double) {
        let normalized = TemperatureValue.normalized(value)
        temperature = normalized
        temperatureText = normalized.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func photoEditor(photo: Binding<EditablePhoto>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            photoSurface(photo.wrappedValue)
                .frame(width: 290, height: 220)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(alignment: .topTrailing) {
                    Button(role: .destructive) {
                        photos.removeAll { $0.id == photo.wrappedValue.id }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: .circle)
                    }
                    .padding(8)
                    .accessibilityLabel("Remove photo")
                }
            TextField("Photo caption", text: Binding(
                get: { photo.wrappedValue.caption },
                set: { photo.wrappedValue.caption = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func photoSurface(_ photo: EditablePhoto) -> some View {
        if let preview = photo.preview {
            Image(uiImage: preview).resizable().scaledToFill()
        } else if let existing = photo.existing {
            JournalPhotoSurface(photo: existing, scaling: .fill)
        } else {
            MissingPhotoPlaceholder()
        }
    }

    private var hasContent: Bool {
        !photos.isEmpty || !blogText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addPhotos(_ selections: [SharedPhotoLibrarySelection]) {
        let isReplacingOnlyPhoto = originalItem.photos.count == 1
            && photos.isEmpty
            && selections.count == 1
        let drafts = selections.map { selection in
            let metadata = PhotoAssetMetadata.extract(from: selection.data)
            let size = Self.pixelSize(from: selection.data)
            return BlogItemPhotoAssetDraft(
                imageData: selection.data,
                mimeType: selection.mimeType,
                photoLibraryAssetIdentifier: selection.assetIdentifier,
                pixelWidth: size.width,
                pixelHeight: size.height,
                photoDate: selection.createdAt ?? metadata.createdAt ?? date,
                photoCaption: "",
                timeZoneIdentifier: metadata.timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier,
                latitude: (selection.coordinate ?? metadata.coordinate)?.latitude,
                longitude: (selection.coordinate ?? metadata.coordinate)?.longitude
            )
        }
        photos.append(contentsOf: zip(selections, drafts).map { selection, draft in
            EditablePhoto(
                id: UUID(),
                existing: nil,
                draft: draft,
                preview: UIImage(data: selection.data)
            )
        })
        if isReplacingOnlyPhoto, let draft = drafts.first {
            Task { await adoptReplacementMetadata(from: draft) }
        }
    }

    private func adoptReplacementMetadata(from draft: BlogItemPhotoAssetDraft) async {
        date = draft.photoDate
        guard let latitude = draft.latitude, let longitude = draft.longitude else { return }
        self.latitude = latitude
        self.longitude = longitude
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        do {
            location = try await reverseGeocodeProvider(coordinate) ?? ""
        } catch {
            Self.logger.error("Unable to reverse geocode replacement photo: \(error.localizedDescription, privacy: .public)")
            location = ""
        }
        do {
            if let weather = try await historicalWeatherProvider(
                WeatherLocation(latitude: latitude, longitude: longitude),
                draft.photoDate
            ) {
                updateTemperature(to: Double(weather.temperatureCelsius))
                condition = weather.conditionCode
            }
        } catch {
            Self.logger.error("Unable to load weather for replacement photo: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadInitialMetadataIfNeeded() async {
        guard isNewItem, !hasLoadedInitialMetadata else { return }
        hasLoadedInitialMetadata = true

        var coordinate = latitude.flatMap { latitude in
            longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
        }
        if coordinate == nil, usesCurrentLocationForNewItem {
            do {
                coordinate = try await currentLocationProvider()
            } catch {
                Self.logger.notice("Unable to enrich new entry with current location: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let coordinate else { return }

        latitude = coordinate.latitude
        longitude = coordinate.longitude
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                if let resolvedLocation = try await reverseGeocodeProvider(coordinate) {
                    location = resolvedLocation
                }
            } catch {
                Self.logger.notice("Unable to enrich new entry with a place name: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            if let weather = try await historicalWeatherProvider(
                WeatherLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                date
            ) {
                updateTemperature(to: Double(weather.temperatureCelsius))
                condition = weather.conditionCode
            }
        } catch {
            Self.logger.notice("Unable to enrich new entry with weather: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let photoUpdates = photos.compactMap { photo -> BlogItemPhotoUpdate? in
            if let existing = photo.existing { return .existing(existing) }
            if let draft = photo.draft { return .added(draft) }
            return nil
        }
        let request = BlogItemUpdateRequest(
            id: originalItem.id,
            blogText: blogText,
            date: date,
            location: location,
            latitude: latitude,
            longitude: longitude,
            temperatureCelsius: temperature,
            weatherCondition: condition.isEmpty ? nil : condition,
            photos: photoUpdates
        )
        if let onCreate { onCreate(request) } else { onUpdate(request) }
        if dismissAfterSave { dismiss() }
    }

    private static func pixelSize(from data: Data) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (nil, nil) }
        return (
            properties[kCGImagePropertyPixelWidth] as? Int,
            properties[kCGImagePropertyPixelHeight] as? Int
        )
    }
}

private struct LocationPickerCoordinate: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

private struct BlogItemLocationPickerSheet: View {
    @State private var coordinate: CLLocationCoordinate2D
    let onCancel: () -> Void
    let onConfirm: (CLLocationCoordinate2D) -> Void

    init(
        coordinate: CLLocationCoordinate2D,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        _coordinate = State(initialValue: coordinate)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        DraggablePinMapView(coordinate: $coordinate)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Adjust location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use This Location") {
                        onConfirm(coordinate)
                    }
                }
            }
    }
}

private struct DraggablePinMapView: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D

    func makeCoordinator() -> Coordinator {
        Coordinator(coordinate: $coordinate)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = true

        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        context.coordinator.annotation = annotation
        mapView.addAnnotation(annotation)
        mapView.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ),
            animated: false
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard let annotation = context.coordinator.annotation else { return }
        if abs(annotation.coordinate.latitude - coordinate.latitude) > 0.000_001
            || abs(annotation.coordinate.longitude - coordinate.longitude) > 0.000_001 {
            annotation.coordinate = coordinate
            mapView.setCenter(coordinate, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        @Binding var coordinate: CLLocationCoordinate2D
        var annotation: MKPointAnnotation?

        init(coordinate: Binding<CLLocationCoordinate2D>) {
            _coordinate = coordinate
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let identifier = "DraggablePin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.isDraggable = true
            view.canShowCallout = false
            if let markerView = view as? MKMarkerAnnotationView {
                markerView.markerTintColor = .systemGreen
                markerView.glyphImage = UIImage(systemName: "mappin")
            }
            return view
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            didChange newState: MKAnnotationView.DragState,
            fromOldState oldState: MKAnnotationView.DragState
        ) {
            switch newState {
            case .ending, .canceling:
                if let annotation = view.annotation {
                    coordinate = annotation.coordinate
                }
                view.dragState = .none
            default:
                break
            }
        }
    }
}

private struct JournalLocationEditor: View {
    @Binding var location: String
    let isLoading: Bool
    let isResolving: Bool
    let onAdjustLocation: () -> Void
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAdjustLocation) {
                locationIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Adjust location on map")

            TextField("Location", text: $location)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var locationIcon: some View {
        Group {
            if isLoading || isResolving {
                ProgressView().frame(width: 18, height: 18)
            } else {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 17, weight: .semibold))
            }
        }
        .foregroundStyle(AppColors.locationGreen)
        .frame(width: 32, height: 32)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .circle)
    }
}

private struct JournalTemperatureEditor: View {
    @Binding var temperature: Double
    @Binding var temperatureText: String
    @FocusState private var isTemperatureFocused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 0) {
                Button {
                    updateTemperature(to: temperature - 1)
                } label: {
                    Image(systemName: "minus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 42)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(temperature <= TemperatureValue.minimumCelsius)
                .accessibilityLabel("Decrease temperature")

                TextField("", text: $temperatureText)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .frame(width: 72, height: 42)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .accessibilityIdentifier("BlogItem temperature")
                    .focused($isTemperatureFocused)
                    .onChange(of: temperatureText) { _, newValue in
                        syncTemperature(from: newValue)
                    }
                    .onChange(of: isTemperatureFocused) { wasFocused, isFocused in
                        if wasFocused, !isFocused {
                            normalizeTemperatureInput()
                        }
                    }
                    .onSubmit {
                        normalizeTemperatureInput()
                    }

                Button {
                    updateTemperature(to: temperature + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 42)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(.rect(bottomTrailingRadius: 16, topTrailingRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(temperature >= TemperatureValue.maximumCelsius)
                .accessibilityLabel("Increase temperature")
            }
        } label: {
            Text("Temperature (°C)")
        }
    }

    private func updateTemperature(to value: Double) {
        let normalized = TemperatureValue.normalized(value)
        temperature = normalized
        temperatureText = normalized.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func syncTemperature(from rawValue: String) {
        guard !rawValue.isEmpty, rawValue != "-" else { return }
        var normalized = ""
        for character in rawValue {
            if character.isNumber {
                normalized.append(character)
            } else if character == "-" && normalized.isEmpty {
                normalized.append(character)
            } else if character == "." && !normalized.contains(".") {
                normalized.append(character)
            }
        }
        guard normalized == rawValue else {
            temperatureText = normalized
            return
        }
        guard let value = Double(normalized) else { return }
        temperature = TemperatureValue.normalized(value)
    }

    private func normalizeTemperatureInput() {
        guard let value = Double(temperatureText) else {
            temperatureText = temperature.formatted(.number.precision(.fractionLength(0...1)))
            return
        }
        updateTemperature(to: value)
    }
}

private struct JournalWeatherConditionEditor: View {
    @Binding var condition: String
    let accessibilityIdentifier: String

    var body: some View {
        LabeledContent {
            Menu {
                Button {
                    condition = ""
                } label: {
                    Label("Unknown", systemImage: "questionmark.circle")
                }
                ForEach(WeatherConditionCatalog.supportedConditions, id: \.rawValue) { weatherCondition in
                    Button {
                        condition = weatherCondition.rawValue
                    } label: {
                        Label(
                            WeatherConditionCatalog.description(for: weatherCondition.rawValue),
                            systemImage: WeatherConditionCatalog.systemImage(for: weatherCondition.rawValue)
                        )
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(
                        systemName: condition.isEmpty
                            ? "questionmark.circle"
                            : WeatherConditionCatalog.systemImage(for: condition)
                    )
                    .foregroundStyle(.secondary)
                    Text(
                        condition.isEmpty
                            ? "Unknown"
                            : WeatherConditionCatalog.description(for: condition)
                    )
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 16)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier)
        } label: {
            Text("Weather")
        }
    }
}
