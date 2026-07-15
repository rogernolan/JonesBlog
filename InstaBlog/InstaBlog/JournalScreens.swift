import SwiftUI
import UIKit
import ImageIO
import MapKit
import CoreLocation
import WeatherKit

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
    let onEditTrip: () -> Void
    let onEndTrip: () -> Void
    let embedsNavigationStack: Bool
    let centersHeaderTitle: Bool
    let onOpenSidebar: (() -> Void)?
    let onTripSubdetailVisibilityChange: (Bool) -> Void
    @Binding var path: [JournalDestination]

    @Environment(\.dismiss) private var dismiss

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
        .safeAreaInset(edge: .top) { tripHeader.padding(.horizontal, 18) }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(!embedsNavigationStack ? .hidden : .automatic, for: .navigationBar)
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
            .onAppear { onTripSubdetailVisibilityChange(true) }
        }
    }

    private var tripHeader: some View {
        HStack(spacing: 12) {
            if let onOpenSidebar {
                Button(action: onOpenSidebar) {
                    Image(systemName: "sidebar.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open sidebar")
            } else if embedsNavigationStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
            }
            Text(trip.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: centersHeaderTitle ? .center : .leading)
                .lineLimit(1)
            if !trip.isUnassigned {
                Menu {
                    Button("Edit Trip", systemImage: "square.and.pencil", action: onEditTrip)
                    if trip.isCurrent {
                        Button("End Trip", systemImage: "flag.checkered", action: onEndTrip)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Trip actions")
            }
        }
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
    }
}

struct BlogItemDetailView: View {
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
    @State private var condition: String
    @State private var photos: [EditablePhoto]
    @State private var isShowingPhotoPicker = false
    @State private var isShowingDeleteConfirmation = false
    @State private var errorMessage: String?
    @State private var hasLoadedInitialMetadata = false

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
            }

            Section("Details") {
                DatePicker("Date and time", selection: $date)
                TextField("Location", text: $location)
                LabeledContent("Temperature") {
                    TextField("°C", value: $temperature, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                }
                TextField("Weather condition", text: $condition)
                LabeledContent("Author", value: originalItem.author)
            }

            if allowsDeletion && !isNewItem {
                Section {
                    Button("Delete Post", systemImage: "trash", role: .destructive) {
                        isShowingDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(location.isEmpty ? "Post" : location)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.disabled(isSaving)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSaving ? "Saving…" : "Save") { save() }
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
        .confirmationDialog("Delete this post?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete Post", role: .destructive) {
                onDelete(originalItem)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Photo Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await loadInitialMetadataIfNeeded()
        }
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
        location = (try? await reverseGeocodeProvider(coordinate)) ?? ""
        if let weather = try? await historicalWeatherProvider(
            WeatherLocation(latitude: latitude, longitude: longitude),
            draft.photoDate
        ) {
            temperature = Double(weather.temperatureCelsius)
            condition = weather.conditionCode
        }
    }

    private func loadInitialMetadataIfNeeded() async {
        guard isNewItem, !hasLoadedInitialMetadata else { return }
        hasLoadedInitialMetadata = true

        var coordinate = latitude.flatMap { latitude in
            longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
        }
        if coordinate == nil, usesCurrentLocationForNewItem {
            coordinate = try? await currentLocationProvider()
        }
        guard let coordinate else { return }

        latitude = coordinate.latitude
        longitude = coordinate.longitude
        if location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let resolvedLocation = try? await reverseGeocodeProvider(coordinate) {
            location = resolvedLocation
        }
        if let weather = try? await historicalWeatherProvider(
            WeatherLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            date
        ) {
            temperature = Double(weather.temperatureCelsius)
            condition = weather.conditionCode
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
