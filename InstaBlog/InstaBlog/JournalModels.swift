import Foundation
import WeatherKit

nonisolated enum SyncDependencyState: Equatable, Sendable {
    case synced
    case pending
    case failed
    case notRequired
}

nonisolated enum BlogItemSyncStatus: String, Equatable, Sendable {
    case storedLocally
    case synced
    case pending
    case failed

    static func resolve(
        record: SyncDependencyState,
        media: SyncDependencyState,
        isShared: Bool = true
    ) -> Self {
        guard isShared else {
            return .storedLocally
        }
        if record == .failed || media == .failed {
            return .failed
        }
        if record == .pending || media == .pending {
            return .pending
        }
        return .synced
    }

    var accessibilityDescription: String {
        switch self {
        case .storedLocally: "Stored locally"
        case .synced: "Uploaded"
        case .pending: "Uploading"
        case .failed: "Upload failed"
        }
    }
}

nonisolated enum BlogItemDatePolicy {
    static func allows(_ itemDate: Date, relativeTo now: Date = Date()) -> Bool {
        itemDate <= now
    }
}

nonisolated enum TripTitleTransition {
    static func progress(scrollOffset: Double, collapseDistance: Double) -> Double {
        guard collapseDistance > 0 else { return scrollOffset > 0 ? 1 : 0 }
        return min(max(scrollOffset / collapseDistance, 0), 1)
    }
}

nonisolated enum JournalPalette: String, Hashable, Sendable {
    case saltMarsh
    case harbour
    case lunch
    case flamingos
    case train
}

nonisolated struct WeatherDisplay: Hashable, Sendable {
    var temperatureCelsius: Int?
    var conditionCode: String?
    var condition: String?
    var systemImage: String?

    var isAvailable: Bool {
        temperatureCelsius != nil || !(condition?.isEmpty ?? true)
    }
}

nonisolated enum WeatherConditionCatalog {
    static let supportedConditions = WeatherCondition.allCases

    static func description(for code: String) -> String {
        if let weatherCondition = WeatherCondition(rawValue: code) {
            return sentenceCased(weatherCondition.accessibilityDescription)
        }

        switch code.lowercased() {
        case "sunny":
            return "Sunny"
        case "cloudy":
            return "Cloudy"
        case "rainy", "rain":
            return "Rain"
        default:
            return code.isEmpty ? "Unknown" : code
        }
    }

    static func systemImage(for code: String) -> String {
        switch code {
        case "clear", "Sunny", "sunny":
            return "sun.max.fill"
        case "mostlyClear", "partlyCloudy", "mostly sunny", "Mostly sunny":
            return "cloud.sun.fill"
        case "cloudy", "mostlyCloudy", "Cloudy":
            return "cloud.fill"
        case "foggy", "haze", "smoky":
            return "cloud.fog.fill"
        case "drizzle", "rain", "heavyRain", "freezingDrizzle", "freezingRain", "sunShowers", "Rain", "rainy":
            return "cloud.rain.fill"
        case "snow", "heavySnow", "flurries", "sunFlurries", "sleet", "wintryMix", "blowingSnow", "blizzard":
            return "cloud.snow.fill"
        case "isolatedThunderstorms", "scatteredThunderstorms", "strongStorms", "thunderstorms", "tropicalStorm", "hurricane":
            return "cloud.bolt.rain.fill"
        case "hail":
            return "cloud.hail.fill"
        case "breezy", "windy", "blowingDust":
            return "wind"
        case "hot":
            return "thermometer.sun.fill"
        case "frigid":
            return "thermometer.snowflake"
        default:
            return "cloud.sun.fill"
        }
    }

    private static func sentenceCased(_ value: String) -> String {
        guard let firstCharacter = value.first else { return value }
        return String(firstCharacter).uppercased() + value.dropFirst()
    }
}

nonisolated struct BlogItemDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var author: String
    var date: Date
    var timeZoneIdentifier: String?
    var caption: String
    var location: String
    var latitude: Double?
    var longitude: Double?
    var weather: WeatherDisplay
    var localImagePath: String?
    var palette: JournalPalette?
    var syncStatus: BlogItemSyncStatus

    init(
        id: UUID = UUID(),
        author: String,
        date: Date,
        timeZoneIdentifier: String? = nil,
        caption: String,
        location: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        weather: WeatherDisplay,
        localImagePath: String? = nil,
        palette: JournalPalette?,
        syncStatus: BlogItemSyncStatus = .synced
    ) {
        self.id = id
        self.author = author
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.caption = caption
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.weather = weather
        self.localImagePath = localImagePath
        self.palette = palette
        self.syncStatus = syncStatus
    }

    private var resolvedTimeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    func localTimeText(locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = resolvedTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    func metadataDateTimeText(
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .current
    ) -> String {
        var localCalendar = calendar
        localCalendar.timeZone = resolvedTimeZone

        let timeText = localTimeText(locale: locale)

        if localCalendar.isDate(date, inSameDayAs: now) {
            return "Today, \(timeText)"
        }

        if let yesterday = localCalendar.date(byAdding: .day, value: -1, to: now),
           localCalendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(timeText)"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = resolvedTimeZone
        dateFormatter.setLocalizedDateFormatFromTemplate(
            localCalendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        )

        return "\(dateFormatter.string(from: date)), \(timeText)"
    }
}

