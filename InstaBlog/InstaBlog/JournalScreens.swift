import SwiftUI
import UIKit

struct JournalView: View {
    let trip: TripDisplay
    let weatherAttributionProvider: (any WeatherAttributing)?
    let onUpdate: (BlogItemDisplay) -> Void
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
        path: Binding<[JournalDestination]> = .constant([]),
        onUpdate: @escaping (BlogItemDisplay) -> Void = { _ in },
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in },
        onEditTrip: @escaping () -> Void = {},
        onEndTrip: @escaping () -> Void = {}
    ) {
        self.trip = trip
        self.weatherAttributionProvider = weatherAttributionProvider
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
            .navigationDestination(for: JournalDestination.self) { destination in
                switch destination {
                case .blogItem(let item):
                    BlogItemDetailView(
                        item: item,
                        weatherAttributionProvider: weatherAttributionProvider,
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
    private let onUpdate: (BlogItemDisplay) -> Void
    private let onDelete: (BlogItemDisplay) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var caption: String
    @State private var date: Date
    @State private var location: String
    @State private var temperature: Int
    @State private var condition: String
    @State private var saveState = "Saved locally"
    @State private var isShowingDeleteConfirmation = false

    init(
        item: BlogItemDisplay,
        weatherAttributionProvider: (any WeatherAttributing)? = nil,
        onUpdate: @escaping (BlogItemDisplay) -> Void = { _ in },
        onDelete: @escaping (BlogItemDisplay) -> Void = { _ in }
    ) {
        originalItem = item
        self.weatherAttributionProvider = weatherAttributionProvider
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _caption = State(initialValue: item.caption)
        _date = State(initialValue: item.date)
        _location = State(initialValue: item.location)
        _temperature = State(initialValue: item.weather.temperatureCelsius ?? 0)
        _condition = State(initialValue: item.weather.condition ?? "")
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

                DatePicker(
                    "Date and time",
                    selection: $date,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .environment(
                    \.timeZone,
                    originalItem.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
                )

                editableField("Location", text: $location, systemImage: "mappin.and.ellipse")

                Stepper(value: $temperature, in: -50...60) {
                    LabeledContent("Temperature", value: "\(temperature) °C")
                }

                editableField("Weather", text: $condition, systemImage: "sun.max.fill")

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
        .navigationTitle("BlogItem")
        .navigationBarTitleDisplayMode(.inline)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(saveState)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: caption) { markSaved() }
        .onChange(of: date) { markSaved() }
        .onChange(of: location) { markSaved() }
        .onChange(of: temperature) { markSaved() }
        .onChange(of: condition) { markSaved() }
    }

    private var photoEditor: some View {
        ZStack(alignment: .topTrailing) {
            if originalItem.localImagePath != nil || originalItem.palette != nil {
                JournalPhotoSurface(item: originalItem)
                    .frame(minHeight: 270)
                    .clipShape(.rect(cornerRadius: 24))
            } else {
                ContentUnavailableView(
                    "Text-only BlogItem",
                    systemImage: "text.alignleft",
                    description: Text("Add a photo if this moment needs one.")
                )
                .frame(minHeight: 220)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
            }

            Menu {
                Button("Replace Photo", systemImage: "photo.badge.arrow.down") {}
                Button("Remove Photo", systemImage: "trash", role: .destructive) {}
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .padding(10)
            .accessibilityLabel("Photo actions")
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

    private func markSaved() {
        var updatedItem = originalItem
        updatedItem.caption = caption
        updatedItem.date = date
        updatedItem.location = location
        updatedItem.weather.temperatureCelsius = temperature
        updatedItem.weather.condition = condition.isEmpty ? nil : condition
        onUpdate(updatedItem)
        saveState = "Saved locally"
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
