import Foundation
import CryptoKit
import SQLiteData

nonisolated struct MediaFileCleanup {
    let removeItem: (URL) throws -> Void
    let logFailure: (String) -> Void

    init(
        removeItem: @escaping (URL) throws -> Void,
        logFailure: @escaping (String) -> Void = { _ in }
    ) {
        self.removeItem = removeItem
        self.logFailure = logFailure
    }

    func removeItem(at url: URL) {
        do {
            try removeItem(url)
        } catch {
            AppTelemetry.log(
                "Failed to remove media file",
                category: "media.cleanup",
                level: .error,
                error: error
            )
            logFailure("Failed to remove media file at \(url.path): \(error)")
        }
    }
}

nonisolated struct JournalService: @unchecked Sendable {
    let database: any DatabaseWriter
    let now: @Sendable () -> Date
    let fileManager: FileManager
    let mediaFileCleanup: MediaFileCleanup
    let mediaDirectoryURL: URL
    let locationProvider: any CurrentLocationProviding
    let weatherProvider: any WeatherProviding
    let placeNameProvider: any PlaceNameProviding
    let mediaCacheDirectoryURL: URL
    let blogID: Blog.ID?
    let bloggerID: Blogger.ID?
    let syncStatusOverride: BlogItemSyncStatus?
    let photoAvailabilityOverride: BlogItemPhotoAvailability?
    let mediaAssetSyncService: MediaAssetSyncService?

    init(
        database: any DatabaseWriter,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default,
        mediaDirectoryURL: URL? = nil,
        locationProvider: any CurrentLocationProviding = CurrentLocationProvider(),
        weatherProvider: any WeatherProviding = LiveWeatherProvider(),
        placeNameProvider: any PlaceNameProviding = LivePlaceNameProvider(),
        mediaCacheDirectoryURL: URL? = nil,
        blogID: Blog.ID? = nil,
        bloggerID: Blogger.ID? = nil,
        syncStatusOverride: BlogItemSyncStatus? = nil,
        photoAvailabilityOverride: BlogItemPhotoAvailability? = nil,
        mediaAssetSyncService: MediaAssetSyncService? = nil
    ) {
        self.database = database
        self.now = now
        self.fileManager = fileManager
        self.mediaFileCleanup = MediaFileCleanup(removeItem: fileManager.removeItem(at:))
        self.mediaDirectoryURL = mediaDirectoryURL
            ?? Self.defaultMediaDirectoryURL(fileManager: fileManager)
        self.locationProvider = locationProvider
        self.weatherProvider = weatherProvider
        self.placeNameProvider = placeNameProvider
        self.mediaCacheDirectoryURL = mediaCacheDirectoryURL
            ?? Self.defaultMediaCacheDirectoryURL(fileManager: fileManager)
        self.blogID = blogID
        self.bloggerID = bloggerID
        self.syncStatusOverride = syncStatusOverride
        self.photoAvailabilityOverride = photoAvailabilityOverride
        self.mediaAssetSyncService = mediaAssetSyncService
    }

    func requestLocationPermissionIfNeeded() async {
        await locationProvider.requestPermissionIfNeeded()
    }

    @MainActor
    func currentLocation() async throws -> WeatherLocation {
        try await locationProvider.currentLocation()
    }

    func placeName(for location: WeatherLocation) async throws -> String? {
        try await placeNameProvider.placeName(for: location)
    }

    func synchronizeMediaAssets() async {
        guard let blogID, let mediaAssetSyncService else { return }
        do {
            AppTelemetry.record("Media synchronization started", category: "media.sync")
            try await mediaAssetSyncService.synchronize(blogID: blogID)
            AppTelemetry.record("Media synchronization completed", category: "media.sync")
        } catch {
            AppTelemetry.record(
                "Media synchronization failed",
                category: "media.sync",
                level: .error,
                error: error
            )
        }
    }

    func primeWeatherCapture() async {
        do {
            _ = try await fetchWeatherCapture()
        } catch {
            AppTelemetry.log(
                "Weather priming failed",
                category: "weather.enrichment",
                level: .warning,
                error: error
            )
        }
    }

    func loadCurrentTrip() throws -> TripDisplay? {
        let referenceDay = localDay(for: now(), timeZoneIdentifier: nil)
        let snapshot = try database.read { db -> JournalLoadSnapshot? in
            guard let blog = try selectedBlog(in: db),
                  let trip = try Trip
                .where({ $0.blogID.eq(blog.id) })
                .where({ $0.endLocalDay.is(nil) })
                .order(by: { ($0.startLocalDay.desc(), $0.createdAt.desc()) })
                .fetchOne(db)
            else {
                return nil
            }
            let bloggers = try Blogger.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let blogItems = try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .where { $0.localDay >= trip.startLocalDay }
                .where { $0.localDay <= referenceDay }
                .order { ($0.localDay, $0.itemDate, $0.id) }
                .fetchAll(db)
            let itemIDs = blogItems.map(\.id)
            let photoItems = itemIDs.isEmpty ? [] : try PhotoItem
                .where { $0.blogItemID.in(itemIDs) }
                .order { ($0.blogItemID, $0.photoDate, $0.createdAt, $0.id) }
                .fetchAll(db)
            let mediaIDs = Array(Set(photoItems.map(\.mediaAssetID)))
            let mediaAssets = mediaIDs.isEmpty ? [] : try MediaAsset
                .where { $0.id.in(mediaIDs) }
                .fetchAll(db)
            let isShared = (try? SyncMetadata
                .find(blog.syncMetadataID)
                .select(\.isShared)
                .fetchOne(db)) ?? false
            var uploadedBlogItemIDs = Set<BlogItem.ID>()
            var uploadedPhotoItemIDs = Set<PhotoItem.ID>()
            if isShared {
                for item in blogItems {
                    let uploaded = try SyncMetadata
                        .find(item.syncMetadataID)
                        .select(\.hasLastKnownServerRecord)
                        .fetchOne(db) ?? false
                    if uploaded { uploadedBlogItemIDs.insert(item.id) }
                }
                for photoItem in photoItems {
                    let uploaded = try SyncMetadata
                        .find(photoItem.syncMetadataID)
                        .select(\.hasLastKnownServerRecord)
                        .fetchOne(db) ?? false
                    if uploaded { uploadedPhotoItemIDs.insert(photoItem.id) }
                }
            }
            return JournalLoadSnapshot(
                trips: [trip],
                bloggers: bloggers,
                blogItems: blogItems,
                photoItems: photoItems,
                mediaAssets: mediaAssets,
                isShared: isShared,
                uploadedBlogItemIDs: uploadedBlogItemIDs,
                uploadedPhotoItemIDs: uploadedPhotoItemIDs
            )
        }
        guard let snapshot, let trip = snapshot.trips.first else { return nil }
        return makeDisplayTrip(trip, items: makeDisplayItems(from: snapshot))
    }

    func loadDeletedBlogItems() throws -> [BlogItemDisplay] {
        let snapshot = try database.read { db -> JournalLoadSnapshot? in
            guard let blog = try selectedBlog(in: db) else { return nil }
            let bloggers = try Blogger.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let blogItems = try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { $0.deletedAt.isNot(nil) }
                .fetchAll(db)
                .sorted {
                    if $0.deletedAt != $1.deletedAt { return ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
                    return $0.id.uuidString < $1.id.uuidString
                }
            let itemIDs = blogItems.map(\.id)
            let photoItems = itemIDs.isEmpty ? [] : try PhotoItem
                .where { $0.blogItemID.in(itemIDs) }
                .order { ($0.blogItemID, $0.photoDate, $0.createdAt, $0.id) }
                .fetchAll(db)
            let mediaIDs = Array(Set(photoItems.map(\.mediaAssetID)))
            let mediaAssets = mediaIDs.isEmpty ? [] : try MediaAsset
                .where { $0.id.in(mediaIDs) }
                .fetchAll(db)
            return JournalLoadSnapshot(
                trips: [],
                bloggers: bloggers,
                blogItems: blogItems,
                photoItems: photoItems,
                mediaAssets: mediaAssets,
                isShared: false,
                uploadedBlogItemIDs: [],
                uploadedPhotoItemIDs: []
            )
        }
        guard let snapshot else { return [] }
        return makeDisplayItems(from: snapshot)
    }

    func loadTrips() throws -> [TripDisplay] {
        let snapshot = try database.read { db -> JournalLoadSnapshot? in
            guard let blog = try selectedBlog(in: db) else { return nil }
            let trips = try Trip
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.startLocalDay, $0.createdAt, $0.id) }
                .fetchAll(db)
            let bloggers = try Blogger.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let blogItems = try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.localDay, $0.itemDate, $0.id) }
                .fetchAll(db)
            let itemIDs = blogItems.map(\.id)
            let photoItems = itemIDs.isEmpty ? [] : try PhotoItem
                .where { $0.blogItemID.in(itemIDs) }
                .order { ($0.blogItemID, $0.photoDate, $0.createdAt, $0.id) }
                .fetchAll(db)
            let mediaIDs = Array(Set(photoItems.map(\.mediaAssetID)))
            let mediaAssets = mediaIDs.isEmpty ? [] : try MediaAsset
                .where { $0.id.in(mediaIDs) }
                .fetchAll(db)
            let isShared = (try? SyncMetadata
                .find(blog.syncMetadataID)
                .select(\.isShared)
                .fetchOne(db)) ?? false
            var uploadedBlogItemIDs = Set<BlogItem.ID>()
            var uploadedPhotoItemIDs = Set<PhotoItem.ID>()
            if isShared {
                let metadataIDs = Set(blogItems.map(\.syncMetadataID) + photoItems.map(\.syncMetadataID))
                let uploadedMetadataIDs = metadataIDs.isEmpty ? Set<SyncMetadata.ID>() : Set(try SyncMetadata
                    .where { $0.id.in(metadataIDs) }
                    .where { $0.hasLastKnownServerRecord.eq(true) }
                    .select(\.id)
                    .fetchAll(db))
                uploadedBlogItemIDs = Set(
                    blogItems
                        .filter { uploadedMetadataIDs.contains($0.syncMetadataID) }
                        .map(\.id)
                )
                uploadedPhotoItemIDs = Set(
                    photoItems
                        .filter { uploadedMetadataIDs.contains($0.syncMetadataID) }
                        .map(\.id)
                )
            }
            return JournalLoadSnapshot(
                trips: trips,
                bloggers: bloggers,
                blogItems: blogItems,
                photoItems: photoItems,
                mediaAssets: mediaAssets,
                isShared: isShared,
                uploadedBlogItemIDs: uploadedBlogItemIDs,
                uploadedPhotoItemIDs: uploadedPhotoItemIDs
            )
        }
        guard let snapshot else { return [] }

        let referenceDay = localDay(for: now(), timeZoneIdentifier: nil)
        let displayItemsByID = Dictionary(uniqueKeysWithValues: makeDisplayItems(from: snapshot).map { ($0.id, $0) })
        let partition = JournalTripPartitioner.partition(
            items: snapshot.blogItems.enumerated().map { offset, item in
                JournalTripPartitionInput(id: item.id, localDay: item.localDay, sequence: offset)
            },
            trips: snapshot.trips,
            referenceDay: referenceDay
        )
        var displays = snapshot.trips.map { trip in
            makeDisplayTrip(
                trip,
                items: (partition.itemIDsByTripID[trip.id] ?? []).compactMap { displayItemsByID[$0] }
            )
        }
        let unassignedItems = partition.unassignedItemIDs.compactMap { displayItemsByID[$0] }
        if !unassignedItems.isEmpty {
            displays.insert(makeUnassignedDisplay(items: unassignedItems), at: 0)
        }
        return displays.sorted { lhs, rhs in
            if lhs.isUnassigned != rhs.isUnassigned { return lhs.isUnassigned }
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.startLocalDay != rhs.startLocalDay { return lhs.startLocalDay > rhs.startLocalDay }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func makeDisplayItems(from snapshot: JournalLoadSnapshot) -> [BlogItemDisplay] {
        let bloggersByID = Dictionary(
            snapshot.bloggers.map { ($0.id, $0) },
            uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 }
        )
        let mediaByID = Dictionary(
            snapshot.mediaAssets.map { ($0.id, $0) },
            uniquingKeysWith: { $0.updatedAt >= $1.updatedAt ? $0 : $1 }
        )
        let photosByBlogItemID = Dictionary(grouping: snapshot.photoItems, by: \.blogItemID)
        return snapshot.blogItems.map { item in
                makeDisplayItem(
                    item,
                    photoItems: photosByBlogItemID[item.id] ?? [],
                    bloggersByID: bloggersByID,
                    mediaByID: mediaByID,
                    isShared: snapshot.isShared,
                    isBlogItemUploaded: snapshot.uploadedBlogItemIDs.contains(item.id),
                    uploadedPhotoItemIDs: snapshot.uploadedPhotoItemIDs
                )
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
            let activeBlog = try requireActiveBlog(in: db)
            let trip = try Trip.find(db, key: id)
            guard trip.blogID == activeBlog.id else {
                throw JournalServiceError.inactiveBlogMutation
            }
            try validateTripRange(
                in: db,
                candidate: TripValidationCandidate(
                    id: id,
                    startLocalDay: startLocalDay,
                    endLocalDay: endLocalDay
                )
            )
            let closedAt = endLocalDay == nil ? nil : (trip.closedAt ?? now())
            try Trip.find(id).update {
                $0.title = #bind(title)
                $0.description = #bind(description)
                $0.startLocalDay = #bind(startLocalDay)
                $0.endLocalDay = #bind(endLocalDay)
                $0.closedAt = #bind(closedAt)
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
            let blog = try requireActiveBlog(in: db)
            try validateTripRange(
                in: db,
                candidate: TripValidationCandidate(
                    id: nil,
                    startLocalDay: startLocalDay,
                    endLocalDay: endLocalDay
                )
            )
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
                    heroImageAssetID: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    closedAt: endLocalDay == nil ? nil : timestamp,
                    deletedAt: nil
                )
            }
            .execute(db)
            return id
        }
    }

    func endTrip(id: Trip.ID) throws {
        try database.write { db in
            let activeBlog = try requireActiveBlog(in: db)
            let trip = try Trip.find(db, key: id)
            guard trip.blogID == activeBlog.id else {
                throw JournalServiceError.inactiveBlogMutation
            }
            let timestamp = now()
            let endDay = localDay(for: timestamp, timeZoneIdentifier: nil)
            try Trip.find(id).update {
                $0.endLocalDay = #bind(endDay)
                $0.closedAt = #bind(timestamp)
                $0.updatedAt = #bind(timestamp)
            }
            .execute(db)
        }
    }

    func deleteTrip(id: Trip.ID) throws {
        try database.write { db in
            let activeBlog = try requireActiveBlog(in: db)
            let trip = try Trip.find(db, key: id)
            guard trip.blogID == activeBlog.id else {
                throw JournalServiceError.inactiveBlogMutation
            }
            let timestamp = now()
            try Trip.find(id).update {
                $0.deletedAt = #bind(timestamp)
                $0.updatedAt = #bind(timestamp)
            }
            .execute(db)
        }
    }

    @discardableResult
    func createBlogItem(
        blogText: String,
        date: Date,
        timeZoneIdentifier: String?,
        photos: [BlogItemPhotoAssetDraft] = [],
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        countryCode: String? = nil
    ) throws -> BlogItem.ID {
        let trimmedText = blogText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !photos.isEmpty else {
            throw JournalServiceError.emptyBlogItem
        }
        let preparedPhotos = try photos.map { draft in
            (draft, try prepareMediaAsset(from: draft))
        }
        let timestamp = now()
        let id = UUID()
        do {
            try database.write { db in
                let blog = try requireActiveBlog(in: db)
                guard let blogger = try selectedBlogger(in: db, blogID: blog.id) else {
                    throw JournalCreationError.missingWorkspace
                }
                let earliestPhoto = photos.min {
                    $0.photoDate < $1.photoDate
                }
                let itemDate = earliestPhoto?.photoDate ?? date
                let resolvedTimeZone = earliestPhoto?.timeZoneIdentifier ?? timeZoneIdentifier
                try BlogItem.insert {
                    BlogItem.Draft(
                        id: id,
                        blogID: blog.id,
                        authorID: blogger.id,
                        blogText: trimmedText.isEmpty ? nil : trimmedText,
                        createdAt: timestamp,
                        updatedAt: timestamp,
                        itemDate: itemDate,
                        itemTimeZoneIdentifier: resolvedTimeZone,
                        localDay: localDay(for: itemDate, timeZoneIdentifier: resolvedTimeZone),
                        latitude: earliestPhoto?.latitude ?? latitude,
                        longitude: earliestPhoto?.longitude ?? longitude,
                        locationName: earliestPhoto?.locationName ?? locationName,
                        countryCode: earliestPhoto?.countryCode ?? countryCode,
                        deletedAt: nil
                    )
                }
                .execute(db)
                for (draft, prepared) in preparedPhotos {
                    try insertPhoto(
                        draft: draft,
                        prepared: prepared,
                        blog: blog,
                        blogger: blogger,
                        blogItemID: id,
                        timestamp: timestamp,
                        in: db
                    )
                }
            }
        } catch {
            removeNewMediaFiles(preparedPhotos.map(\.1))
            throw error
        }
        AppTelemetry.record(
            "Blog item created",
            category: "journal.mutation",
            data: ["photo_count": photos.count]
        )
        return id
    }

    func updateBlogItem(_ request: BlogItemUpdateRequest) throws {
        let trimmedText = request.blogText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !request.photos.isEmpty else {
            throw JournalServiceError.emptyBlogItem
        }
        let additions = request.photos.compactMap { update -> BlogItemPhotoAssetDraft? in
            guard case .added(let draft) = update else { return nil }
            return draft
        }
        let preparedAdditions = try additions.map { draft in
            (draft, try prepareMediaAsset(from: draft))
        }
        var candidateAssets: [MediaAsset] = []
        var orphanedAssets: [MediaAsset] = []
        do {
            try database.write { db in
                let blog = try requireActiveBlog(in: db)
                guard let blogger = try selectedBlogger(in: db, blogID: blog.id) else {
                    throw JournalCreationError.missingWorkspace
                }
                let item = try BlogItem.find(db, key: request.id)
                guard item.blogID == blog.id else {
                    throw JournalServiceError.inactiveBlogMutation
                }
                let existingPhotos = try PhotoItem
                    .where { $0.blogItemID.eq(item.id) }
                    .fetchAll(db)
                let retainedDisplays = request.photos.compactMap { update -> PhotoItemDisplay? in
                    guard case .existing(let display) = update else { return nil }
                    return display
                }
                let retainedIDs = Set(retainedDisplays.map(\.id))
                guard retainedIDs.isSubset(of: Set(existingPhotos.map(\.id))) else {
                    throw JournalServiceError.inactiveBlogMutation
                }
                for display in retainedDisplays {
                    try PhotoItem.find(display.id).update {
                        $0.photoCaption = #bind(display.caption.trimmingCharacters(in: .whitespacesAndNewlines))
                        $0.photoDate = #bind(display.date)
                        $0.updatedAt = #bind(now())
                    }
                    .execute(db)
                }
                for photo in existingPhotos where !retainedIDs.contains(photo.id) {
                    if let asset = try MediaAsset.find(photo.mediaAssetID).fetchOne(db) {
                        candidateAssets.append(asset)
                    }
                    try PhotoItem.find(photo.id).delete().execute(db)
                }
                for (draft, prepared) in preparedAdditions {
                    try insertPhoto(
                        draft: draft,
                        prepared: prepared,
                        blog: blog,
                        blogger: blogger,
                        blogItemID: item.id,
                        timestamp: now(),
                        in: db
                    )
                }
                let replacingOnlyPhoto = existingPhotos.count == 1
                    && retainedIDs.isEmpty
                    && additions.count == 1
                let resolvedDate = replacingOnlyPhoto ? additions[0].photoDate : request.date
                let replacement = replacingOnlyPhoto ? additions[0] : nil
                let resolvedTimeZone = replacement?.timeZoneIdentifier ?? item.itemTimeZoneIdentifier
                let editedAt = now()
                try BlogItem.find(item.id).update {
                    $0.blogText = #bind(trimmedText.isEmpty ? nil : trimmedText)
                    $0.itemDate = #bind(resolvedDate)
                    $0.itemTimeZoneIdentifier = #bind(resolvedTimeZone)
                    $0.localDay = #bind(localDay(for: resolvedDate, timeZoneIdentifier: resolvedTimeZone))
                    $0.locationName = #bind(replacement?.locationName ?? request.location)
                    $0.latitude = #bind(replacement?.latitude ?? request.latitude ?? item.latitude)
                    $0.longitude = #bind(replacement?.longitude ?? request.longitude ?? item.longitude)
                    $0.countryCode = #bind(replacement?.countryCode ?? item.countryCode)
                    $0.weatherTemperatureCelsius = #bind(TemperatureValue.normalized(request.temperatureCelsius))
                    $0.weatherConditionCode = #bind(request.weatherCondition)
                    $0.updatedAt = #bind(editedAt)
                    $0.lastEditorID = #bind(blogger.id)
                    $0.lastEditedAt = #bind(editedAt)
                }
                .execute(db)
                orphanedAssets = try deleteUnreferencedAssets(candidateAssets, in: db)
            }
        } catch {
            removeNewMediaFiles(preparedAdditions.map(\.1))
            throw error
        }
        removeMediaFiles(orphanedAssets)
        AppTelemetry.record(
            "Blog item updated",
            category: "journal.mutation",
            data: ["photo_count": request.photos.count]
        )
    }

    func deleteBlogItem(id: BlogItem.ID) throws {
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let item = try BlogItem.find(db, key: id)
            guard item.blogID == blog.id else {
                throw JournalServiceError.inactiveBlogMutation
            }
            let timestamp = now()
            try BlogItem.find(id).update {
                $0.deletedAt = #bind(timestamp)
                $0.updatedAt = #bind(timestamp)
            }
            .execute(db)
        }
        AppTelemetry.record("Blog item deleted", category: "journal.mutation")
    }

    func recoverBlogItem(id: BlogItem.ID) throws {
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let item = try BlogItem.find(db, key: id)
            guard item.blogID == blog.id else { throw JournalServiceError.inactiveBlogMutation }
            guard item.deletedAt != nil else { throw JournalServiceError.blogItemNotDeleted }
            try BlogItem.find(id).update {
                $0.deletedAt = #bind(Date?.none)
                $0.updatedAt = #bind(now())
            }.execute(db)
        }
    }

    func permanentlyDeleteBlogItem(id: BlogItem.ID) throws {
        var orphanedAssets: [MediaAsset] = []
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let item = try BlogItem.find(db, key: id)
            guard item.blogID == blog.id else { throw JournalServiceError.inactiveBlogMutation }
            guard item.deletedAt != nil else { throw JournalServiceError.blogItemNotDeleted }
            let photos = try PhotoItem.where { $0.blogItemID.eq(id) }.fetchAll(db)
            var candidateAssets: [MediaAsset] = []
            for photo in photos {
                if let asset = try MediaAsset.find(photo.mediaAssetID).fetchOne(db) {
                    candidateAssets.append(asset)
                }
                try PhotoItem.find(photo.id).delete().execute(db)
            }
            try BlogItem.find(id).delete().execute(db)
            orphanedAssets = try deleteUnreferencedAssets(candidateAssets, in: db)
        }
        removeMediaFiles(orphanedAssets)
    }

    func makeBlankBlogItemDraft(after source: BlogItemDisplay) throws -> BlogItemDisplay {
        let sourceLocalDay = localDay(
            for: source.date,
            timeZoneIdentifier: source.timeZoneIdentifier
        )
        let (author, nextItemDate) = try database.read { db in
            let blog = try requireActiveBlog(in: db)
            guard let blogger = try selectedBlogger(in: db, blogID: blog.id) else {
                throw JournalCreationError.missingWorkspace
            }
            let nextItemDate = try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { $0.localDay.eq(sourceLocalDay) }
                .where { !$0.deletedAt.isNot(nil) }
                .fetchAll(db)
                .map(\.itemDate)
                .filter { $0 > source.date }
                .min()
            return (blogger.displayName, nextItemDate)
        }

        return BlogItemDisplay(
            id: UUID(),
            author: author,
            date: blankBlogItemDate(after: source, nextItemDate: nextItemDate),
            timeZoneIdentifier: source.timeZoneIdentifier ?? TimeZone.autoupdatingCurrent.identifier,
            blogText: "",
            location: "",
            weather: WeatherDisplay(),
            photos: [],
            syncStatus: .storedLocally
        )
    }

    private func blankBlogItemDate(
        after source: BlogItemDisplay,
        nextItemDate: Date?
    ) -> Date {
        if let nextItemDate {
            return source.date.addingTimeInterval(nextItemDate.timeIntervalSince(source.date) / 2)
        }

        let fiveMinutesLater = source.date.addingTimeInterval(5 * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        guard let midnight = calendar.dateInterval(of: .day, for: source.date)?.end,
              fiveMinutesLater >= midnight else {
            return fiveMinutesLater
        }
        return source.date.addingTimeInterval(midnight.timeIntervalSince(source.date) / 2)
    }

    func captureWeather(for id: BlogItem.ID) async {
        do {
            let location = try await locationProvider.currentLocation()
            async let placeName = placeNameProvider.placeName(for: location)
            async let weather = fetchWeatherCapture()
            try await persistWeatherEnrichment(
                for: id,
                location: location,
                placeName: placeName,
                weather: weather
            )
        } catch {
            AppTelemetry.log(
                "Weather enrichment failed",
                category: "weather.enrichment",
                level: .warning,
                error: error
            )
        }
    }

    func captureHistoricalWeather(
        for id: BlogItem.ID,
        date: Date,
        latitude: Double,
        longitude: Double,
        locationName: String
    ) async {
        let location = WeatherLocation(latitude: latitude, longitude: longitude)
        do {
            let weather = try await weatherProvider.weather(for: location, near: date)
            try await persistWeatherEnrichment(
                for: id,
                location: location,
                placeName: locationName,
                weather: weather
            )
        } catch {
            AppTelemetry.log(
                "Historical weather enrichment failed",
                category: "weather.enrichment",
                level: .warning,
                error: error
            )
        }
    }

    func capturePlaceName(for id: BlogItem.ID, location: WeatherLocation) async {
        do {
            let placeName = try await placeNameProvider.placeName(for: location)
            try await database.write { db in
                try BlogItem.find(id).update {
                    $0.locationName = #bind(placeName)
                    $0.updatedAt = #bind(now())
                }
                .execute(db)
            }
        } catch {
            AppTelemetry.log(
                "Place-name enrichment failed",
                category: "location.enrichment",
                level: .warning,
                error: error
            )
        }
    }

    private func makeDisplayTrip(_ trip: Trip, items: [BlogItemDisplay]) -> TripDisplay {
        TripDisplay(
            id: trip.id,
            kind: .trip,
            title: trip.title,
            description: trip.description,
            startLocalDay: trip.startLocalDay,
            endLocalDay: trip.endLocalDay,
            closedAt: trip.closedAt,
            days: displayDays(from: items, newestFirst: trip.endLocalDay == nil)
        )
    }

    private func makeUnassignedDisplay(items: [BlogItemDisplay]) -> TripDisplay {
        let days = displayDays(from: items, newestFirst: true)
        return TripDisplay(
            id: TripDisplay.unassignedID,
            kind: .unassigned,
            title: "Unassigned",
            startLocalDay: days.last?.localDay ?? "",
            endLocalDay: days.first?.localDay,
            days: days
        )
    }

    private func displayDays(
        from items: [BlogItemDisplay],
        newestFirst: Bool
    ) -> [DayPostDisplay] {
        let byDay = Dictionary(grouping: items) {
            localDay(for: $0.date, timeZoneIdentifier: $0.timeZoneIdentifier)
        }
        let sortedDays = byDay.keys.sorted(by: newestFirst ? (>) : (<))
        var previousLocation: String?
        return sortedDays.compactMap { localDay in
            guard let items = byDay[localDay]?.sorted(by: { lhs, rhs in
                if lhs.date != rhs.date { return newestFirst ? lhs.date > rhs.date : lhs.date < rhs.date }
                return lhs.id.uuidString < rhs.id.uuidString
            }), let first = items.first else { return nil }
            let route = route(for: items, startingAt: previousLocation)
            previousLocation = items.reversed().compactMap { routeLocationDisplay(for: $0.location) }.first
                ?? previousLocation
            return DayPostDisplay(
                id: first.id,
                date: first.date,
                localDay: localDay,
                route: route,
                blogItems: items
            )
        }
    }

    private func makeDisplayItem(
        _ item: BlogItem,
        photoItems: [PhotoItem],
        bloggersByID: [Blogger.ID: Blogger],
        mediaByID: [MediaAsset.ID: MediaAsset],
        isShared: Bool,
        isBlogItemUploaded: Bool,
        uploadedPhotoItemIDs: Set<PhotoItem.ID>
    ) -> BlogItemDisplay {
        var dependencies: [SyncDependencyState] = [isBlogItemUploaded ? .synced : .pending]
        var displays: [PhotoItemDisplay] = []
        for photoItem in photoItems.sorted(by: photoItemSort) {
            guard let media = mediaByID[photoItem.mediaAssetID] else {
                dependencies.append(.failed)
                displays.append(
                    PhotoItemDisplay(
                        id: photoItem.id,
                        date: photoItem.photoDate,
                        caption: photoItem.photoCaption ?? "",
                        availability: .unavailable
                    )
                )
                continue
            }
            let localPath = resolveExistingLocalImagePath(for: media)
                ?? resolveExistingCacheImagePath(for: media)
            let palette: JournalPalette? = localPath == nil
                ? JournalPalette(rawValue: (media.filename as NSString).deletingPathExtension)
                : nil
            let availability: BlogItemPhotoAvailability
            if let photoAvailabilityOverride {
                availability = photoAvailabilityOverride
            } else if localPath != nil {
                availability = .available
            } else if media.cloudAssetIdentifier?.isEmpty == false && media.externalSyncState != .failed {
                availability = .downloading
            } else if palette != nil {
                availability = .none
            } else {
                availability = .unavailable
            }
            let photoRecordState: SyncDependencyState = uploadedPhotoItemIDs.contains(photoItem.id)
                ? .synced : .pending
            dependencies.append(photoRecordState)
            dependencies.append(media.externalSyncState)
            displays.append(
                PhotoItemDisplay(
                    id: photoItem.id,
                    date: photoItem.photoDate,
                    caption: photoItem.photoCaption ?? "",
                        availability: availability,
                        localImagePath: localPath,
                        pixelWidth: media.pixelWidth,
                        pixelHeight: media.pixelHeight,
                        palette: palette
                )
            )
        }
        let aggregate = dependencies.reduce(SyncDependencyState.notRequired) { result, state in
            if result == .failed || state == .failed { return .failed }
            if result == .pending || state == .pending { return .pending }
            if result == .synced || state == .synced { return .synced }
            return .notRequired
        }
        let syncStatus = syncStatusOverride ?? BlogItemSyncStatus.resolve(
            record: aggregate,
            media: aggregate,
            isShared: isShared
        )
        let conditionCode = item.weatherConditionCode
        return BlogItemDisplay(
            id: item.id,
            author: bloggersByID[item.authorID]?.displayName ?? BootstrapDefaults.bloggerDisplayName,
            lastEditor: item.lastEditorID.flatMap { bloggersByID[$0]?.displayName },
            date: item.itemDate,
            createdAt: item.createdAt,
            lastEditedAt: item.lastEditedAt,
            timeZoneIdentifier: item.itemTimeZoneIdentifier,
            blogText: item.blogText ?? "",
            location: item.locationName ?? "",
            latitude: item.latitude,
            longitude: item.longitude,
            weather: WeatherDisplay(
                temperatureCelsius: item.weatherTemperatureCelsius.map(TemperatureValue.normalized),
                conditionCode: conditionCode,
                condition: conditionCode.map(WeatherConditionCatalog.description(for:)),
                systemImage: conditionCode.map(WeatherConditionCatalog.systemImage(for:))
            ),
            photos: displays,
            syncStatus: syncStatus
        )
    }

    private func prepareMediaAsset(from draft: BlogItemPhotoAssetDraft) throws -> PreparedMediaAsset {
        let contentHash = SHA256.hash(data: draft.imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        let filename = "\(contentHash).\(MediaStoragePaths.preferredFileExtension(for: draft.mimeType))"
        let mediaURL = mediaDirectoryURL.appendingPathComponent(filename)
        try fileManager.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)
        let createdOriginal = !fileManager.fileExists(atPath: mediaURL.path)
        if createdOriginal {
            try draft.imageData.write(to: mediaURL, options: .atomic)
        }
        return PreparedMediaAsset(
            id: UUID(),
            storedFilename: filename,
            mimeType: draft.mimeType,
            photoLibraryAssetIdentifier: draft.photoLibraryAssetIdentifier,
            contentHash: contentHash,
            createdOriginal: createdOriginal,
            mediaURL: mediaURL
        )
    }

    private func insertPhoto(
        draft: BlogItemPhotoAssetDraft,
        prepared: PreparedMediaAsset,
        blog: Blog,
        blogger: Blogger,
        blogItemID: BlogItem.ID,
        timestamp: Date,
        in db: Database
    ) throws {
        try MediaAsset.insert {
            prepared.draft(
                id: prepared.id,
                blogID: blog.id,
                createdAt: timestamp,
                pixelWidth: draft.pixelWidth,
                pixelHeight: draft.pixelHeight,
                photoLibraryAssetUploaderID: draft.photoLibraryAssetIdentifier == nil ? nil : blogger.id
            )
        }
        .execute(db)
        let trimmedCaption = draft.photoCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        try PhotoItem.insert {
            PhotoItem.Draft(
                id: UUID(),
                blogID: blog.id,
                blogItemID: blogItemID,
                mediaAssetID: prepared.id,
                photoCaption: trimmedCaption.isEmpty ? nil : trimmedCaption,
                photoDate: draft.photoDate,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
        .execute(db)
    }

    private func deleteUnreferencedAssets(
        _ candidates: [MediaAsset],
        in db: Database
    ) throws -> [MediaAsset] {
        var deleted: [MediaAsset] = []
        for asset in candidates {
            let photoReferenceCount = try PhotoItem
                .where { $0.mediaAssetID.eq(asset.id) }
                .fetchCount(db)
            let tripReferenceCount = try Trip
                .where { $0.heroImageAssetID.eq(asset.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .fetchCount(db)
            if photoReferenceCount == 0 && tripReferenceCount == 0 {
                try MediaAsset.find(asset.id).delete().execute(db)
                let sharedFileCount = try MediaAsset
                    .where { $0.filename.eq(asset.filename) }
                    .fetchCount(db)
                if sharedFileCount == 0 {
                    deleted.append(asset)
                }
            }
        }
        return deleted
    }

    private func removeNewMediaFiles(_ prepared: [PreparedMediaAsset]) {
        for asset in prepared where asset.createdOriginal {
            mediaFileCleanup.removeItem(at: asset.mediaURL)
        }
    }

    private func removeMediaFiles(_ assets: [MediaAsset]) {
        for asset in assets {
            mediaFileCleanup.removeItem(at: durableMediaURL(for: asset))
            mediaFileCleanup.removeItem(at: cacheMediaURL(for: asset))
        }
    }

    private func photoItemSort(_ lhs: PhotoItem, _ rhs: PhotoItem) -> Bool {
        if lhs.photoDate != rhs.photoDate { return lhs.photoDate < rhs.photoDate }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func selectedBlog(in db: Database) throws -> Blog? {
        try requireActiveBlog(in: db)
    }

    private func selectedBlogger(in db: Database, blogID: Blog.ID?) throws -> Blogger? {
        guard let blogID else { return nil }
        if let bloggerID {
            let blogger = try Blogger.find(bloggerID).fetchOne(db)
            guard blogger?.blogID == blogID else { throw JournalServiceError.inactiveBlogger }
            return blogger
        }
        return try Blogger
            .where { $0.blogID.eq(blogID) }
            .order { ($0.createdAt, $0.id) }
            .fetchOne(db)
    }

    private func requireActiveBlog(in db: Database) throws -> Blog {
        let workspaceBlogID = try AppWorkspace
            .find(AppWorkspace.singletonID)
            .select(\.activeBlogID)
            .fetchOne(db) ?? nil
        let oldestBlogID = try Blog.order { ($0.createdAt, $0.id) }.select(\.id).fetchOne(db)
        let activeBlogID = workspaceBlogID ?? blogID ?? oldestBlogID
        guard let activeBlogID, let blog = try Blog.find(activeBlogID).fetchOne(db) else {
            throw JournalServiceError.missingBlog
        }
        guard self.blogID == nil || self.blogID == activeBlogID else {
            throw JournalServiceError.inactiveBlogMutation
        }
        if let bloggerID {
            guard let blogger = try Blogger.find(bloggerID).fetchOne(db), blogger.blogID == blog.id else {
                throw JournalServiceError.inactiveBlogger
            }
        }
        return blog
    }

    private func validateTripRange(
        in db: Database,
        candidate: TripValidationCandidate
    ) throws {
        let blog = try requireActiveBlog(in: db)
        let trips = try Trip
            .where { $0.blogID.eq(blog.id) }
            .where { !$0.deletedAt.isNot(nil) }
            .fetchAll(db)
            .map {
                TripValidationCandidate(
                    id: $0.id,
                    startLocalDay: $0.startLocalDay,
                    endLocalDay: $0.endLocalDay
                )
            }
        switch TripValidation.validate(
            candidate: candidate,
            against: trips,
            todayLocalDay: localDay(for: now(), timeZoneIdentifier: nil)
        ) {
        case .valid:
            return
        case .overlapsAnotherTrip:
            throw JournalServiceError.overlapsAnotherTrip
        case .multipleOpenTrips:
            throw JournalServiceError.multipleOpenTrips
        }
    }

    private func fetchWeatherCapture() async throws -> WeatherCapture {
        let location = try await locationProvider.currentLocation()
        return try await weatherProvider.currentWeather(for: location)
    }

    private func persistWeatherEnrichment(
        for id: BlogItem.ID,
        location: WeatherLocation,
        placeName: String?,
        weather: WeatherCapture?
    ) async throws {
        try await database.write { db in
            try BlogItem.find(id).update {
                $0.latitude = #bind(location.latitude)
                $0.longitude = #bind(location.longitude)
                $0.locationName = #bind(placeName)
                $0.weatherTemperatureCelsius = #bind(weather.map { Double($0.temperatureCelsius) })
                $0.weatherConditionCode = #bind(weather?.conditionCode)
                $0.updatedAt = #bind(now())
            }
            .execute(db)
        }
    }

    private func resolveExistingLocalImagePath(for mediaAsset: MediaAsset) -> String? {
        let canonicalPath = durableMediaURL(for: mediaAsset).path
        if isReadableRegularFile(atPath: canonicalPath) { return canonicalPath }
        guard let storedPath = mediaAsset.localOriginalPath else { return nil }
        let storedURL = URL(fileURLWithPath: storedPath)
        let resolvedURL = storedPath.hasPrefix("/")
            ? storedURL
            : mediaDirectoryURL.appendingPathComponent(storedPath)
        if isContainedInMediaDirectory(path: resolvedURL.path),
           isReadableRegularFile(atPath: resolvedURL.path) {
            return resolvedURL.path
        }
        let recoveredURL = mediaDirectoryURL.appendingPathComponent(storedURL.lastPathComponent)
        return isReadableRegularFile(atPath: recoveredURL.path) ? recoveredURL.path : nil
    }

    private func resolveExistingCacheImagePath(for mediaAsset: MediaAsset) -> String? {
        let path = cacheMediaURL(for: mediaAsset).path
        return isReadableRegularFile(atPath: path) ? path : nil
    }

    private func isContainedInMediaDirectory(path: String) -> Bool {
        let rootPath = mediaDirectoryURL.standardizedFileURL.path
        let candidatePath = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func isReadableRegularFile(atPath path: String) -> Bool {
        guard fileManager.isReadableFile(atPath: path),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
        else { return false }
        return values.isRegularFile == true
    }

    private func durableMediaURL(for mediaAsset: MediaAsset) -> URL {
        MediaStoragePaths.canonicalURL(for: mediaAsset, in: mediaDirectoryURL)
    }

    private func cacheMediaURL(for mediaAsset: MediaAsset) -> URL {
        mediaCacheDirectoryURL.appendingPathComponent(safeFilename(for: mediaAsset))
    }

    private func safeFilename(for mediaAsset: MediaAsset) -> String {
        "\(mediaAsset.contentHash ?? mediaAsset.id.uuidString).\(MediaStoragePaths.preferredFileExtension(for: mediaAsset.mimeType))"
    }

    private func route(for items: [BlogItemDisplay], startingAt location: String?) -> [String] {
        var route: [String] = []
        var seen = Set<String>()
        for candidate in [location] + items.map(\.location).map(Optional.some) {
            guard let display = routeLocationDisplay(for: candidate) else { continue }
            let key = routeLocationKey(for: display)
            if seen.insert(key).inserted { route.append(display) }
        }
        return route
    }

    private func routeLocationDisplay(for location: String?) -> String? {
        guard let location else { return nil }
        let town = location.split(separator: ",", maxSplits: 1).first.map(String.init) ?? location
        let trimmed = town.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func routeLocationKey(for location: String) -> String {
        location
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    static func defaultMediaDirectoryURL(fileManager: FileManager) -> URL {
        do {
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("BlogItemMedia", isDirectory: true)
        } catch {
            AppTelemetry.log(
                "Application Support unavailable; using temporary media storage",
                category: "media.storage",
                level: .error,
                error: error
            )
            return fileManager.temporaryDirectory
                .appendingPathComponent("BlogItemMedia", isDirectory: true)
        }
    }

    private static func defaultMediaCacheDirectoryURL(fileManager: FileManager) -> URL {
        do {
            return try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("BlogItemMedia", isDirectory: true)
        } catch {
            AppTelemetry.log(
                "Caches directory unavailable; using temporary media cache",
                category: "media.storage",
                level: .warning,
                error: error
            )
            return fileManager.temporaryDirectory
                .appendingPathComponent("BlogItemMedia", isDirectory: true)
        }
    }
}

private nonisolated struct PreparedMediaAsset {
    let id: MediaAsset.ID
    let storedFilename: String
    let mimeType: String
    let photoLibraryAssetIdentifier: String?
    let contentHash: String
    let createdOriginal: Bool
    let mediaURL: URL

    func draft(
        id: MediaAsset.ID,
        blogID: Blog.ID,
        createdAt: Date,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        photoLibraryAssetUploaderID: Blogger.ID? = nil
    ) -> MediaAsset.Draft {
        MediaAsset.Draft(
            id: id,
            blogID: blogID,
            localOriginalPath: storedFilename,
            photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
            photoLibraryAssetUploaderID: photoLibraryAssetUploaderID,
            contentHash: contentHash,
            filename: storedFilename,
            mimeType: mimeType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private nonisolated struct JournalLoadSnapshot {
    let trips: [Trip]
    let bloggers: [Blogger]
    let blogItems: [BlogItem]
    let photoItems: [PhotoItem]
    let mediaAssets: [MediaAsset]
    let isShared: Bool
    let uploadedBlogItemIDs: Set<BlogItem.ID>
    let uploadedPhotoItemIDs: Set<PhotoItem.ID>
}

nonisolated struct JournalTripPartitionInput: Sendable, Equatable {
    let id: BlogItem.ID
    let localDay: String
    let sequence: Int
}

nonisolated struct JournalTripPartition: Sendable, Equatable {
    let itemIDsByTripID: [Trip.ID: [BlogItem.ID]]
    let unassignedItemIDs: [BlogItem.ID]
    let inspectedTripCount: Int
}

nonisolated enum JournalTripPartitioner {
    /// Partitions items already ordered by `localDay` against non-overlapping trips ordered by start day.
    static func partition(
        items: [JournalTripPartitionInput],
        trips: [Trip],
        referenceDay: String
    ) -> JournalTripPartition {
        var itemIDsByTripID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, [BlogItem.ID]()) })
        var unassignedItemIDs: [BlogItem.ID] = []
        var tripIndex = 0
        var inspectedTripCount = 0

        for item in items {
            while tripIndex < trips.count {
                let trip = trips[tripIndex]
                let endLocalDay = trip.endLocalDay ?? referenceDay
                guard endLocalDay < item.localDay else { break }
                tripIndex += 1
                inspectedTripCount += 1
            }

            guard tripIndex < trips.count else {
                unassignedItemIDs.append(item.id)
                continue
            }

            let trip = trips[tripIndex]
            if trip.startLocalDay <= item.localDay {
                itemIDsByTripID[trip.id, default: []].append(item.id)
            } else {
                unassignedItemIDs.append(item.id)
            }
        }

        return JournalTripPartition(
            itemIDsByTripID: itemIDsByTripID,
            unassignedItemIDs: unassignedItemIDs,
            inspectedTripCount: inspectedTripCount
        )
    }
}

enum JournalCreationError: Error {
    case missingWorkspace
}

enum JournalServiceError: LocalizedError, Equatable {
    case missingBlog
    case inactiveBlogMutation
    case inactiveBlogger
    case overlapsAnotherTrip
    case multipleOpenTrips
    case emptyBlogItem
    case blogItemNotDeleted

    var errorDescription: String? {
        switch self {
        case .missingBlog:
            "The active Blog could not be found."
        case .inactiveBlogMutation:
            "This item belongs to a Blog that is no longer active."
        case .inactiveBlogger:
            "The active Blogger does not belong to the active Blog."
        case .overlapsAnotherTrip:
            "Overlaps another trip."
        case .multipleOpenTrips:
            "There may only be one open trip."
        case .emptyBlogItem:
            "A post must contain text or at least one photo."
        case .blogItemNotDeleted:
            "Only a deleted post can be recovered or deleted forever."
        }
    }
}