nonisolated struct BlogItemPhotoAssetDraft: Equatable, Sendable {
    var imageData: Data
    var mimeType: String
    var pixelWidth: Int?
    var pixelHeight: Int?
}

nonisolated enum BlogItemPhotoChange: Equatable, Sendable {
    case unchanged
    case removed
    case replaced(BlogItemPhotoAssetDraft)
}

nonisolated struct BlogItemUpdateRequest: Equatable, Sendable {
    let id: UUID
    var caption: String
    var date: Date
    var location: String
    var latitude: Double?
    var longitude: Double?
    var temperatureCelsius: Int
    var weatherCondition: String?
    var photoChange: BlogItemPhotoChange

    init(
        id: UUID,
        caption: String,
        date: Date,
        location: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        temperatureCelsius: Int,
        weatherCondition: String? = nil,
        photoChange: BlogItemPhotoChange = .unchanged
    ) {
        self.id = id
        self.caption = caption
        self.date = date
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.temperatureCelsius = temperatureCelsius
        self.weatherCondition = weatherCondition
        self.photoChange = photoChange
    }
}

nonisolated struct GalleryDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var location: String
    var items: [BlogItemDisplay]

    init(
        id: UUID = UUID(),
        title: String,
        location: String,
        items: [BlogItemDisplay]
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.items = items
    }
}

nonisolated enum DayPostEntry: Identifiable, Hashable, Sendable {
    case blogItem(BlogItemDisplay)
    case gallery(GalleryDisplay)

    var id: UUID {
        switch self {
        case .blogItem(let item): item.id
        case .gallery(let gallery): gallery.id
        }
    }
}

nonisolated struct DayPostDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var date: Date
    var localDay: String
    var route: [String]
    var entries: [DayPostEntry]

    init(
        id: UUID = UUID(),
        date: Date,
        localDay: String? = nil,
        route: [String],
        entries: [DayPostEntry]
    ) {
        self.id = id
        self.date = date
        self.localDay = localDay ?? JournalDayProgress.localDay(from: date)
        self.route = route
        self.entries = entries
    }

    var routeBreadcrumb: String {
        route.joined(separator: " → ")
    }
}

nonisolated struct JournalDayProgress: Equatable, Sendable {
    let dayNumber: Int
    let totalDays: Int

    init?(startLocalDay: String, dayLocalDay: String, endLocalDay: String) {
        let calendar = Calendar(identifier: .gregorian)
        guard let start = Self.date(from: startLocalDay, calendar: calendar),
              let day = Self.date(from: dayLocalDay, calendar: calendar),
              let end = Self.date(from: endLocalDay, calendar: calendar),
              let dayOffset = calendar.dateComponents([.day], from: start, to: day).day,
              let endOffset = calendar.dateComponents([.day], from: start, to: end).day,
              dayOffset >= 0,
              endOffset >= dayOffset else {
            return nil
        }

        dayNumber = dayOffset + 1
        totalDays = endOffset + 1
    }

    static func localDay(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func date(from localDay: String, calendar: Calendar) -> Date? {
        let parts = localDay.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

nonisolated struct TripDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var description: String
    var startLocalDay: String
    var endLocalDay: String?
    var closedAt: Date?
    var days: [DayPostDisplay]

    init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        startLocalDay: String = "",
        endLocalDay: String? = nil,
        closedAt: Date? = nil,
        days: [DayPostDisplay]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.startLocalDay = startLocalDay
        self.endLocalDay = endLocalDay
        self.closedAt = closedAt
        self.days = days
    }

    var isCurrent: Bool {
        closedAt == nil
    }
}

nonisolated enum JournalDestination: Hashable {
    case blogItem(BlogItemDisplay)
    case gallery(GalleryDisplay)
}

nonisolated func reconciledJournalPath(
    _ path: [JournalDestination],
    with trip: TripDisplay
) -> [JournalDestination] {
    var itemsByID: [UUID: BlogItemDisplay] = [:]
    var galleriesByID: [UUID: GalleryDisplay] = [:]

    for entry in trip.days.flatMap(\.entries) {
        switch entry {
        case .blogItem(let item):
            itemsByID[item.id] = item
        case .gallery(let gallery):
            galleriesByID[gallery.id] = gallery
            for item in gallery.items {
                itemsByID[item.id] = item
            }
        }
    }

    return path.compactMap { destination in
        switch destination {
        case .blogItem(let item):
            itemsByID[item.id].map(JournalDestination.blogItem)
        case .gallery(let gallery):
            galleriesByID[gallery.id].map(JournalDestination.gallery)
        }
    }
}
