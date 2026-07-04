import SwiftUI
import UIKit
import PhotosUI
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
    let onUpdate: (BlogItemUpdateRequest) -> Void
    let onDelete: (BlogItemDisplay) -> Void
    let onEditTrip: () -> Void
    let onEndTrip: () -> Void
    @Binding var path: [JournalDestination]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var expandedTitleSize = 34.0
    @ScaledMetric(relativeTo: .headline) private var compactTitleSize = 17.0
    @State private var titleProgress = 0.0
    @State private var titleWidth = 0.0

    init(
        trip: TripDisplay,
        weatherAttributionProvider: (any WeatherAttributing)? = nil,
        currentLocationProvider: @escaping @MainActor () async throws -> CLLocationCoordinate2D = {
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        },
        reverseGeocodeProvider: @escaping (CLLocationCoordinate2D) async throws -> String? = { _ in nil },
        historicalWeatherProvider: @escaping (WeatherLocation, Date) async throws -> WeatherCapture? = { _, _ in nil },
        path: Binding<[JournalDestination]> = .constant([]),
        onUpdate: @escaping (BlogItemUpdateRequest) -> Void = { _ in },
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in },
        onEditTrip: @escaping () -> Void = {},
        onEndTrip: @escaping () -> Void = {}
    ) {
        self.trip = trip
        self.weatherAttributionProvider = weatherAttributionProvider
        self.currentLocationProvider = currentLocationProvider
        self.reverseGeocodeProvider = reverseGeocodeProvider
        self.historicalWeatherProvider = historicalWeatherProvider
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onEditTrip = onEditTrip
        self.onEndTrip = onEndTrip
        _path = path
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(Array(trip.days.enumerated().reversed()), id: \.element.id) { index, day in
                        let progress = JournalDayProgress(
                            startLocalDay: trip.startLocalDay,
                            dayLocalDay: day.localDay,
                            endLocalDay: trip.endLocalDay ?? JournalDayProgress.localDay(from: Date())
                        )
                        DayPostSection(
                            dayPost: day,
                            dayNumber: progress?.dayNumber ?? index + 1,
                            totalDays: progress?.totalDays ?? trip.days.count
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
            .contentMargins(.top, 54, for: .scrollContent)
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, scrollOffset in
                let progress = TripTitleTransition.progress(
                    scrollOffset: scrollOffset,
                    collapseDistance: 64
                )
                titleProgress = reduceMotion ? (progress < 0.5 ? 0 : 1) : progress
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    tripTitle(in: geometry.size.width)
                }
                .allowsHitTesting(false)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !trip.isUnassigned {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Edit Trip Details", systemImage: "square.and.pencil", action: onEditTrip)
                            Button("End This Trip", systemImage: "checkmark.circle", role: .destructive, action: onEndTrip)
                                .disabled(!trip.isCurrent)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Trip actions")
                    }
                }
            }
            .navigationDestination(for: JournalDestination.self) { destination in
                switch destination {
                case .blogItem(let item):
                    BlogItemDetailView(
                        item: item,
                        weatherAttributionProvider: weatherAttributionProvider,
                        currentLocationProvider: currentLocationProvider,
                        reverseGeocodeProvider: reverseGeocodeProvider,
                        historicalWeatherProvider: historicalWeatherProvider,
                        onUpdate: onUpdate,
                        onDelete: onDelete
                    )
                case .gallery(let gallery):
                    GalleryDetailView(gallery: gallery)
                }
            }
        }
    }

    private func tripTitle(in availableWidth: CGFloat) -> some View {
        let progress = CGFloat(titleProgress)
        let fontSize = expandedTitleSize + ((compactTitleSize - expandedTitleSize) * progress)
        let expandedX = 18.0
        let compactX = max((availableWidth - titleWidth) / 2, expandedX)

        return Text(trip.title)
            .font(.system(size: fontSize, weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("Trip title")
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                titleWidth = width
            }
            .offset(
                x: expandedX + ((compactX - expandedX) * progress),
                y: 8 - (15 * progress)
            )
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

    @Environment(\.dismiss) private var dismiss
    @State private var caption: String
    @State private var date: Date
    @State private var location: String
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var temperature: Int
    @State private var temperatureText: String
    @State private var condition: String
    @State private var isShowingDeleteConfirmation = false
    @State private var selectedReplacementPhoto: PhotosPickerItem?
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

    init(
        item: BlogItemDisplay,
        weatherAttributionProvider: (any WeatherAttributing)? = nil,
        currentLocationProvider: @escaping @MainActor () async throws -> CLLocationCoordinate2D = {
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        },
        reverseGeocodeProvider: @escaping (CLLocationCoordinate2D) async throws -> String? = { _ in nil },
        historicalWeatherProvider: @escaping (WeatherLocation, Date) async throws -> WeatherCapture? = { _, _ in nil },
        onUpdate: @escaping (BlogItemUpdateRequest) -> Void = { _ in },
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in }
    ) {
        originalItem = item
        self.weatherAttributionProvider = weatherAttributionProvider
        self.currentLocationProvider = currentLocationProvider
        self.reverseGeocodeProvider = reverseGeocodeProvider
        self.historicalWeatherProvider = historicalWeatherProvider
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _caption = State(initialValue: item.caption)
        _date = State(initialValue: item.date)
        _location = State(initialValue: item.location)
        _latitude = State(initialValue: item.latitude)
        _longitude = State(initialValue: item.longitude)
        _temperature = State(initialValue: item.weather.temperatureCelsius ?? 0)
        _temperatureText = State(initialValue: String(item.weather.temperatureCelsius ?? 0))
        _condition = State(initialValue: item.weather.conditionCode ?? "")
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
                }

                dateTimeEditor

                locationEditor

                temperatureEditor

                weatherConditionEditor

                LabeledContent("Author", value: originalItem.author)
                    .foregroundStyle(.secondary)

                Divider()

                Button("Delete this entry", systemImage: "trash", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
                    .frame(maxWidth: .infinity, alignment: .leading)

                WeatherAttributionFooter(provider: weatherAttributionProvider)
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(detailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .photosPicker(
            isPresented: $isShowingReplacementPicker,
            selection: $selectedReplacementPhoto,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedReplacementPhoto) { _, newValue in
            guard let newValue else { return }
            loadReplacementPhoto(from: newValue)
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
                    saveChanges()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Save")
                    }
                }
                .accessibilityLabel("Save")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") {
                    dismiss()
                }
            }
        }
    }

    private var photoEditor: some View {
        photoEditorContent
    }

    private var locationEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Button {
                    presentLocationPicker()
                } label: {
                    Group {
                        if isLoadingLocationPicker || isResolvingPlaceName {
                            ProgressView()
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.green)
                    .frame(width: 32, height: 32)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adjust location on map")

                TextField("Location", text: $location)
                    .textFieldStyle(.roundedBorder)
            }
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
        LabeledContent {
            HStack(spacing: 0) {
                Button {
                    updateTemperature(to: temperature - 1)
                } label: {
                    Image(systemName: "minus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 42)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 16,
                                bottomLeadingRadius: 16,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(temperature <= -50)
                .accessibilityLabel("Decrease temperature")

                TextField("Temperature", text: $temperatureText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.center)
                    .frame(width: 46)
                    .frame(height: 42)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .onChange(of: temperatureText) { _, newValue in
                        syncTemperature(from: newValue)
                    }

                Button {
                    updateTemperature(to: temperature + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 44, height: 42)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 16,
                                topTrailingRadius: 16
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(temperature >= 60)
                .accessibilityLabel("Increase temperature")
            }
        } label: {
            Text("Temperature (°C)")
        }
    }

    private var weatherConditionEditor: some View {
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
                    Image(systemName: selectedWeatherConditionSystemImage)
                        .foregroundStyle(.secondary)

                    Text(selectedWeatherConditionDescription)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("BlogItem weather condition")
            .overlay(alignment: .trailing) {
                if isRefreshingHistoricalWeather {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 34)
                }
            }
        } label: {
            Text("Weather\nconditions")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedWeatherConditionDescription: String {
        condition.isEmpty ? "Unknown" : WeatherConditionCatalog.description(for: condition)
    }

    private var selectedWeatherConditionSystemImage: String {
        condition.isEmpty ? "questionmark.circle" : WeatherConditionCatalog.systemImage(for: condition)
    }

    @ViewBuilder
    private var photoEditorContent: some View {
        if let replacementPreviewImage {
            Image(uiImage: replacementPreviewImage)
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
            JournalPhotoPlaceholder(palette: originalItem.palette ?? .harbour)
                .frame(maxWidth: .infinity, minHeight: 270)
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
            ContentUnavailableView(
                "Text-only BlogItem",
                systemImage: "text.alignleft",
                description: Text("Add a photo if this moment needs one.")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
            .overlay(alignment: .topTrailing) {
                photoActionsMenu
            }
            .overlay {
                replacementProgressOverlay
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        }
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
            || replacementPhotoDraft != nil
            || originalItem.localImagePath != nil
            || originalItem.palette != nil
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

    private func updateTemperature(to newValue: Int) {
        let clampedValue = min(max(newValue, -50), 60)
        temperature = clampedValue
        temperatureText = String(clampedValue)
    }

    private func syncTemperature(from rawValue: String) {
        if rawValue.isEmpty || rawValue == "-" {
            return
        }

        let filtered = rawValue.enumerated().filter { index, character in
            character.isNumber || (character == "-" && index == 0)
        }.map(\.element)
        let normalized = String(filtered)

        guard normalized == rawValue else {
            temperatureText = normalized
            return
        }

        guard let parsedValue = Int(normalized) else { return }
        let clampedValue = min(max(parsedValue, -50), 60)
        temperature = clampedValue
        if clampedValue != parsedValue {
            temperatureText = String(clampedValue)
        }
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

    private func loadReplacementPhoto(from item: PhotosPickerItem) {
        isLoadingReplacementPhoto = true
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw BlogItemPhotoActionError.invalidSelection
                }
                guard let previewImage = await Self.makePreviewImage(from: data) else {
                    throw BlogItemPhotoActionError.previewUnavailable
                }
                let pixelSize = Self.pixelSize(from: data)
                await MainActor.run {
                    replacementPhotoDraft = BlogItemPhotoAssetDraft(
                        imageData: data,
                        mimeType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg",
                        pixelWidth: pixelSize.width,
                        pixelHeight: pixelSize.height
                    )
                    replacementPreviewImage = previewImage
                    isPhotoRemoved = false
                    isLoadingReplacementPhoto = false
                    selectedReplacementPhoto = nil
                }
            } catch {
                await MainActor.run {
                    isLoadingReplacementPhoto = false
                    photoActionErrorMessage = "The selected photo could not be loaded."
                    selectedReplacementPhoto = nil
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
                        updateTemperature(to: weather.temperatureCelsius)
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(gallery.items.count) moments")
                        .font(.title2.weight(.bold))
                    Text(timeRange)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(gallery.location, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                ForEach(gallery.items) { item in
                    NavigationLink(value: JournalDestination.blogItem(item)) {
                        BlogItemCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(gallery.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var timeRange: String {
        guard let first = gallery.items.first,
              let last = gallery.items.last else {
            return ""
        }
        return "\(first.localTimeText())–\(last.localTimeText())"
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
