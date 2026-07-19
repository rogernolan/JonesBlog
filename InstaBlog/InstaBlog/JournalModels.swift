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

nonisolated enum BlogItemPhotoAvailability: String, Hashable, Sendable {
    case none
    case available
    case downloading
    case unavailable
}

nonisolated enum BlogItemDatePolicy {
    static func allows(_ itemDate: Date, relativeTo now: Date = Date()) -> Bool {
        itemDate <= now
    }
}

nonisolated enum BlogItemDatePresentationCache {
    nonisolated struct CacheMetrics: Equatable, Sendable {
        let cacheHits: Int
        let cacheMisses: Int
    }

    private static let cache = DatePresentationCache()

    static var cacheMetrics: CacheMetrics {
        cache.metrics
    }

    static func resetForTesting() {
        cache.reset()
    }

    static func localTime(
        for date: Date,
        timeZone: TimeZone,
        locale: Locale
    ) -> String {
        cache.localTime(for: date, timeZone: timeZone, locale: locale)
    }

    static func metadata(
        for date: Date,
        relativeTo now: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        locale: Locale
    ) -> String {
        cache.metadata(
            for: date,
            relativeTo: now,
            calendar: calendar,
            timeZone: timeZone,
            locale: locale
        )
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
    var temperatureCelsius: Double?
    var conditionCode: String?
    var condition: String?
    var systemImage: String?

    init(
        temperatureCelsius: Double? = nil,
        conditionCode: String? = nil,
        condition: String? = nil,
        systemImage: String? = nil
    ) {
        self.temperatureCelsius = temperatureCelsius
        self.conditionCode = conditionCode
        self.condition = condition
        self.systemImage = systemImage
    }

    var isAvailable: Bool {
        temperatureCelsius != nil || !(condition?.isEmpty ?? true)
    }
}

nonisolated enum TemperatureValue {
    static let minimumCelsius = -100.0
    static let maximumCelsius = 60.0

    static func normalized(_ value: Double) -> Double {
        let constrained = min(max(value, minimumCelsius), maximumCelsius)
        return (constrained * 2).rounded() / 2
    }
}

nonisolated enum TemperatureText {
    static func constrained(_ rawValue: String) -> String {
        var sanitized = ""

        for character in rawValue {
            if character.isNumber {
                sanitized.append(character)
            } else if character == "-" && sanitized.isEmpty {
                sanitized.append(character)
            } else if character == "." && !sanitized.contains(".") {
                sanitized.append(character)
            }
        }

        let unsignedValue = sanitized.drop(while: { $0 == "-" })
        let components = unsignedValue.split(separator: ".", omittingEmptySubsequences: false)
        let integerDigitCount = components.first?.count ?? 0
        let fractionDigitCount = components.count > 1 ? components[1].count : 0

        guard integerDigitCount > 2 || fractionDigitCount > 1,
              let value = Double(sanitized) else {
            return sanitized
        }

        let normalized = TemperatureValue.normalized(value)
        return normalized.formatted(.number.precision(.fractionLength(0...1)))
    }
}

nonisolated enum PhotoCaptionText {
    static func updating(_ previousValue: String, with proposedValue: String) -> String {
        let proposedWithoutNewlines = proposedValue.unicodeScalars.filter {
            !CharacterSet.newlines.contains($0)
        }

        if String(String.UnicodeScalarView(proposedWithoutNewlines)) == previousValue {
            return previousValue
        }

        return singleLine(proposedValue)
    }

    static func singleLine(_ value: String) -> String {
        var result = ""
        var isReplacingNewline = false

        for scalar in value.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                if !isReplacingNewline {
                    result.append(" ")
                }
                isReplacingNewline = true
            } else {
                result.unicodeScalars.append(scalar)
                isReplacingNewline = false
            }
        }

        return result
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

nonisolated struct PhotoItemDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var date: Date
    var caption: String
    var availability: BlogItemPhotoAvailability
    var localImagePath: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var palette: JournalPalette?

    init(
        id: UUID = UUID(),
        date: Date,
        caption: String = "",
        availability: BlogItemPhotoAvailability = .none,
        localImagePath: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        palette: JournalPalette? = nil
    ) {
        self.id = id
        self.date = date
        self.caption = caption
        self.availability = availability
        self.localImagePath = localImagePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.palette = palette
    }
}

