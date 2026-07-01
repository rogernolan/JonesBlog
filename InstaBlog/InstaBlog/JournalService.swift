import Foundation
import SQLiteData

nonisolated struct JournalService {
    let database: any DatabaseWriter
    let now: @Sendable () -> Date
    let fileManager: FileManager
    let mediaDirectoryURL: URL

    init(
        database: any DatabaseWriter,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default,
        mediaDirectoryURL: URL? = nil
    ) {
        self.database = database
        self.now = now
        self.fileManager = fileManager
        self.mediaDirectoryURL = mediaDirectoryURL
            ?? JournalService.defaultMediaDirectoryURL(fileManager: fileManager)
    }

    func loadCurrentTrip() throws -> TripDisplay? {
        let trips = try loadTrips()
        return trips.first(where: \.isCurrent)
    }

    func loadTrips() throws -> [TripDisplay] {
        try database.read { db in
            guard let blog = try Blog.order(by: { ($0.createdAt, $0.id) }).fetchOne(db) else {
                return []
            }
            let trips = try Trip
                .where { $0.blogID.eq(blog.id) }
                .order { ($0.startLocalDay.desc(), $0.createdAt.desc()) }
                .fetchAll(db)
            let bloggers = try Blogger.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let mediaAssets = try MediaAsset.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let items = try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.itemDate, $0.id) }
                .fetchAll(db)
            let bloggersByID = Dictionary(uniqueKeysWithValues: bloggers.map { ($0.id, $0) })
            let mediaByID = Dictionary(uniqueKeysWithValues: mediaAssets.map { ($0.id, $0) })

            let displays = trips.map { trip in
                makeDisplayTrip(
                    trip,
                    items: items,
                    galleryInterval: blog.galleryIntervalSeconds,
                    bloggersByID: bloggersByID,
                    mediaByID: mediaByID
                )
            }

            return displays.sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent {
                    return lhs.isCurrent
                }
                if lhs.startLocalDay != rhs.startLocalDay {
                    return lhs.startLocalDay > rhs.startLocalDay
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    func updateTripDetails(
        id: Trip.ID,
        title: String,
        description: String,
        startLocalDay: String,
        endLocalDay: String?
    ) throws {
        try database.write { db in
            try Trip.find(id)
                .update {
                    $0.title = #bind(title)
                    $0.description = #bind(description)
                    $0.startLocalDay = #bind(startLocalDay)
                    $0.endLocalDay = #bind(endLocalDay)
                    $0.updatedAt = #bind(now())
                }
                .execute(db)
        }
    }

    @discardableResult
    func createTrip(
        title: String,
        description: String,
        startLocalDay: String,
        endLocalDay: String?
    ) throws -> Trip.ID {
        try database.write { db in
            guard let blog = try Blog.order(by: { ($0.createdAt, $0.id) }).fetchOne(db) else {
                throw JournalServiceError.missingBlog
            }
            let timestamp = now()
            let id = UUID()
            try Trip.insert {
                Trip.Draft(
                    id: id,
                    blogID: blog.id,
                    title: title,
                    description: description,
                    startLocalDay: startLocalDay,
                    endLocalDay: endLocalDay,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
            .execute(db)
            return id
        }
    }

    func endTrip(id: Trip.ID) throws {
        try database.write { db in
            let timestamp = now()
            let localDay = localDay(for: timestamp, timeZoneIdentifier: nil)
            try Trip.find(id)
                .update {
                    $0.endLocalDay = #bind(localDay)
                    $0.updatedAt = #bind(timestamp)
                    $0.closedAt = #bind(timestamp)
                }
                .execute(db)
        }
    }

    func updateBlogItem(
        id: BlogItem.ID,
        caption: String,
        date: Date,
        location: String,
        temperatureCelsius: Int,
        weatherCondition: String
    ) throws {
        try database.write { db in
            let item = try BlogItem.find(db, key: id)
            let localDay = localDay(for: date, timeZoneIdentifier: item.itemTimeZoneIdentifier)
            try BlogItem.find(id)
                .update {
                    $0.caption = #bind(caption)
                    $0.itemDate = #bind(date)
                    $0.localDay = #bind(localDay)
                    $0.locationName = #bind(location)
                    $0.weatherTemperatureCelsius = #bind(Double(temperatureCelsius))
                    $0.weatherConditionCode = #bind(weatherCondition)
                    $0.updatedAt = #bind(now())
                }
                .execute(db)
        }
    }

    func createPhotoBlogItem(
        caption: String,
        date: Date,
        timeZoneIdentifier: String?,
        imageData: Data,
        mimeType: String,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) throws {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionValue = trimmedCaption.isEmpty ? nil : trimmedCaption
        let timestamp = now()
        let mediaID = UUID()
        let blogItemID = UUID()
        let fileExtension = JournalService.preferredFileExtension(for: mimeType)
        let mediaURL = mediaDirectoryURL.appendingPathComponent("\(mediaID.uuidString).\(fileExtension)")

        try fileManager.createDirectory(
            at: mediaDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try imageData.write(to: mediaURL, options: .atomic)

        do {
            try database.write { db in
                let blog = try Blog.order { ($0.createdAt, $0.id) }.fetchOne(db)
                let blogger = try Blogger.order { ($0.createdAt, $0.id) }.fetchOne(db)
                guard let blog, let blogger else {
                    throw JournalCreationError.missingWorkspace
                }
                let localDay = localDay(for: date, timeZoneIdentifier: timeZoneIdentifier)

                try MediaAsset.insert {
                    MediaAsset.Draft(
                        id: mediaID,
                        blogID: blog.id,
                        localOriginalPath: mediaURL.path,
                        filename: mediaURL.lastPathComponent,
                        mimeType: mimeType,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .execute(db)

                try BlogItem.insert {
                    BlogItem.Draft(
                        id: blogItemID,
                        blogID: blog.id,
                        authorID: blogger.id,
                        caption: captionValue,
                        createdAt: timestamp,
                        updatedAt: timestamp,
                        itemDate: date,
                        itemTimeZoneIdentifier: timeZoneIdentifier,
                        localDay: localDay,
                        photoAssetID: mediaID
                    )
                }
                .execute(db)
            }
        } catch {
            try? fileManager.removeItem(at: mediaURL)
            throw error
        }
    }

    private func makeDisplayTrip(
        _ trip: Trip,
        items: [BlogItem],
        galleryInterval: Int,
        bloggersByID: [Blogger.ID: Blogger],
        mediaByID: [MediaAsset.ID: MediaAsset]
    ) -> TripDisplay {
        let effectiveEndLocalDay = trip.closedAt == nil
            ? localDay(for: now(), timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
            : trip.endLocalDay
        let matchingItems = items.filter { item in
            guard item.localDay >= trip.startLocalDay else { return false }
            if let endLocalDay = effectiveEndLocalDay {
                return item.localDay <= endLocalDay
            }
            return true
        }
        let displayItems = matchingItems.map {
            makeDisplayItem($0, bloggersByID: bloggersByID, mediaByID: mediaByID)
        }

        let itemsByDay = Dictionary(grouping: displayItems) { localDay(for: $0.date, timeZoneIdentifier: $0.timeZoneIdentifier) }
        let days = itemsByDay.keys.sorted().compactMap { localDay -> DayPostDisplay? in
            guard let dayItems = itemsByDay[localDay]?.sorted(by: { $0.date < $1.date }),
                  let firstItem = dayItems.first else {
                return nil
            }
            return DayPostDisplay(
                id: firstItem.id,
                date: firstItem.date,
                route: route(for: dayItems),
                entries: entries(for: dayItems, galleryInterval: galleryInterval)
            )
        }

        return TripDisplay(
            id: trip.id,
            title: trip.title,
            description: trip.description,
            startLocalDay: trip.startLocalDay,
            endLocalDay: trip.endLocalDay,
            closedAt: trip.closedAt,
            days: days
        )
    }

    private func makeDisplayItem(
        _ item: BlogItem,
        bloggersByID: [Blogger.ID: Blogger],
        mediaByID: [MediaAsset.ID: MediaAsset]
    ) -> BlogItemDisplay {
        let condition = item.weatherConditionCode ?? "Unknown"
        let mediaAsset = item.photoAssetID.flatMap { mediaByID[$0] }
        let resolvedLocalImagePath = mediaAsset.flatMap(resolveLocalImagePath(for:))
        let recordState: SyncDependencyState = .synced
        let mediaState: SyncDependencyState
        if let mediaAsset {
            mediaState = mediaAsset.cloudAssetIdentifier == nil ? .pending : .synced
        } else {
            mediaState = .notRequired
        }

        return BlogItemDisplay(
            id: item.id,
            author: bloggersByID[item.authorID]?.displayName ?? BootstrapDefaults.bloggerDisplayName,
            date: item.itemDate,
            timeZoneIdentifier: item.itemTimeZoneIdentifier,
            caption: item.caption ?? "",
            location: item.locationName ?? "",
            weather: WeatherDisplay(
                temperatureCelsius: Int((item.weatherTemperatureCelsius ?? 0).rounded()),
                condition: condition,
                systemImage: weatherSystemImage(for: condition)
            ),
            localImagePath: resolvedLocalImagePath,
            palette: mediaAsset.flatMap {
                guard resolveLocalImagePath(for: $0) == nil else { return nil }
                return JournalPalette(rawValue: ($0.filename as NSString).deletingPathExtension)
            },
            syncStatus: BlogItemSyncStatus.resolve(record: recordState, media: mediaState)
        )
    }

    private func resolveLocalImagePath(for mediaAsset: MediaAsset) -> String? {
        let currentContainerPath = mediaDirectoryURL
            .appendingPathComponent(mediaAsset.filename)
            .path
        if fileManager.fileExists(atPath: currentContainerPath) {
            return currentContainerPath
        }

        if let legacyPath = mediaAsset.localOriginalPath,
           fileManager.fileExists(atPath: legacyPath) {
            return legacyPath
        }

        return nil
    }

    private func entries(
        for items: [BlogItemDisplay],
        galleryInterval: Int
    ) -> [DayPostEntry] {
        var result: [DayPostEntry] = []
        var index = items.startIndex

        while index < items.endIndex {
            let item = items[index]
            var galleryItems = [item]
            var nextIndex = items.index(after: index)
            while nextIndex < items.endIndex {
                let candidate = items[nextIndex]
                guard candidate.location == item.location,
                      candidate.date.timeIntervalSince(item.date) <= Double(galleryInterval) else {
                    break
                }
                galleryItems.append(candidate)
                nextIndex = items.index(after: nextIndex)
            }

            if galleryItems.count > 1 {
                result.append(
                    .gallery(
                        GalleryDisplay(
                            id: item.id,
                            title: item.location,
                            location: item.location,
                            items: galleryItems
                        )
                    )
                )
                index = nextIndex
            } else {
                result.append(.blogItem(item))
                index = items.index(after: index)
            }
        }
        return result
    }

    private func route(for items: [BlogItemDisplay]) -> [String] {
        items.reduce(into: [String]()) { route, item in
            guard !item.location.isEmpty, route.last != item.location else { return }
            route.append(item.location)
        }
    }

    private func localDay(for date: Date, timeZoneIdentifier: String?) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func weatherSystemImage(for condition: String) -> String {
        switch condition.lowercased() {
        case "clear", "sunny": "sun.max.fill"
        case "mostly sunny": "sun.haze.fill"
        case "cloudy": "cloud.fill"
        case "rain", "rainy": "cloud.rain.fill"
        default: "cloud.sun.fill"
        }
    }

    private static func preferredFileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/heic":
            return "heic"
        default:
            return "jpg"
        }
    }

    private static func defaultMediaDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupportDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return applicationSupportDirectory.appendingPathComponent("BlogItemMedia", isDirectory: true)
    }
}

enum JournalCreationError: Error {
    case missingWorkspace
}

private enum JournalServiceError: Error {
    case missingBlog
}
