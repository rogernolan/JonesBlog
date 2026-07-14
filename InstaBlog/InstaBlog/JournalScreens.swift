import SwiftUI
import UIKit
import ImageIO
import MapKit
import CoreLocation
import WeatherKit

struct JournalView: View {
    let trip: TripDisplay
    let weatherAttributionProvider: (any WeatherAttributing)?
    let currentLocationProvider: @MainActor () async throws -> CLLocationCoordinate2D
    let reverseGeocodeProvider: (CLLocationCoordinate2D) async throws -> String?
    let historicalWeatherProvider: (WeatherLocation, Date) async throws -> WeatherCapture?
    let onRefresh: () async -> Void
    let onUpdate: (BlogItemUpdateRequest) -> Void
    let onDelete: (BlogItemDisplay) -> Void
    let onAddBlogItem: (BlogItemDisplay) -> Void
    let onAddGallery: (DayPostDisplay) -> Void
    let onCreateEntryInGallery: (GalleryDisplay) -> Void
    let onMoveItemsToGallery: ([BlogItem.ID], Gallery.ID) -> Void
    let onMoveItemOutOfGallery: (BlogItem.ID) -> Void
    let onUpdateGallery: (GalleryDisplay) -> Void
    let onReorderGallery: (Gallery.ID, [BlogItem.ID]) -> Void
    let onDeleteGallery: (Gallery.ID, Bool) -> Void
    let onEditTrip: () -> Void
    let onEndTrip: () -> Void
    let embedsNavigationStack: Bool
    let centersHeaderTitle: Bool
    let onOpenSidebar: (() -> Void)?
    let onTripSubdetailVisibilityChange: (Bool) -> Void
    @Binding var path: [JournalDestination]
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var compactTitleSize = 17.0
    @State private var menuLeadingPadding: CGFloat = 0
    @State private var journalScrollPosition = ScrollPosition()