nonisolated struct BlogItemDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var author: String
    var lastEditor: String?
    var date: Date
    var createdAt: Date?
    var lastEditedAt: Date?
    var timeZoneIdentifier: String?
    var blogText: String
    var location: String
    var latitude: Double?
    var longitude: Double?
    var weather: WeatherDisplay
    var photos: [PhotoItemDisplay]
    var syncStatus: BlogItemSyncStatus

    init(
        id: UUID = UUID(),
        author: String,
        lastEditor: String? = nil,
        date: Date,
        createdAt: Date? = nil,
        lastEditedAt: Date? = nil,
        timeZoneIdentifier: String? = nil,
        blogText: String,
        location: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        weather: WeatherDisplay,
        photos: [PhotoItemDisplay] = [],
        syncStatus: BlogItemSyncStatus = .synced
    ) {
        self.id = id
        self.author = author
        self.lastEditor = lastEditor
        self.date = date
        self.createdAt = createdAt
        self.lastEditedAt = lastEditedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.blogText = blogText
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.weather = weather
        self.photos = photos
        self.syncStatus = syncStatus
    }

    private var resolvedTimeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    func localTimeText(locale: Locale = .current) -> String {
        BlogItemDatePresentationCache.localTime(
            for: date,
            timeZone: resolvedTimeZone,
            locale: locale
        )
    }

    func metadataDateTimeText(
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .current
    ) -> String {
        BlogItemDatePresentationCache.metadata(
            for: date,
            relativeTo: now,
            calendar: calendar,
            timeZone: resolvedTimeZone,
            locale: locale
        )
    }
}

private nonisolated final class DatePresentationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DatePresentationKey: String] = [:]
    private var formatters: [DateFormatterKey: DateFormatter] = [:]
    private var cacheHits = 0
    private var cacheMisses = 0

    var metrics: BlogItemDatePresentationCache.CacheMetrics {
        lock.withLock { .init(cacheHits: cacheHits, cacheMisses: cacheMisses) }
    }

    func localTime(for date: Date, timeZone: TimeZone, locale: Locale) -> String {
        lock.withLock {
            formatter(locale: locale, timeZone: timeZone, template: "HH:mm").string(from: date)
        }
    }

    func metadata(
        for date: Date,
        relativeTo now: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        locale: Locale
    ) -> String {
        lock.withLock {
            var localCalendar = calendar
            localCalendar.timeZone = timeZone
            let key = DatePresentationKey(
                date: date,
                relativeDay: localCalendar.startOfDay(for: now),
                calendarIdentifier: calendar.identifier,
                timeZoneIdentifier: timeZone.identifier,
                localeIdentifier: locale.identifier
            )
            if let cached = values[key] {
                cacheHits += 1
                return cached
            }

            cacheMisses += 1
            let time = formatter(locale: locale, timeZone: timeZone, template: "HH:mm").string(from: date)
            let value: String
            if localCalendar.isDate(date, inSameDayAs: now) {
                value = "Today, \(time)"
            } else if let yesterday = localCalendar.date(byAdding: .day, value: -1, to: now),
                      localCalendar.isDate(date, inSameDayAs: yesterday) {
                value = "Yesterday, \(time)"
            } else {
                let template = localCalendar.isDate(date, equalTo: now, toGranularity: .year)
                    ? "d MMM"
                    : "d MMM yyyy"
                value = "\(formatter(locale: locale, timeZone: timeZone, template: template).string(from: date)), \(time)"
            }
            if values.count >= 512 {
                values.removeAll(keepingCapacity: true)
            }
            values[key] = value
            return value
        }
    }

    func reset() {
        lock.withLock {
            values.removeAll(keepingCapacity: false)
            formatters.removeAll(keepingCapacity: false)
            cacheHits = 0
            cacheMisses = 0
        }
    }

    private func formatter(locale: Locale, timeZone: TimeZone, template: String) -> DateFormatter {
        let key = DateFormatterKey(
            localeIdentifier: locale.identifier,
            timeZoneIdentifier: timeZone.identifier,
            template: template
        )
        if let formatter = formatters[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if template == "HH:mm" {
            formatter.dateFormat = template
        } else {
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
        formatters[key] = formatter
        return formatter
    }
}

private nonisolated struct DatePresentationKey: Hashable {
    let date: Date
    let relativeDay: Date
    let calendarIdentifier: Calendar.Identifier
    let timeZoneIdentifier: String
    let localeIdentifier: String
}

private nonisolated struct DateFormatterKey: Hashable {
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let template: String
}

nonisolated struct BlogItemPhotoAssetDraft: Equatable, Sendable {
    var imageData: Data
    var mimeType: String
    var photoLibraryAssetIdentifier: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var photoDate: Date
    var photoCaption: String
    var timeZoneIdentifier: String?
    var latitude: Double?
    var longitude: Double?
    var locationName: String?
    var countryCode: String?

    init(
        imageData: Data,
        mimeType: String,
        photoLibraryAssetIdentifier: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        photoDate: Date = Date(),
        photoCaption: String = "",
        timeZoneIdentifier: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        countryCode: String? = nil
    ) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.photoLibraryAssetIdentifier = photoLibraryAssetIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.photoDate = photoDate
        self.photoCaption = photoCaption
        self.timeZoneIdentifier = timeZoneIdentifier
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.countryCode = countryCode
    }
}

