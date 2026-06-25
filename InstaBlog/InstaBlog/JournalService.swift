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
        try database.read { db in
            guard let blog = try Blog.order(by: { ($0.createdAt, $0.id) }).fetchOne(db) else {
                return nil
            }
            let trips = try Trip
                .where { $0.blogID.eq(blog.id) }
                .order { ($0.startLocalDay.desc(), $0.createdAt.desc()) }
                .fetchAll(db)
            guard let trip = trips.first(where: { $0.closedAt == nil }) ?? trips.first else {
                return nil
            }

            let bloggers = try Blogger.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let mediaAssets = try MediaAsset.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let matchingItems = BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) && $0.localDay >= trip.startLocalDay }
            let items: [BlogItem]
            let effectiveEndLocalDay: String?
            if trip.closedAt == nil {
                effectiveEndLocalDay = localDay(for: now(), timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
            } else {
                effectiveEndLocalDay = trip.endLocalDay
            }
            if let endLocalDay = effectiveEndLocalDay {
                items = try matchingItems
                    .where { $0.localDay <= endLocalDay }
                    .order { ($0.itemDate, $0.id) }
                    .fetchAll(db)
            } else {
                items = try matchingItems
                    .order { ($0.itemDate, $0.id) }
                    .fetchAll(db)
            }

            let bloggersByID = Dictionary(uniqueKeysWithValues: bloggers.map { ($0.id, $0) })
            let mediaByID = Dictionary(uniqueKeysWithValues: mediaAssets.map { ($0.id, $0) })
            let displayItems = items.map {
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
                    entries: entries(for: dayItems, galleryInterval: blog.galleryIntervalSeconds)
                )
            }

            return TripDisplay(id: trip.id, title: trip.title, days: days)
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