    init(
        trip: TripDisplay,
        weatherAttributionProvider: (any WeatherAttributing)? = nil,
        currentLocationProvider: @escaping @MainActor () async throws -> CLLocationCoordinate2D = {
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        },
        reverseGeocodeProvider: @escaping (CLLocationCoordinate2D) async throws -> String? = { _ in nil },
        historicalWeatherProvider: @escaping (WeatherLocation, Date) async throws -> WeatherCapture? = { _, _ in nil },
        onRefresh: @escaping () async -> Void = {},
        path: Binding<[JournalDestination]> = .constant([]),
        onUpdate: @escaping (BlogItemUpdateRequest) -> Void = { _ in },
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in },
        onAddBlogItem: @escaping (BlogItemDisplay) -> Void = { _ in },
        onAddGallery: @escaping (DayPostDisplay) -> Void = { _ in },
        onCreateEntryInGallery: @escaping (GalleryDisplay) -> Void = { _ in },
        onMoveItemsToGallery: @escaping ([BlogItem.ID], Gallery.ID) -> Void = { _, _ in },
        onMoveItemOutOfGallery: @escaping (BlogItem.ID) -> Void = { _ in },
        onUpdateGallery: @escaping (GalleryDisplay) -> Void = { _ in },
        onReorderGallery: @escaping (Gallery.ID, [BlogItem.ID]) -> Void = { _, _ in },
        onDeleteGallery: @escaping (Gallery.ID, Bool) -> Void = { _, _ in },
        onEditTrip: @escaping () -> Void = {},
        embedsNavigationStack: Bool = true,
        centersHeaderTitle: Bool = false,
        onOpenSidebar: (() -> Void)? = nil,
        onTripSubdetailVisibilityChange: @escaping (Bool) -> Void = { _ in },
        onEndTrip: @escaping () -> Void = {}
    ) {
        self.trip = trip
        self.weatherAttributionProvider = weatherAttributionProvider
        self.currentLocationProvider = currentLocationProvider
        self.reverseGeocodeProvider = reverseGeocodeProvider
        self.historicalWeatherProvider = historicalWeatherProvider
        self.onRefresh = onRefresh
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onAddBlogItem = onAddBlogItem
        self.onAddGallery = onAddGallery
        self.onCreateEntryInGallery = onCreateEntryInGallery
        self.onMoveItemsToGallery = onMoveItemsToGallery
        self.onMoveItemOutOfGallery = onMoveItemOutOfGallery
        self.onUpdateGallery = onUpdateGallery
        self.onReorderGallery = onReorderGallery
        self.onDeleteGallery = onDeleteGallery
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
                    journalContent
                        .navigationDestination(for: JournalDestination.self) { destination in
                            Self.makeDestinationView(
                                for: destination,
                                trip: trip,
                                weatherAttributionProvider: weatherAttributionProvider,
                                currentLocationProvider: currentLocationProvider,
                                reverseGeocodeProvider: reverseGeocodeProvider,
                                historicalWeatherProvider: historicalWeatherProvider,
                                onUpdate: onUpdate,
                                onDelete: onDelete,
                                onCreateEntryInGallery: onCreateEntryInGallery,
                                onMoveItemsToGallery: onMoveItemsToGallery,
                                onMoveItemOutOfGallery: onMoveItemOutOfGallery,
                                onUpdateGallery: onUpdateGallery,
                                onReorderGallery: onReorderGallery,
                                onDeleteGallery: onDeleteGallery
                            )
                        }
                }
            } else {
                journalContent
            }
        }
    }

    private var journalContent: some View {
        ScrollView {
            if trip.isUnassigned && displayedDays.isEmpty {
                ContentUnavailableView(
                    "No Unassigned Entries",
                    systemImage: "tray",
                    description: Text("All entries belong to a trip.")
                )
                .containerRelativeFrame(.vertical)
            } else {
                LazyVStack(alignment: .leading, spacing: 34) {
                ForEach(displayedDays, id: \.element.id) { index, day in
                    let progress = JournalDayProgress(
                        startLocalDay: trip.startLocalDay,
                        dayLocalDay: day.localDay,
                        endLocalDay: trip.endLocalDay ?? JournalDayProgress.localDay(from: Date())
                    )
                    DayPostSection(
                        dayPost: day,
                        dayNumber: progress?.dayNumber ?? index + 1,
                        totalDays: progress?.totalDays ?? trip.days.count,
                        showsNewestFirst: trip.isCurrent,
                        showsActions: !trip.isUnassigned,
                        blogItemDestination: embedsNavigationStack ? nil : { item in
                            AnyView(
                                Self.makeDestinationView(
                                    for: .blogItem(item),
                                    trip: trip,
                                    weatherAttributionProvider: weatherAttributionProvider,
                                    currentLocationProvider: currentLocationProvider,
                                    reverseGeocodeProvider: reverseGeocodeProvider,
                                    historicalWeatherProvider: historicalWeatherProvider,
                                    onUpdate: onUpdate,
                                    onDelete: onDelete,
                                    onCreateEntryInGallery: onCreateEntryInGallery,
                                    onMoveItemsToGallery: onMoveItemsToGallery,
                                    onMoveItemOutOfGallery: onMoveItemOutOfGallery,
                                    onUpdateGallery: onUpdateGallery,
                                    onReorderGallery: onReorderGallery,
                                    onDeleteGallery: onDeleteGallery
                                )
                                .onAppear {
                                    onTripSubdetailVisibilityChange(true)
                                }
                                .onDisappear {
                                    onTripSubdetailVisibilityChange(false)
                                }
                            )
                        },
                        galleryDestination: embedsNavigationStack ? nil : { gallery in
                            AnyView(
                                Self.makeDestinationView(
                                    for: .gallery(gallery),
                                    trip: trip,
                                    weatherAttributionProvider: weatherAttributionProvider,
                                    currentLocationProvider: currentLocationProvider,
                                    reverseGeocodeProvider: reverseGeocodeProvider,
                                    historicalWeatherProvider: historicalWeatherProvider,
                                    onUpdate: onUpdate,
                                    onDelete: onDelete,
                                    onCreateEntryInGallery: onCreateEntryInGallery,
                                    onMoveItemsToGallery: onMoveItemsToGallery,
                                    onMoveItemOutOfGallery: onMoveItemOutOfGallery,
                                    onUpdateGallery: onUpdateGallery,
                                    onReorderGallery: onReorderGallery,
                                    onDeleteGallery: onDeleteGallery
                                )
                                .onAppear {
                                    onTripSubdetailVisibilityChange(true)
                                }
                                .onDisappear {
                                    onTripSubdetailVisibilityChange(false)
                                }
                            )
                        },
                        onAddGallery: { onAddGallery(day) },
                        onAddBlogItem: trip.isUnassigned ? nil : onAddBlogItem
                    )
                    .id(day.id)

                    if index > 0 {
                        Divider()
                    }
                }

                WeatherAttributionFooter(provider: weatherAttributionProvider)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .refreshable {
            await onRefresh()
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .scrollPosition($journalScrollPosition)
        .contentMargins(.top, 54, for: .scrollContent)
        .overlay(alignment: .top) {
            tripHeader
                .padding(.horizontal, 18)
                .padding(.top, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(!embedsNavigationStack ? .hidden : .automatic, for: .navigationBar)
    }

    private var displayedDays: [(offset: Int, element: DayPostDisplay)] {
        let enumeratedDays = Array(trip.days.enumerated())
        return trip.isCurrent ? Array(enumeratedDays.reversed()) : enumeratedDays
    }

    @ViewBuilder
    static func makeDestinationView(
        for destination: JournalDestination,
        trip: TripDisplay,
        weatherAttributionProvider: (any WeatherAttributing)?,
        currentLocationProvider: @escaping @MainActor () async throws -> CLLocationCoordinate2D,
        reverseGeocodeProvider: @escaping (CLLocationCoordinate2D) async throws -> String?,
        historicalWeatherProvider: @escaping (WeatherLocation, Date) async throws -> WeatherCapture?,
        onUpdate: @escaping (BlogItemUpdateRequest) -> Void,
        onDelete: @escaping (BlogItemDisplay) -> Void,
        onCreateEntryInGallery: @escaping (GalleryDisplay) -> Void,
        onMoveItemsToGallery: @escaping ([BlogItem.ID], Gallery.ID) -> Void,
        onMoveItemOutOfGallery: @escaping (BlogItem.ID) -> Void,
        onUpdateGallery: @escaping (GalleryDisplay) -> Void,
        onReorderGallery: @escaping (Gallery.ID, [BlogItem.ID]) -> Void,
        onDeleteGallery: @escaping (Gallery.ID, Bool) -> Void
    ) -> some View {
        switch destination {
        case .blogItem(let item):
            BlogItemDetailView(
                item: item,
                galleryDestinations: galleries(in: trip),
                weatherAttributionProvider: weatherAttributionProvider,
                currentLocationProvider: currentLocationProvider,
                reverseGeocodeProvider: reverseGeocodeProvider,
                historicalWeatherProvider: historicalWeatherProvider,
                onUpdate: onUpdate,
                onDelete: onDelete,
                onMoveToGallery: { item, galleryID in
                    onMoveItemsToGallery([item.id], galleryID)
                }
            )
        case .newBlogItem(let item):
            BlogItemDetailView(
                item: item,
                galleryDestinations: galleries(in: trip),
                weatherAttributionProvider: weatherAttributionProvider,
                currentLocationProvider: currentLocationProvider,
                reverseGeocodeProvider: reverseGeocodeProvider,
                historicalWeatherProvider: historicalWeatherProvider,
                onUpdate: onUpdate,
                onDelete: onDelete,
                onMoveToGallery: { item, galleryID in
                    onMoveItemsToGallery([item.id], galleryID)
                },
                deletesOnCancel: true
            )
        case .gallery(let gallery):
            GalleryDetailView(
                gallery: gallery,
                trip: trip,
                onCreateEntry: { onCreateEntryInGallery(gallery) },
                onMoveItems: { onMoveItemsToGallery($0, gallery.id) },
                onMoveItemToGallery: { itemID, galleryID in
                    onMoveItemsToGallery([itemID], galleryID)
                },
                onMoveItemOut: onMoveItemOutOfGallery,
                onUpdateItem: onUpdate,
                onDeleteItem: onDelete,
                onUpdate: onUpdateGallery,
                onReorder: { onReorderGallery(gallery.id, $0) },
                onDelete: { onDeleteGallery(gallery.id, $0) }
            )
        }
    }

    private static func galleries(in trip: TripDisplay) -> [GalleryDisplay] {
        trip.days
            .flatMap(\.entries)
            .compactMap {
                if case .gallery(let gallery) = $0 { gallery } else { nil }
            }
    }

    private var tripHeader: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 12) {
                if showsInlineBackButton {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .accessibilityLabel("Back")
                } else if let onOpenSidebar {
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
                } else if centersHeaderTitle && showsTripActions {
                    Color.clear
                        .frame(width: 44, height: 44)
                }

                Text(headerTitle)
                    .font(.system(size: compactTitleSize, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .accessibilityIdentifier("Trip title")
                    .frame(maxWidth: .infinity, alignment: titleAlignment)

                if showsTripActions {
                    Menu {
                        Button("Edit Trip Details", systemImage: "square.and.pencil", action: onEditTrip)
                        if showsEndTripAction {
                            Button("End This Trip", systemImage: "checkmark.circle", role: .destructive, action: onEndTrip)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .tint(AppColors.controlOrange)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .accessibilityLabel("Trip actions")
                } else if showsInlineBackButton {
                    Color.clear
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.leading, 0)
            .padding(.trailing, 18)
            .onChange(of: proxy.size) { _, _ in
                updateMenuLeadingPadding(animated: true)
            }
        }
        .frame(height: 52)
        .onAppear {
            updateMenuLeadingPadding(animated: false)
        }
    }

    private func updateMenuLeadingPadding(animated: Bool) {
        let newPadding = IPadWindowChrome.hasVisibleTrafficLights ? 60.0 : 0.0
        if animated {
            withAnimation(.easeInOut(duration: 0.5)) {
                menuLeadingPadding = newPadding
            }
        } else {
            menuLeadingPadding = newPadding
        }
    }

    private var showsInlineBackButton: Bool {
        !embedsNavigationStack
    }

    private var headerTitle: String {
        trip.isUnassigned ? "Unassigned entries" : trip.title
    }

    private var titleAlignment: Alignment {
        showsInlineBackButton || centersHeaderTitle ? .center : .leading
    }

    private var showsEndTripAction: Bool {
        embedsNavigationStack && trip.isCurrent
    }

    private var showsTripActions: Bool {
        !trip.isUnassigned
    }
}

struct BlogItemDetailView: View {
    private let originalItem: BlogItemDisplay
    private let weatherAttributionProvider: (any WeatherAttributing)?
    private let currentLocationProvider: @MainActor () async throws -> CLLocationCoordinate2D
    private let reverseGeocodeProvider: (CLLocationCoordinate2D) async throws -> String?
    private let historicalWeatherProvider: (WeatherLocation, Date) async throws -> WeatherCapture?
    private let onUpdate: (BlogItemUpdateRequest) -> Void
    private let onDelete: (BlogItemDisplay) -> Void
    private let onMoveOutOfGallery: ((BlogItemDisplay) -> Void)?
    private let galleryDestinations: [GalleryDisplay]
    private let onMoveToGallery: ((BlogItemDisplay, Gallery.ID) -> Void)?
    private let isNewItem: Bool
    private let deletesOnCancel: Bool
    private let allowsDeletion: Bool
    private let canSave: Bool
    private let isSaving: Bool
    private let dismissAfterSave: Bool
    private let initialPhotoDraft: BlogItemPhotoAssetDraft?
    private let initialPreviewImage: UIImage?

    @Environment(\.dismiss) private var dismiss
    @State private var caption: String
    @State private var date: Date
    @State private var location: String
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var temperature: Double
    @State private var temperatureText: String
    @State private var condition: String
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingReplacementPicker = false
    @State private var replacementPreviewImage: UIImage?
    @State private var replacementPhotoDraft: BlogItemPhotoAssetDraft?
    @State private var isPhotoRemoved = false
    @State private var photoActionErrorMessage: String?
    @State private var isLoadingReplacementPhoto = false
    @State private var selectedMapCoordinate: LocationPickerCoordinate?
    @State private var isLoadingLocationPicker = false
    @State private var isResolvingPlaceName = false
    @State private var isRefreshingHistoricalWeather = false
    @State private var locationActionErrorMessage: String?
    @State private var weatherActionErrorMessage: String?
    @State private var isShowingDatePickerSheet = false
    @State private var isShowingTimePickerSheet = false
    @State private var pendingHistoricalWeatherRefreshID = UUID()
    @FocusState private var focusedField: EditableField?

    private enum EditableField: Hashable {
        case caption
        case location
        case temperature
    }

    init(
        item: BlogItemDisplay,
        galleryDestinations: [GalleryDisplay] = [],
        weatherAttributionProvider: (any WeatherAttributing)? = nil,
        currentLocationProvider: @escaping @MainActor () async throws -> CLLocationCoordinate2D = {
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        },
        reverseGeocodeProvider: @escaping (CLLocationCoordinate2D) async throws -> String? = { _ in nil },
        historicalWeatherProvider: @escaping (WeatherLocation, Date) async throws -> WeatherCapture? = { _, _ in nil },
        onUpdate: @escaping (BlogItemUpdateRequest) -> Void = { _ in },
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in },
        onMoveOutOfGallery: ((BlogItemDisplay) -> Void)? = nil,
        onMoveToGallery: ((BlogItemDisplay, Gallery.ID) -> Void)? = nil,
        isNewItem: Bool = false,
        deletesOnCancel: Bool = false,
        allowsDeletion: Bool = true,
        canSave: Bool = true,
        isSaving: Bool = false,
        dismissAfterSave: Bool = true,
        initialPhotoDraft: BlogItemPhotoAssetDraft? = nil,
        initialPreviewImage: UIImage? = nil
    ) {
        originalItem = item
        self.weatherAttributionProvider = weatherAttributionProvider
        self.currentLocationProvider = currentLocationProvider
        self.reverseGeocodeProvider = reverseGeocodeProvider
        self.historicalWeatherProvider = historicalWeatherProvider
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onMoveOutOfGallery = onMoveOutOfGallery
        self.galleryDestinations = galleryDestinations
        self.onMoveToGallery = onMoveToGallery
        self.isNewItem = isNewItem
        self.deletesOnCancel = deletesOnCancel
        self.allowsDeletion = allowsDeletion
        self.canSave = canSave
        self.isSaving = isSaving
        self.dismissAfterSave = dismissAfterSave
        self.initialPhotoDraft = initialPhotoDraft
        self.initialPreviewImage = initialPreviewImage
        _caption = State(initialValue: item.caption)
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
        _replacementPhotoDraft = State(initialValue: initialPhotoDraft)
        _replacementPreviewImage = State(initialValue: initialPreviewImage)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                    photoEditor

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Caption")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $caption)
                            .font(.body)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                            .accessibilityIdentifier("BlogItem caption")
                            .focused($focusedField, equals: .caption)
                    }
                    .id(EditableField.caption)

                    dateTimeEditor

                    locationEditor

                    temperatureEditor

                    weatherConditionEditor

                    LabeledContent("Author", value: originalItem.author)
                        .foregroundStyle(.secondary)

                    Divider()

                    if let onMoveOutOfGallery {
                        Button("Move out of Gallery", systemImage: "arrow.up.forward.square") {
                            onMoveOutOfGallery(originalItem)
                            dismiss()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let onMoveToGallery, !galleryDestinations.isEmpty {
                        Menu {
                            ForEach(galleryDestinations) { gallery in
                                Button(gallery.title) {
                                    onMoveToGallery(originalItem, gallery.id)
                                    dismiss()
                                }
                            }
                        } label: {
                            Label(
                                onMoveOutOfGallery == nil
                                    ? "Move to Gallery"
                                    : "Move to Another Gallery",
                                systemImage: "rectangle.stack.badge.plus"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if allowsDeletion {
                        Button("Delete this entry", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    WeatherAttributionFooter(provider: weatherAttributionProvider)
            }
            .padding(18)
        }
        .keyboardAwareScroll(
            focusedField: $focusedField,
            contentField: .caption,
            contentChange: caption,
            scrollAnchor: { field in
                isNewItem && field == .caption ? .center : .bottom
            },
            scrollDuration: { field in
                isNewItem && field == .caption ? 0.35 : 0.25
            }
        )
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: focusedField) { _, field in
            if field != .temperature {
                normalizeTemperatureInput()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .disabled(isSaving)
        .navigationTitle(detailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $isShowingReplacementPicker) {
            SharedPhotoLibraryPicker { result in
                isShowingReplacementPicker = false
                switch result {
                case .success(.some(let selection)):
                    loadReplacementPhoto(from: selection)
                case .success(.none):
                    break
                case .failure:
                    photoActionErrorMessage = "The selected photo could not be loaded."
                }
            }
        }
        .alert(
            "This will permanently delete this entry. Are you sure?",
            isPresented: $isShowingDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                onDelete(originalItem)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Unable to update photo", isPresented: Binding(
            get: { photoActionErrorMessage != nil },
            set: { if !$0 { photoActionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoActionErrorMessage ?? "")
        }
        .alert("Unable to update location", isPresented: Binding(
            get: { locationActionErrorMessage != nil },
            set: { if !$0 { locationActionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(locationActionErrorMessage ?? "")
        }
        .alert("Unable to update weather", isPresented: Binding(
            get: { weatherActionErrorMessage != nil },
            set: { if !$0 { weatherActionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(weatherActionErrorMessage ?? "")
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
                            refreshHistoricalWeatherPreviewForCurrentSelection()
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
                            refreshHistoricalWeatherPreviewForCurrentSelection()
                        }
                    }
                }
            }
            .environment(\.timeZone, editingTimeZone)
            .presentationDetents([.medium])
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if deletesOnCancel {
                        onDelete(originalItem)
                    }
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Cancel")
                    }
                }
                .disabled(isSaving)
                .accessibilityLabel("Cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? "Saving..." : "Save") {
                    saveChanges()
                    if dismissAfterSave {
                        dismiss()
                    }
                }
                .disabled(isSaving || !canSave || !hasSaveContent)
                .accessibilityLabel("Save")
            }
        }
        .task {
            guard isNewItem else { return }
            focusedField = .caption
            await loadInitialEditorDetails()
        }
    }

    private var photoEditor: some View {
        photoEditorContent
    }

    private var locationEditor: some View {
        JournalLocationEditor(
            location: $location,
            isLoading: isLoadingLocationPicker,
            isResolving: isResolvingPlaceName,
            onAdjustLocation: presentLocationPicker,
            accessibilityIdentifier: "BlogItem location"
        )
        .id(EditableField.location)
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
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
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
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
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

    private var temperatureEditor: some View {
        JournalTemperatureEditor(
            temperature: $temperature,
            temperatureText: $temperatureText,
            onTemperatureChange: { temperature = $0 }
        )
        .id(EditableField.temperature)
    }

    private var weatherConditionEditor: some View {
        JournalWeatherConditionEditor(
            condition: $condition,
            isLoading: isRefreshingHistoricalWeather,
            accessibilityIdentifier: "BlogItem weather condition"
        )
    }

    private var selectedWeatherConditionDescription: String {
        condition.isEmpty ? "Unknown" : WeatherConditionCatalog.description(for: condition)
    }

    private var selectedWeatherConditionSystemImage: String {
        condition.isEmpty ? "questionmark.circle" : WeatherConditionCatalog.systemImage(for: condition)
    }

    @ViewBuilder
    private var photoEditorContent: some View {
        if isLoadingInitialPhoto {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                ProgressView("Loading photo")
                    .tint(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 270)
            .overlay(alignment: .topTrailing) {
                photoActionsMenu
            }
        } else if let previewImage = replacementPreviewImage ?? initialPreviewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFit()
                .overlay(alignment: .topTrailing) {
                    photoActionsMenu
                }
                .overlay {
                    replacementProgressOverlay
                }
                .clipShape(.rect(cornerRadius: 24))
                .frame(maxWidth: .infinity)
        } else if isPhotoRemoved {
            emptyPhotoPlaceholder
                .overlay(alignment: .topTrailing) {
                    photoActionsMenu
                }
                .overlay {
                    replacementProgressOverlay
                }
                .clipShape(.rect(cornerRadius: 24))
        } else if let localImagePath = originalItem.localImagePath,
           let image = UIImage(contentsOfFile: localImagePath) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay(alignment: .topTrailing) {
                    photoActionsMenu
                }
                .overlay {
                    replacementProgressOverlay
                }
                .clipShape(.rect(cornerRadius: 24))
                .frame(maxWidth: .infinity)
        } else if originalItem.palette != nil {
            JournalPhotoSurface(item: originalItem)
                .frame(maxWidth: .infinity, minHeight: 270)
                .overlay(alignment: .topTrailing) {
                    photoActionsMenu
                }
                .overlay {
                    replacementProgressOverlay
                }
                .clipShape(.rect(cornerRadius: 24))
        } else {
            emptyPhotoPlaceholder
            .overlay(alignment: .topTrailing) {
                photoActionsMenu
            }
            .overlay {
                replacementProgressOverlay
            }
            .clipShape(.rect(cornerRadius: 24))
        }
    }

    private var emptyPhotoPlaceholder: some View {
        Button {
            isShowingReplacementPicker = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 90, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 270)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("BlogItem photo placeholder")
        .accessibilityLabel("Add photo")
    }

    private var isLoadingInitialPhoto: Bool {
        isNewItem
            && initialPhotoDraft != nil
            && replacementPreviewImage == nil
            && initialPreviewImage == nil
            && !isPhotoRemoved
    }

    private var photoActionsMenu: some View {
        Menu {
            Button(hasEditablePhoto ? "Replace Photo" : "Add Photo", systemImage: "photo.badge.arrow.down") {
                isShowingReplacementPicker = true
            }
            Button("Remove Photo", systemImage: "trash", role: .destructive) {
                replacementPhotoDraft = nil
                replacementPreviewImage = nil
                isPhotoRemoved = true
            }
            .disabled(!hasEditablePhoto)
        } label: {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .padding(8)
        .disabled(isLoadingReplacementPhoto)
        .accessibilityLabel("Photo actions")
    }

    private var hasEditablePhoto: Bool {
        replacementPreviewImage != nil
            || initialPreviewImage != nil
            || replacementPhotoDraft != nil
            || originalItem.localImagePath != nil
            || originalItem.hasPhoto
    }

    private var hasSaveContent: Bool {
        hasEditablePhoto
            || !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var replacementProgressOverlay: some View {
        if isLoadingReplacementPhoto {
            ProgressView()
                .padding(18)
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
    }

    private func editableField(
        _ title: String,
        text: Binding<String>,
        systemImage: String
    ) -> some View {
        Label {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }

    private func saveChanges() {
        let photoChange: BlogItemPhotoChange
        if let replacementPhotoDraft {
            photoChange = .replaced(replacementPhotoDraft)
        } else if isPhotoRemoved {
            photoChange = .removed
        } else {
            photoChange = .unchanged
        }

        onUpdate(
            BlogItemUpdateRequest(
                id: originalItem.id,
                caption: caption,
                date: date,
                location: location,
                latitude: latitude,
                longitude: longitude,
                temperatureCelsius: temperature,
                weatherCondition: condition.isEmpty ? nil : condition,
                photoChange: photoChange
            )
        )
    }

    private var detailTitle: String {
        let place = location
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        var item = originalItem
        item.date = date
        let dateTime = item.metadataDateTimeText()
        return place.isEmpty ? dateTime : "\(place): \(dateTime)"
    }

    private func updateTemperature(to newValue: Double) {
        let normalizedValue = TemperatureValue.normalized(newValue)
        temperature = normalizedValue
        temperatureText = Self.temperatureText(for: normalizedValue)
    }

    private func syncTemperature(from rawValue: String) {
        if rawValue.isEmpty || rawValue == "-" {
            return
        }

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

        guard let parsedValue = Double(normalized) else { return }
        temperature = parsedValue
    }

    private func normalizeTemperatureInput() {
        guard let parsedValue = Double(temperatureText) else {
            updateTemperature(to: temperature)
            return
        }
        updateTemperature(to: parsedValue)
    }

    private static func temperatureText(for value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func presentLocationPicker() {
        if let selectedMapCoordinate {
            self.selectedMapCoordinate = selectedMapCoordinate
            return
        }

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
                await MainActor.run {
                    selectedMapCoordinate = LocationPickerCoordinate(coordinate: coordinate)
                    isLoadingLocationPicker = false
                }
            } catch {
                await MainActor.run {
                    isLoadingLocationPicker = false
                    locationActionErrorMessage = "The current location could not be loaded."
                }
            }
        }
    }

    private func loadInitialEditorDetails() async {
        var coordinate: CLLocationCoordinate2D?
        if let latitude, let longitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            do {
                coordinate = try await currentLocationProvider()
            } catch {
                return
            }
        }

        guard let coordinate else { return }
        latitude = coordinate.latitude
        longitude = coordinate.longitude

        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                if let placeName = try await reverseGeocodeProvider(coordinate), !placeName.isEmpty {
                    location = placeName
                }
            } catch {
                // Weather and location remain editable if reverse geocoding fails.
            }
        }

        refreshHistoricalWeatherPreview(
            for: WeatherLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            date: date
        )
    }

    private func applySelectedMapCoordinate(_ coordinate: CLLocationCoordinate2D) {
        selectedMapCoordinate = nil
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        isResolvingPlaceName = true

        Task {
            do {
                let placeName = try await reverseGeocodeProvider(coordinate)
                await MainActor.run {
                    if let placeName, !placeName.isEmpty {
                        location = placeName
                    }
                    isResolvingPlaceName = false
                    refreshHistoricalWeatherPreview(
                        for: WeatherLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                        date: date
                    )
                }
            } catch {
                await MainActor.run {
                    isResolvingPlaceName = false
                    locationActionErrorMessage = "The selected location could not be reverse geocoded."
                    refreshHistoricalWeatherPreview(
                        for: WeatherLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                        date: date
                    )
                }
            }
        }
    }

    private func loadReplacementPhoto(from selection: SharedPhotoLibrarySelection) {
        isLoadingReplacementPhoto = true
        Task {
            do {
                let data = selection.data
                guard let previewImage = await Self.makePreviewImage(from: data) else {
                    throw BlogItemPhotoActionError.previewUnavailable
                }
                let pixelSize = Self.pixelSize(from: data)
                await MainActor.run {
                    replacementPhotoDraft = BlogItemPhotoAssetDraft(
                        imageData: data,
                        mimeType: selection.mimeType,
                        photoLibraryAssetIdentifier: selection.assetIdentifier,
                        pixelWidth: pixelSize.width,
                        pixelHeight: pixelSize.height
                    )
                    replacementPreviewImage = previewImage
                    isPhotoRemoved = false
                    isLoadingReplacementPhoto = false
                }
            } catch {
                await MainActor.run {
                    isLoadingReplacementPhoto = false
                    photoActionErrorMessage = "The selected photo could not be loaded."
                }
            }
        }
    }

    private static func makePreviewImage(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }

    private static func pixelSize(from data: Data) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        return (
            properties[kCGImagePropertyPixelWidth] as? Int,
            properties[kCGImagePropertyPixelHeight] as? Int
        )
    }

    private func refreshHistoricalWeatherPreviewForCurrentSelection() {
        guard let latitude, let longitude else { return }
        refreshHistoricalWeatherPreview(
            for: WeatherLocation(latitude: latitude, longitude: longitude),
            date: date
        )
    }

    private func refreshHistoricalWeatherPreview(for location: WeatherLocation, date: Date) {
        let refreshID = UUID()
        pendingHistoricalWeatherRefreshID = refreshID
        isRefreshingHistoricalWeather = true

        Task {
            do {
                let weather = try await historicalWeatherProvider(location, date)
                await MainActor.run {
                    guard pendingHistoricalWeatherRefreshID == refreshID else { return }
                    isRefreshingHistoricalWeather = false
                    if let weather {
                        updateTemperature(to: Double(weather.temperatureCelsius))
                        condition = weather.conditionCode
                    }
                }
            } catch {
                await MainActor.run {
                    guard pendingHistoricalWeatherRefreshID == refreshID else { return }
                    isRefreshingHistoricalWeather = false
                    weatherActionErrorMessage = "The weather for this place and time could not be loaded."
                }
            }
        }
    }
}

private struct LocationPickerCoordinate: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

private enum BlogItemPhotoActionError: Error {
    case invalidSelection
    case previewUnavailable
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

private struct WeatherAttributionFooter: View {
    let provider: (any WeatherAttributing)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution: WeatherAttributionDisplay?

    var body: some View {
        Group {
            if let attribution {
                Link(destination: attribution.legalPageURL) {
                    HStack(spacing: 10) {
                        AsyncImage(url: colorScheme == .dark ? attribution.combinedMarkDarkURL : attribution.combinedMarkLightURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            default:
                                Text(attribution.legalAttributionText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 92, height: 18, alignment: .leading)

                        Text("Weather data source")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Weather attribution")
                .accessibilityHint("Opens the Apple Weather legal attribution page")
            }
        }
        .task {
            guard let provider else { return }
            attribution = try? await provider.attribution()
        }
    }
}

struct GalleryDetailView: View {
    let gallery: GalleryDisplay
    let trip: TripDisplay
    let onCreateEntry: () -> Void
    let onMoveItems: ([BlogItem.ID]) -> Void
    let onMoveItemToGallery: (BlogItem.ID, Gallery.ID) -> Void
    let onMoveItemOut: (BlogItem.ID) -> Void
    let onUpdateItem: (BlogItemUpdateRequest) -> Void
    let onDeleteItem: (BlogItemDisplay) -> Void
    let onUpdate: (GalleryDisplay) -> Void
    let onReorder: ([BlogItem.ID]) -> Void
    let onDelete: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isShowingMovePicker = false
    @State private var isEditingDetails = false
    @State private var isEditingOrder = false
    @State private var isDeleting = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(gallery.items.count) photos")
                        .font(.title2.weight(.bold))
                    Text(timeRange)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(gallery.location, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(AppColors.locationGreen)
                    if !gallery.description.isEmpty {
                        Text(gallery.description)
                            .font(.body)
                            .padding(.top, 8)
                    }
                }
                .accessibilityElement(children: .combine)

                if gallery.items.isEmpty {
                    ContentUnavailableView {
                        Label("Empty Gallery", systemImage: "rectangle.stack")
                    } description: {
                        Text("Add a new entry or move entries from this Trip.")
                    } actions: {
                        Button("Add Entry", systemImage: "plus", action: onCreateEntry)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(gallery.items) { item in
                        NavigationLink {
                            BlogItemDetailView(
                                item: item,
                                galleryDestinations: otherGalleries,
                                onUpdate: onUpdateItem,
                                onDelete: onDeleteItem,
                                onMoveOutOfGallery: {
                                    onMoveItemOut($0.id)
                                },
                                onMoveToGallery: { item, destinationGalleryID in
                                    onMoveItemToGallery(item.id, destinationGalleryID)
                                }
                            )
                        } label: {
                            BlogItemCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(gallery.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Create New Entry", systemImage: "camera", action: onCreateEntry)
                    Button("Move Existing Entries", systemImage: "arrow.right.square") {
                        isShowingMovePicker = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Gallery entry")

                Menu {
                    Button("Edit Gallery Details", systemImage: "square.and.pencil") {
                        isEditingDetails = true
                    }
                    Button("Edit Order", systemImage: "arrow.up.arrow.down") {
                        isEditingOrder = true
                    }
                    .disabled(gallery.items.count < 2)
                    Button("Delete Gallery", systemImage: "trash", role: .destructive) {
                        isDeleting = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(AppColors.controlOrange)
                .accessibilityLabel("Gallery actions")
            }
        }
        .sheet(isPresented: $isShowingMovePicker) {
            GalleryEntryPicker(
                gallery: gallery,
                trip: trip,
                onCancel: { isShowingMovePicker = false },
                onMove: {
                    onMoveItems($0)
                    isShowingMovePicker = false
                }
            )
        }
        .sheet(isPresented: $isEditingDetails) {
            GalleryDetailsEditor(
                gallery: gallery,
                onCancel: { isEditingDetails = false },
                onSave: {
                    onUpdate($0)
                    isEditingDetails = false
                }
            )
        }
        .sheet(isPresented: $isEditingOrder) {
            GalleryOrderEditor(
                gallery: gallery,
                onCancel: { isEditingOrder = false },
                onSave: {
                    onReorder($0)
                    isEditingOrder = false
                }
            )
        }
        .sheet(isPresented: $isDeleting) {
            GalleryDeletionSheet(
                entryCount: gallery.items.count,
                onCancel: { isDeleting = false },
                onDelete: { deletingEntries in
                    onDelete(deletingEntries)
                    isDeleting = false
                    dismiss()
                }
            )
        }
    }

    private var otherGalleries: [GalleryDisplay] {
        trip.days
            .flatMap(\.entries)
            .compactMap {
                guard case .gallery(let candidate) = $0, candidate.id != gallery.id else {
                    return nil
                }
                return candidate
            }
    }

    private var timeRange: String {
        guard let first = gallery.items.first,
              let last = gallery.items.last else {
            return ""
        }
        return "\(first.localTimeText())–\(last.localTimeText())"
    }
}

private struct GalleryEntryCandidate: Identifiable {
    let item: BlogItemDisplay
    let localDay: String

    var id: BlogItem.ID { item.id }
}

private struct GalleryEntryPicker: View {
    let gallery: GalleryDisplay
    let trip: TripDisplay
    let onCancel: () -> Void
    let onMove: ([BlogItem.ID]) -> Void

    @State private var selection = Set<BlogItem.ID>()
    @State private var isConfirmingCrossDayMove = false

    private var candidates: [GalleryEntryCandidate] {
        trip.days.flatMap { day in
            day.entries.flatMap { entry -> [GalleryEntryCandidate] in
                switch entry {
                case .blogItem(let item):
                    return [GalleryEntryCandidate(item: item, localDay: day.localDay)]
                case .gallery:
                    return []
                }
            }
        }
        .sorted { $0.item.date > $1.item.date }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates) { candidate in
                    Button {
                        if !selection.insert(candidate.id).inserted {
                            selection.remove(candidate.id)
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            JournalPhotoSurface(item: candidate.item, scaling: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(.rect(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 6) {
                                Text(candidate.item.caption.isEmpty ? "Untitled entry" : candidate.item.caption)
                                    .foregroundStyle(.black)
                                    .lineLimit(2)

                                Spacer(minLength: 0)

                                Text(candidateMetadata(candidate.item))
                                    .font(.footnote)
                                    .foregroundColor(
                                        candidate.localDay == gallery.localDay ? .green : .orange
                                    )
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)

                            Spacer()
                            if selection.contains(candidate.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move Entries")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        let crossesDay = candidates.contains {
                            selection.contains($0.id) && $0.localDay != gallery.localDay
                        }
                        if crossesDay {
                            isConfirmingCrossDayMove = true
                        } else {
                            onMove(Array(selection))
                        }
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .alert("Move entries to \(gallery.localDay ?? "this Gallery’s day")?", isPresented: $isConfirmingCrossDayMove) {
                Button("Move") { onMove(Array(selection)) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Their Journal day will change, but their original capture dates will be preserved.")
            }
        }
    }

    private func candidateMetadata(_ item: BlogItemDisplay) -> String {
        let dateTime = item.metadataDateTimeText()
        return item.location.isEmpty ? dateTime : "\(dateTime) · \(item.location)"
    }
}

private struct JournalLocationEditor: View {
    @Binding var location: String
    let isLoading: Bool
    let isResolving: Bool
    let onAdjustLocation: (() -> Void)?
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            if let onAdjustLocation {
                Button(action: onAdjustLocation) { locationIcon }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Adjust location on map")
            } else {
                locationIcon
            }
            TextField("Location", text: $location)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var locationIcon: some View {
        Group {
            if isLoading || isResolving { ProgressView().frame(width: 18, height: 18) }
            else { Image(systemName: "mappin.and.ellipse").font(.system(size: 17, weight: .semibold)) }
        }
        .foregroundStyle(AppColors.locationGreen)
        .frame(width: 32, height: 32)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .circle)
    }
}

private struct JournalTemperatureEditor: View {
    @Binding var temperature: Double
    @Binding var temperatureText: String
    let onTemperatureChange: (Double) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 0) {
                Button { updateTemperature(to: temperature - 1) } label: {
                    Image(systemName: "minus").font(.headline.weight(.semibold))
                        .frame(width: 44, height: 42)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(.rect(topLeadingRadius: 16, bottomLeadingRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(temperature <= TemperatureValue.minimumCelsius)
                .accessibilityLabel("Decrease temperature")

                TextField("Temperature", text: $temperatureText)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .frame(width: 72, height: 42)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .accessibilityIdentifier("BlogItem temperature")
                    .onChange(of: temperatureText) { _, newValue in syncTemperature(from: newValue) }
                    .onSubmit { normalizeTemperatureInput() }

                Button { updateTemperature(to: temperature + 1) } label: {
                    Image(systemName: "plus").font(.headline.weight(.semibold))
                        .frame(width: 44, height: 42)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(.rect(bottomTrailingRadius: 16, topTrailingRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(temperature >= TemperatureValue.maximumCelsius)
                .accessibilityLabel("Increase temperature")
            }
        } label: { Text("Temperature (°C)") }
    }

    private func updateTemperature(to value: Double) {
        let normalized = TemperatureValue.normalized(value)
        temperature = normalized
        temperatureText = normalized.formatted(.number.precision(.fractionLength(0...1)))
        onTemperatureChange(normalized)
    }

    private func syncTemperature(from rawValue: String) {
        guard !rawValue.isEmpty, rawValue != "-" else { return }
        var normalized = ""
        for character in rawValue {
            if character.isNumber { normalized.append(character) }
            else if character == "-" && normalized.isEmpty { normalized.append(character) }
            else if character == "." && !normalized.contains(".") { normalized.append(character) }
        }
        guard normalized == rawValue else { temperatureText = normalized; return }
        if let value = Double(normalized) {
            temperature = value
            onTemperatureChange(value)
        }
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
    let isLoading: Bool
    let accessibilityIdentifier: String

    var body: some View {
        LabeledContent {
            Menu {
                Button { condition = "" } label: { Label("Unknown", systemImage: "questionmark.circle") }
                ForEach(WeatherConditionCatalog.supportedConditions, id: \.rawValue) { weatherCondition in
                    Button { condition = weatherCondition.rawValue } label: {
                        Label(WeatherConditionCatalog.description(for: weatherCondition.rawValue),
                              systemImage: WeatherConditionCatalog.systemImage(for: weatherCondition.rawValue))
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: condition.isEmpty ? "questionmark.circle" : WeatherConditionCatalog.systemImage(for: condition))
                        .foregroundStyle(.secondary)
                    Text(condition.isEmpty ? "Unknown" : WeatherConditionCatalog.description(for: condition))
                        .foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).frame(minHeight: 42)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityIdentifier)
            .overlay(alignment: .trailing) {
                if isLoading { ProgressView().controlSize(.small).padding(.trailing, 34) }
            }
        } label: { Text("Weather\nconditions").fixedSize(horizontal: false, vertical: true) }
    }
}

private struct KeyboardAwareScrollModifier<Field: Hashable, Change: Equatable>: ViewModifier {
    @FocusState.Binding private var focusedField: Field?
    private let contentField: Field
    private let contentChange: Change
    private let scrollAnchor: (Field) -> UnitPoint
    private let scrollDuration: (Field) -> Double

    init(
        focusedField: FocusState<Field?>.Binding,
        contentField: Field,
        contentChange: Change,
        scrollAnchor: @escaping (Field) -> UnitPoint,
        scrollDuration: @escaping (Field) -> Double
    ) {
        _focusedField = focusedField
        self.contentField = contentField
        self.contentChange = contentChange
        self.scrollAnchor = scrollAnchor
        self.scrollDuration = scrollDuration
    }

    func body(content: Content) -> some View {
        ScrollViewReader { scrollProxy in
            content
                .onChange(of: focusedField) { _, field in
                    guard let field else { return }
                    scrollTo(field, using: scrollProxy)
                }
                .onChange(of: contentChange) { _, _ in
                    guard focusedField == contentField else { return }
                    scrollTo(contentField, using: scrollProxy)
                }
        }
    }

    private func scrollTo(_ field: Field, using scrollProxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: scrollDuration(field))) {
                scrollProxy.scrollTo(field, anchor: scrollAnchor(field))
            }
        }
    }
}

private extension View {
    func keyboardAwareScroll<Field: Hashable, Change: Equatable>(
        focusedField: FocusState<Field?>.Binding,
        contentField: Field,
        contentChange: Change,
        scrollAnchor: @escaping (Field) -> UnitPoint = { _ in .bottom },
        scrollDuration: @escaping (Field) -> Double = { _ in 0.25 }
    ) -> some View {
        modifier(
            KeyboardAwareScrollModifier(
                focusedField: focusedField,
                contentField: contentField,
                contentChange: contentChange,
                scrollAnchor: scrollAnchor,
                scrollDuration: scrollDuration
            )
        )
    }
}

private struct GalleryDetailsEditor: View {
    let gallery: GalleryDisplay
    let onCancel: () -> Void
    let onSave: (GalleryDisplay) -> Void

    @State private var draft: GalleryDisplay
    @State private var temperature: Double
    @State private var temperatureText: String
    @State private var hasTemperature: Bool
    @FocusState private var focusedField: EditableField?

    private enum EditableField: Hashable {
        case description
    }

    init(
        gallery: GalleryDisplay,
        onCancel: @escaping () -> Void,
        onSave: @escaping (GalleryDisplay) -> Void
    ) {
        self.gallery = gallery
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: gallery)
        let initialTemperature = gallery.weather.temperatureCelsius ?? 0
        _temperature = State(initialValue: initialTemperature)
        _temperatureText = State(initialValue: initialTemperature.formatted(.number.precision(.fractionLength(0...1))))
        _hasTemperature = State(initialValue: gallery.weather.temperatureCelsius != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                        TextField("Title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Description")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $draft.description)
                                .font(.body)
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                                .focused($focusedField, equals: .description)
                        }
                        .id(EditableField.description)

                        JournalLocationEditor(
                            location: $draft.location,
                            isLoading: false,
                            isResolving: false,
                            onAdjustLocation: nil,
                            accessibilityIdentifier: "Gallery location"
                        )

                        JournalTemperatureEditor(
                            temperature: $temperature,
                            temperatureText: $temperatureText,
                            onTemperatureChange: { _ in hasTemperature = true }
                        )

                        JournalWeatherConditionEditor(
                            condition: Binding(
                                get: { draft.weather.conditionCode ?? "" },
                                set: { draft.weather.conditionCode = $0.isEmpty ? nil : $0 }
                            ),
                            isLoading: false,
                            accessibilityIdentifier: "Gallery weather condition"
                        )
                }
                .padding(18)
            }
            .keyboardAwareScroll(
                focusedField: $focusedField,
                contentField: .description,
                contentChange: draft.description
            )
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Edit Gallery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.weather.temperatureCelsius = hasTemperature ? temperature : nil
                        onSave(draft)
                    }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

}

private struct GalleryOrderEditor: View {
    let gallery: GalleryDisplay
    let onCancel: () -> Void
    let onSave: ([BlogItem.ID]) -> Void

    @State private var items: [BlogItemDisplay]

    init(
        gallery: GalleryDisplay,
        onCancel: @escaping () -> Void,
        onSave: @escaping ([BlogItem.ID]) -> Void
    ) {
        self.gallery = gallery
        self.onCancel = onCancel
        self.onSave = onSave
        _items = State(initialValue: gallery.items)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Text(item.caption.isEmpty ? "Untitled entry" : item.caption)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Order")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(items.map(\.id)) }
                }
            }
        }
    }
}

private struct GalleryDeletionSheet: View {
    let entryCount: Int
    let onCancel: () -> Void
    let onDelete: (Bool) -> Void

    @State private var deletesEntries = false

    var body: some View {
        NavigationStack {
            Form {
                if entryCount > 0 {
                    Toggle("Also delete all entries", isOn: $deletesEntries)
                    Text("Entries you keep will appear individually in the Journal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Delete Gallery", role: .destructive) {
                    onDelete(deletesEntries)
                }
            }
            .navigationTitle("Delete Gallery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

nonisolated struct GalleryCreationDraft {
    var title: String
    var description: String
    var placementDate: Date
    var timeZoneIdentifier: String?
    var location: String
    var temperatureCelsius: Double?
    var weatherConditionCode: String?
}

struct GalleryCreationSheet: View {
    let day: DayPostDisplay
    let onCancel: () -> Void
    let onSave: (GalleryCreationDraft) -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var placementDate: Date
    @State private var location = ""
    @State private var temperatureCelsius: Double?
    @State private var weatherConditionCode = ""

    init(
        day: DayPostDisplay,
        onCancel: @escaping () -> Void,
        onSave: @escaping (GalleryCreationDraft) -> Void
    ) {
        self.day = day
        self.onCancel = onCancel
        self.onSave = onSave
        _placementDate = State(initialValue: day.date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gallery") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Placement") {
                    LabeledContent("Day", value: day.localDay)
                    DatePicker(
                        "Time",
                        selection: $placementDate,
                        displayedComponents: .hourAndMinute
                    )
                }
                Section("Optional details") {
                    TextField("Location", text: $location)
                    TextField(
                        "Temperature",
                        value: $temperatureCelsius,
                        format: .number
                    )
                    TextField("Weather condition", text: $weatherConditionCode)
                }
            }
            .navigationTitle("New Gallery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onSave(
                            GalleryCreationDraft(
                                title: title,
                                description: description,
                                placementDate: placementDate,
                                timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                                location: location,
                                temperatureCelsius: temperatureCelsius,
                                weatherConditionCode: weatherConditionCode.isEmpty
                                    ? nil
                                    : weatherConditionCode
                            )
                        )
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

#Preview("Journal") {
    JournalView(trip: DevelopmentSampleData.currentTrip)
}

#Preview("BlogItem detail") {
    NavigationStack {
        BlogItemDetailView(
            item: DevelopmentSampleData.currentTrip.days[1].entries.compactMap {
                if case .blogItem(let item) = $0 { item } else { nil }
            }[0]
        )
    }
}