nonisolated enum BlogItemPhotoUpdate: Equatable, Sendable {
    case existing(PhotoItemDisplay)
    case added(BlogItemPhotoAssetDraft)
}

nonisolated struct BlogItemUpdateRequest: Equatable, Sendable {
    let id: UUID
    var blogText: String
    var date: Date
    var location: String
    var latitude: Double?
    var longitude: Double?
    var temperatureCelsius: Double
    var weatherCondition: String?
    var photos: [BlogItemPhotoUpdate]

    init(
        id: UUID,
        blogText: String,
        date: Date,
        location: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        temperatureCelsius: Double,
        weatherCondition: String? = nil,
        photos: [BlogItemPhotoUpdate]
    ) {
        self.id = id
        self.blogText = blogText
        self.date = date
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.temperatureCelsius = temperatureCelsius
        self.weatherCondition = weatherCondition
        self.photos = photos
    }
}

nonisolated struct DayPostDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var date: Date
    var localDay: String
    var route: [String]
    var blogItems: [BlogItemDisplay]

    init(
        id: UUID = UUID(),
        date: Date,
        localDay: String? = nil,
        route: [String],
        blogItems: [BlogItemDisplay]
    ) {
        self.id = id
        self.date = date
        self.localDay = localDay ?? JournalDayProgress.localDay(from: date)
        self.route = route
        self.blogItems = blogItems
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
    nonisolated enum Kind: Hashable, Sendable {
        case trip
        case unassigned
    }

    static let unassignedID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

    let id: UUID
    var kind: Kind
    var title: String
    var description: String
    var startLocalDay: String
    var endLocalDay: String?
    var closedAt: Date?
    var days: [DayPostDisplay]

    init(
        id: UUID = UUID(),
        kind: Kind = .trip,
        title: String,
        description: String = "",
        startLocalDay: String = "",
        endLocalDay: String? = nil,
        closedAt: Date? = nil,
        days: [DayPostDisplay]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.description = description
        self.startLocalDay = startLocalDay
        self.endLocalDay = endLocalDay
        self.closedAt = closedAt
        self.days = days
    }

    var isCurrent: Bool {
        kind == .trip && endLocalDay == nil
    }

    var isUnassigned: Bool {
        kind == .unassigned
    }

    static var emptyUnassigned: TripDisplay {
        TripDisplay(
            id: unassignedID,
            kind: .unassigned,
            title: "Unassigned",
            days: []
        )
    }
}

nonisolated enum TripValidationStatus: Equatable, Sendable {
    case valid
    case overlapsAnotherTrip
    case multipleOpenTrips

    var statusText: String {
        switch self {
        case .valid:
            "Valid dates"
        case .overlapsAnotherTrip:
            "Overlaps another trip"
        case .multipleOpenTrips:
            "There may only be one open trip"
        }
    }
}

nonisolated struct TripValidationCandidate: Equatable, Sendable {
    var id: UUID?
    var startLocalDay: String
    var endLocalDay: String?
}

nonisolated enum TripValidation {
    static func validate(
        candidate: TripValidationCandidate,
        against trips: [TripValidationCandidate],
        todayLocalDay: String
    ) -> TripValidationStatus {
        let otherTrips = trips.filter { $0.id != candidate.id }

        if candidate.endLocalDay == nil,
           otherTrips.contains(where: { $0.endLocalDay == nil }) {
            return .multipleOpenTrips
        }

        let candidateEnd = candidate.endLocalDay ?? todayLocalDay
        for trip in otherTrips {
            let tripEnd = trip.endLocalDay ?? todayLocalDay
            let overlaps = candidate.startLocalDay <= tripEnd && trip.startLocalDay <= candidateEnd
            if overlaps {
                return .overlapsAnotherTrip
            }
        }

        return .valid
    }
}

nonisolated enum JournalDestination: Hashable {
    case blogItem(BlogItemDisplay)
    case newBlogItem(BlogItemDisplay, after: BlogItemDisplay)
}

nonisolated func reconciledJournalPath(
    _ path: [JournalDestination],
    with trip: TripDisplay
) -> [JournalDestination] {
    var itemsByID: [UUID: BlogItemDisplay] = [:]
    for item in trip.days.flatMap(\.blogItems) {
        itemsByID[item.id] = item
    }

    return path.compactMap { destination in
        switch destination {
        case .blogItem(let item):
            itemsByID[item.id].map(JournalDestination.blogItem)
        case .newBlogItem(let item, let source):
            .newBlogItem(item, after: source)
        }
    }
}
