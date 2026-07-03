import Foundation

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
    var condition: String?
    var systemImage: String?

    var isAvailable: Bool {
        temperatureCelsius != nil || !(condition?.isEmpty ?? true)
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
    var route: [String]
    var entries: [DayPostEntry]

    init(
        id: UUID = UUID(),
        date: Date,
        route: [String],
        entries: [DayPostEntry]
    ) {
        self.id = id
        self.date = date
        self.route = route
        self.entries = entries
    }

    var routeBreadcrumb: String {
        route.joined(separator: " → ")
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
