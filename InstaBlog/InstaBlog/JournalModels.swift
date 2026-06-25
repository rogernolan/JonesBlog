import Foundation

nonisolated enum SyncDependencyState: Equatable, Sendable {
    case synced
    case pending
    case failed
    case notRequired
}

nonisolated enum BlogItemSyncStatus: Equatable, Sendable {
    case synced
    case pending
    case failed

    static func resolve(
        record: SyncDependencyState,
        media: SyncDependencyState
    ) -> Self {
        if record == .failed || media == .failed {
            return .failed
        }
        if record == .pending || media == .pending {
            return .pending
        }
        return .synced
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
    var temperatureCelsius: Int
    var condition: String
    var systemImage: String
}

nonisolated struct BlogItemDisplay: Identifiable, Hashable, Sendable {
    let id: UUID
    var author: String
    var date: Date
    var timeZoneIdentifier: String?
    var caption: String
    var location: String
    var weather: WeatherDisplay
    var palette: JournalPalette?
    var syncStatus: BlogItemSyncStatus

    init(
        id: UUID = UUID(),
        author: String,
        date: Date,
        timeZoneIdentifier: String? = nil,
        caption: String,
        location: String,
        weather: WeatherDisplay,
        palette: JournalPalette?,
        syncStatus: BlogItemSyncStatus = .synced
    ) {
        self.id = id
        self.author = author
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.caption = caption
        self.location = location
        self.weather = weather
        self.palette = palette
        self.syncStatus = syncStatus
    }

    func localTimeText(locale: Locale = .current) -> String {
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        return date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                timeZone: timeZone
            )
        )
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
    var days: [DayPostDisplay]

    init(id: UUID = UUID(), title: String, days: [DayPostDisplay]) {
        self.id = id
        self.title = title
        self.days = days
    }
}

nonisolated enum JournalDestination: Hashable {
    case blogItem(BlogItemDisplay)
    case gallery(GalleryDisplay)
}
