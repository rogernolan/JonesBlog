import Foundation
import CryptoKit
import CoreLocation
import MapKit
import OSLog
import SQLiteData
import WeatherKit

nonisolated struct WeatherCapture: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var temperatureCelsius: Int
    var conditionCode: String
}

nonisolated struct WeatherLocation: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

nonisolated struct WeatherAttributionDisplay: Equatable, Sendable {
    var combinedMarkLightURL: URL
    var combinedMarkDarkURL: URL
    var legalPageURL: URL
    var legalAttributionText: String
}

private nonisolated enum WeatherEnrichmentLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "InstaBlog",
        category: "WeatherEnrichment"
    )

    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[WeatherEnrichment] \(message)")
    }

    static func error(_ message: String, error: Error? = nil) {
        if let error {
            let nsError = error as NSError
            let detailedMessage = "\(message) [\(nsError.domain) code \(nsError.code)] \(nsError.localizedDescription)"
            logger.error("\(detailedMessage, privacy: .public)")
            print("[WeatherEnrichment] ERROR: \(detailedMessage)")
        } else {
            logger.error("\(message, privacy: .public)")
            print("[WeatherEnrichment] ERROR: \(message)")
        }
    }
}

nonisolated protocol CurrentLocationProviding: Sendable {
    @MainActor func requestPermissionIfNeeded() async
    @MainActor func currentLocation() async throws -> WeatherLocation
}

nonisolated protocol WeatherProviding: Sendable {
    func currentWeather(for location: WeatherLocation) async throws -> WeatherCapture
    func weather(for location: WeatherLocation, near date: Date) async throws -> WeatherCapture?
}

nonisolated protocol PlaceNameProviding: Sendable {
    func placeName(for location: WeatherLocation) async throws -> String?
}

nonisolated protocol WeatherAttributing: Sendable {
    func attribution() async throws -> WeatherAttributionDisplay
}

final class CurrentLocationProvider: NSObject, CurrentLocationProviding, CLLocationManagerDelegate, @unchecked Sendable {
    private let maxTransientFailureCount = 6
    private let requestTimeout: TimeInterval = 6
    private let acceptableCachedLocationAge: TimeInterval = 15 * 60
    private let manager = CLLocationManager()
    private var permissionContinuations: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<WeatherLocation, Error>?
    private var transientFailureCount = 0
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestPermissionIfNeeded() async {
        guard manager.authorizationStatus == .notDetermined else { return }

        WeatherEnrichmentLog.notice("Requesting when-in-use location permission on first launch.")
        await withCheckedContinuation { continuation in
            permissionContinuations.append(continuation)
            if permissionContinuations.count == 1 {
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    func currentLocation() async throws -> WeatherLocation {
        if continuation != nil {
            WeatherEnrichmentLog.error("Location request rejected because another request is already in progress.")
            throw CurrentLocationError.requestInProgress
        }

        if let cachedLocation = cachedLocation() {
            WeatherEnrichmentLog.notice(
                "Using cached location from \(cachedLocation.timestamp.formatted()) with horizontal accuracy \(cachedLocation.horizontalAccuracy.formatted(.number.precision(.fractionLength(1)))) meters."
            )
            return WeatherLocation(
                latitude: cachedLocation.coordinate.latitude,
                longitude: cachedLocation.coordinate.longitude
            )
        }

        transientFailureCount = 0
        WeatherEnrichmentLog.notice("Starting location lookup. Authorization status: \(Self.authorizationDescription(self.manager.authorizationStatus))")

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                WeatherEnrichmentLog.notice("Location already authorized. Requesting one-shot location.")
                requestLocation()
            case .notDetermined:
                WeatherEnrichmentLog.notice("Location permission not determined. Requesting when-in-use authorization.")
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                WeatherEnrichmentLog.error("Location request failed because authorization is denied or restricted.")
                resume(with: .failure(CurrentLocationError.authorizationDenied))
            @unknown default:
                WeatherEnrichmentLog.error("Location request failed because authorization status is unavailable.")
                resume(with: .failure(CurrentLocationError.unavailable))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined, !permissionContinuations.isEmpty {
            let pendingContinuations = permissionContinuations
            permissionContinuations.removeAll()
            pendingContinuations.forEach { $0.resume() }
        }

        guard continuation != nil else { return }
        WeatherEnrichmentLog.notice("Location authorization changed to \(Self.authorizationDescription(manager.authorizationStatus))")
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            WeatherEnrichmentLog.notice("Authorization granted. Requesting one-shot location.")
            requestLocation()
        case .denied, .restricted:
            WeatherEnrichmentLog.error("Location request failed after authorization change because access was denied or restricted.")
            resume(with: .failure(CurrentLocationError.authorizationDenied))
        case .notDetermined:
            break
        @unknown default:
            WeatherEnrichmentLog.error("Location request failed after authorization change because status is unavailable.")
            resume(with: .failure(CurrentLocationError.unavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            WeatherEnrichmentLog.error("Location manager returned no locations.")
            resume(with: .failure(CurrentLocationError.unavailable))
            return
        }
        guard location.horizontalAccuracy >= 0 else {
            retryTransientLocationFailure(reason: "Location manager returned an invalid coordinate.")
            return
        }
        WeatherEnrichmentLog.notice("Received location update with horizontal accuracy \(location.horizontalAccuracy.formatted(.number.precision(.fractionLength(1)))) meters.")
        resume(
            with: .success(
                WeatherLocation(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            )
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown {
            retryTransientLocationFailure(reason: "Location manager returned a transient locationUnknown error.", error: error)
            return
        }
        WeatherEnrichmentLog.error("Location manager failed.", error: error)
        resume(with: .failure(error))
    }

    private func resume(with result: Result<WeatherLocation, Error>) {
        guard let continuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func retryTransientLocationFailure(reason: String, error: Error? = nil) {
        guard transientFailureCount < maxTransientFailureCount else {
            WeatherEnrichmentLog.error("\(reason) Exhausted retry budget.", error: error)
            resume(with: .failure(error ?? CurrentLocationError.unavailable))
            return
        }

        transientFailureCount += 1
        WeatherEnrichmentLog.notice("\(reason) Retrying location request (\(transientFailureCount)/\(maxTransientFailureCount)).")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.requestLocation()
        }
    }

    private func cachedLocation() -> CLLocation? {
        guard let location = manager.location else { return nil }
        guard location.horizontalAccuracy >= 0 else { return nil }
        guard abs(location.timestamp.timeIntervalSinceNow) <= acceptableCachedLocationAge else { return nil }
        return location
    }

    private func startTimeoutIfNeeded() {
        guard timeoutTask == nil else { return }
        let requestTimeout = self.requestTimeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(requestTimeout))
            guard let self, self.continuation != nil else { return }

            if let cachedLocation = self.cachedLocation() {
                WeatherEnrichmentLog.notice("Location request timed out. Falling back to cached location from \(cachedLocation.timestamp.formatted()).")
                self.resume(
                    with: .success(
                        WeatherLocation(
                            latitude: cachedLocation.coordinate.latitude,
                            longitude: cachedLocation.coordinate.longitude
                        )
                    )
                )
            } else {
                WeatherEnrichmentLog.error("Location request timed out without any cached location.")
                self.resume(with: .failure(CurrentLocationError.unavailable))
            }
        }
    }

    private func requestLocation() {
        startTimeoutIfNeeded()
        manager.requestLocation()
    }

    private static func authorizationDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "authorizedAlways"
        case .authorizedWhenInUse:
            return "authorizedWhenInUse"
        @unknown default:
            return "unknown"
        }
    }
}

nonisolated enum MediaStoragePaths {
    static func canonicalURL(for mediaAsset: MediaAsset, in directory: URL) -> URL {
        if let contentHash = mediaAsset.contentHash {
            return directory.appendingPathComponent(
                "\(contentHash).\(preferredFileExtension(for: mediaAsset.mimeType))"
            )
        }
        return directory.appendingPathComponent(mediaAsset.filename)
    }

    static func preferredFileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": "png"
        case "image/heic": "heic"
        default: "jpg"
        }
    }
}

nonisolated struct LiveWeatherProvider: WeatherProviding {
    func currentWeather(for location: WeatherLocation) async throws -> WeatherCapture {
        let weatherLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        WeatherEnrichmentLog.notice("Requesting current WeatherKit conditions for the captured location.")
        let current = try await WeatherService.shared.weather(for: weatherLocation, including: .current)
        WeatherEnrichmentLog.notice(
            "WeatherKit returned \(current.condition.rawValue) at \(current.temperature.converted(to: .celsius).value.formatted(.number.precision(.fractionLength(1)))) C."
        )
        return WeatherCapture(
            latitude: location.latitude,
            longitude: location.longitude,
            temperatureCelsius: Int(current.temperature.converted(to: .celsius).value.rounded()),
            conditionCode: current.condition.rawValue
        )
    }

    func weather(for location: WeatherLocation, near date: Date) async throws -> WeatherCapture? {
        let weatherLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let startDate = date.addingTimeInterval(-2 * 60 * 60)
        let endDate = date.addingTimeInterval(2 * 60 * 60)

        WeatherEnrichmentLog.notice(
            "Requesting historical WeatherKit conditions near \(date.formatted(date: .abbreviated, time: .shortened))."
        )

        let hourlyForecast = try await WeatherService.shared.weather(
            for: weatherLocation,
            including: .hourly(startDate: startDate, endDate: endDate)
        )

        guard let nearestHour = hourlyForecast.forecast.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }) else {
            WeatherEnrichmentLog.notice("WeatherKit returned no hourly data for the requested historical window.")
            return nil
        }

        WeatherEnrichmentLog.notice(
            "WeatherKit matched historical hour at \(nearestHour.date.formatted(date: .abbreviated, time: .shortened)) with \(nearestHour.condition.rawValue) and \(nearestHour.temperature.converted(to: .celsius).value.formatted(.number.precision(.fractionLength(1)))) C."
        )

        return WeatherCapture(
            latitude: location.latitude,
            longitude: location.longitude,
            temperatureCelsius: Int(nearestHour.temperature.converted(to: .celsius).value.rounded()),
            conditionCode: nearestHour.condition.rawValue
        )
    }
}

nonisolated struct LiveWeatherAttributionProvider: WeatherAttributing {
    func attribution() async throws -> WeatherAttributionDisplay {
        let attribution = try await WeatherService.shared.attribution
        return WeatherAttributionDisplay(
            combinedMarkLightURL: attribution.combinedMarkLightURL,
            combinedMarkDarkURL: attribution.combinedMarkDarkURL,
            legalPageURL: attribution.legalPageURL,
            legalAttributionText: attribution.legalAttributionText
        )
    }
}

nonisolated final class LivePlaceNameProvider: Sendable, PlaceNameProviding {
    func placeName(for location: WeatherLocation) async throws -> String? {
        let location = CLLocation(latitude: location.latitude, longitude: location.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let mapItems = try await request.mapItems
        let item = mapItems.first
        return item?.addressRepresentations?.cityName
            ?? item?.name
            ?? item?.address?.shortAddress
    }
}

nonisolated enum CurrentLocationError: Error {
    case authorizationDenied
    case requestInProgress
    case unavailable
}

private actor WeatherCapturePrimer {
    private let freshnessWindow: TimeInterval = 10 * 60
    private var cachedCapture: WeatherCapture?
    private var cachedAt: Date?
    private var inFlightTask: Task<WeatherCapture, Error>?

    func capture(
        now: Date,
        load: @Sendable @escaping () async throws -> WeatherCapture
    ) async throws -> WeatherCapture {
        if let cachedCapture, let cachedAt,
           now.timeIntervalSince(cachedAt) <= freshnessWindow {
            return cachedCapture
        }

        if let inFlightTask {
            return try await inFlightTask.value
        }

        let task = Task {
            try await load()
        }
        inFlightTask = task

        do {
            let capture = try await task.value
            cachedCapture = capture
            cachedAt = now
            inFlightTask = nil
            return capture
        } catch {
            inFlightTask = nil
            throw error
        }
    }
}

nonisolated struct JournalService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jonesthevan.blog.InstaBlog", category: "PhotoCache")

    let database: any DatabaseWriter
    let now: @Sendable () -> Date
    let fileManager: FileManager
    let mediaDirectoryURL: URL
    let locationProvider: any CurrentLocationProviding
    let weatherProvider: any WeatherProviding
    let placeNameProvider: any PlaceNameProviding
    let weatherAttributionProvider: any WeatherAttributing
    private let weatherCapturePrimer: WeatherCapturePrimer
    let mediaCacheDirectoryURL: URL
    let blogID: Blog.ID?
    let bloggerID: Blogger.ID?
    let syncStatusOverride: BlogItemSyncStatus?
    let photoAvailabilityOverride: BlogItemPhotoAvailability?
    let mediaAssetSyncService: MediaAssetSyncService?

    private nonisolated struct PendingHistoricalWeatherRefresh: Sendable {
        let id: BlogItem.ID
        let date: Date
        let location: WeatherLocation
        let locationName: String
    }

    init(
        database: any DatabaseWriter,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default,
        mediaDirectoryURL: URL? = nil,
        locationProvider: any CurrentLocationProviding = CurrentLocationProvider(),
        weatherProvider: any WeatherProviding = LiveWeatherProvider(),
        placeNameProvider: any PlaceNameProviding = LivePlaceNameProvider(),
        weatherAttributionProvider: any WeatherAttributing = LiveWeatherAttributionProvider(),
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
        self.mediaDirectoryURL = mediaDirectoryURL
            ?? JournalService.defaultMediaDirectoryURL(fileManager: fileManager)
        self.locationProvider = locationProvider
        self.weatherProvider = weatherProvider
        self.placeNameProvider = placeNameProvider
        self.weatherAttributionProvider = weatherAttributionProvider
        self.weatherCapturePrimer = WeatherCapturePrimer()
        self.mediaCacheDirectoryURL = mediaCacheDirectoryURL
            ?? JournalService.defaultMediaCacheDirectoryURL(fileManager: fileManager)
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
        try await fetchPlaceName(for: location)
    }

    func synchronizeMediaAssets() async {
        guard let blogID, let mediaAssetSyncService else { return }
        do {
            try await mediaAssetSyncService.synchronize(blogID: blogID)
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "External photo synchronization failed [\(nsError.domain, privacy: .public) \(nsError.code)]: \(String(describing: error), privacy: .public)"
            )
        }
    }

    func primeWeatherCapture() async {
        WeatherEnrichmentLog.notice("Priming weather enrichment for the camera flow.")
        do {
            _ = try await fetchWeatherCapture()
            WeatherEnrichmentLog.notice("Weather priming completed for the camera flow.")
        } catch {
            WeatherEnrichmentLog.error("Weather priming failed for the camera flow.", error: error)
        }
    }

    func loadCurrentTrip() throws -> TripDisplay? {
        let trips = try loadTrips()
        return trips.first(where: \.isCurrent)
    }

    func loadTrips() throws -> [TripDisplay] {
        let snapshot = try database.read { db -> JournalLoadSnapshot? in
            guard let blog = try selectedBlog(in: db) else {
                return nil
            }
            let trips = try Trip
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.startLocalDay.desc(), $0.createdAt.desc()) }
                .fetchAll(db)
            let bloggers = try Blogger.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let items = try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.itemDate, $0.id) }
                .fetchAll(db)
            let galleries = try Gallery
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .fetchAll(db)
            let dayItems = try DayItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.localDay, $0.placementDate, $0.id) }
                .fetchAll(db)
            let dayItemIDs = dayItems.map(\.id)
            let placements = dayItemIDs.isEmpty
                ? []
                : try BlogItemPlacement
                    .where { $0.dayItemID.in(dayItemIDs) }
                    .order { ($0.dayItemID, $0.position, $0.blogItemID) }
                    .fetchAll(db)
            let referencedMediaIDs = Array(Set(items.compactMap(\.photoAssetID)))
            let mediaAssets: [MediaAsset]
            if referencedMediaIDs.isEmpty {
                mediaAssets = []
            } else {
                mediaAssets = try MediaAsset
                    .where { $0.id.in(referencedMediaIDs) }
                    .fetchAll(db)
            }
            let isShared = (try? SyncMetadata
                .find(blog.syncMetadataID)
                .select(\.isShared)
                .fetchOne(db))
                ?? false
            var uploadedItemIDs = Set<BlogItem.ID>()
            if isShared {
                for item in items {
                    let isUploaded = try SyncMetadata
                        .find(item.syncMetadataID)
                        .select(\.hasLastKnownServerRecord)
                        .fetchOne(db)
                        ?? false
                    if isUploaded {
                        uploadedItemIDs.insert(item.id)
                    }
                }
            }
            let uploadedMediaIDs: Set<MediaAsset.ID> = Set(mediaAssets.compactMap { mediaAsset in
                mediaAsset.externalSyncState == .synced ? mediaAsset.id : nil
            })
            let failedMediaIDs: Set<MediaAsset.ID> = Set(mediaAssets.compactMap { mediaAsset in
                mediaAsset.externalSyncState == .failed ? mediaAsset.id : nil
            })
            return JournalLoadSnapshot(
                blog: blog,
                trips: trips,
                bloggers: bloggers,
                mediaAssets: mediaAssets,
                items: items,
                galleries: galleries,
                dayItems: dayItems,
                placements: placements,
                isShared: isShared,
                uploadedItemIDs: uploadedItemIDs,
                uploadedMediaIDs: uploadedMediaIDs,
                failedMediaIDs: failedMediaIDs
            )
        }
        guard let snapshot else { return [] }

        var localImagePathsByMediaID: [MediaAsset.ID: String] = [:]
        for mediaAsset in snapshot.mediaAssets {
            if let path = resolveExistingLocalImagePath(for: mediaAsset)
                ?? resolveExistingCacheImagePath(for: mediaAsset) {
                localImagePathsByMediaID[mediaAsset.id] = path
                continue
            }
        }

        let bloggersByID: [Blogger.ID: Blogger] = Dictionary(
            snapshot.bloggers.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.updatedAt > current.updatedAt ? candidate : current
            }
        )
        let mediaByID: [MediaAsset.ID: MediaAsset] = Dictionary(
            snapshot.mediaAssets.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.updatedAt > current.updatedAt ? candidate : current
            }
        )
        var displayItemsByID: [BlogItem.ID: BlogItemDisplay] = [:]

        for item in snapshot.items {
            let displayItem = makeDisplayItem(
                item,
                bloggersByID: bloggersByID,
                mediaByID: mediaByID,
                localImagePathsByMediaID: localImagePathsByMediaID,
                isShared: snapshot.isShared,
                isUploaded: snapshot.uploadedItemIDs.contains(item.id),
                isMediaUploaded: item.photoAssetID.map(snapshot.uploadedMediaIDs.contains) ?? true,
                isMediaFailed: item.photoAssetID.map(snapshot.failedMediaIDs.contains) ?? false
            )
            displayItemsByID[item.id] = displayItem
        }

        let galleriesByID = Dictionary(
            snapshot.galleries.map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.updatedAt > current.updatedAt ? candidate : current
            }
        )
        // CloudKit can deliver competing relationship rows out of order. Resolve those
        // deterministically for display until synchronization converges.
        var placementByBlogItemID: [BlogItem.ID: BlogItemPlacement] = [:]
        for placement in snapshot.placements {
            guard let existing = placementByBlogItemID[placement.blogItemID] else {
                placementByBlogItemID[placement.blogItemID] = placement
                continue
            }
            if placement.updatedAt > existing.updatedAt
                || (placement.updatedAt == existing.updatedAt
                    && placement.id.uuidString < existing.id.uuidString) {
                placementByBlogItemID[placement.blogItemID] = placement
            }
        }
        let placementsByDayItemID = Dictionary(
            grouping: Array(placementByBlogItemID.values),
            by: \.dayItemID
        )
        let candidateEntries = snapshot.dayItems.compactMap { dayItem -> JournalPlacedEntry? in
            let placements = (placementsByDayItemID[dayItem.id] ?? []).sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.blogItemID.uuidString < $1.blogItemID.uuidString
            }
            let items = placements.compactMap { displayItemsByID[$0.blogItemID] }
            if let galleryID = dayItem.galleryID,
               let gallery = galleriesByID[galleryID] {
                return JournalPlacedEntry(
                    dayItem: dayItem,
                    entry: .gallery(makeDisplayGallery(gallery, dayItem: dayItem, items: items)),
                    items: items
                )
            }
            guard let item = items.first else { return nil }
            return JournalPlacedEntry(dayItem: dayItem, entry: .blogItem(item), items: [item])
        }
        var placedEntryByID: [UUID: JournalPlacedEntry] = [:]
        for entry in candidateEntries {
            guard let existing = placedEntryByID[entry.entry.id] else {
                placedEntryByID[entry.entry.id] = entry
                continue
            }
            if entry.dayItem.updatedAt > existing.dayItem.updatedAt
                || (entry.dayItem.updatedAt == existing.dayItem.updatedAt
                    && entry.dayItem.id.uuidString < existing.dayItem.id.uuidString) {
                placedEntryByID[entry.entry.id] = entry
            }
        }
        let placedEntries = Array(placedEntryByID.values)

        var displays = snapshot.trips.map { trip in
            makeDisplayTrip(
                trip,
                entries: placedEntries.filter {
                    isDayItem($0.dayItem, includedIn: trip, referenceDate: now())
                }
            )
        }

        let assignedDayItemIDs = Set(
            snapshot.trips.flatMap { trip in
                placedEntries.compactMap {
                    isDayItem($0.dayItem, includedIn: trip, referenceDate: now())
                        ? $0.dayItem.id
                        : nil
                }
            }
        )
        let unassignedEntries = placedEntries.filter { !assignedDayItemIDs.contains($0.dayItem.id) }
        if !unassignedEntries.isEmpty {
            displays.insert(
                makeUnassignedDisplay(entries: unassignedEntries),
                at: 0
            )
        }

        return displays.sorted { lhs, rhs in
            if lhs.isUnassigned != rhs.isUnassigned {
                return lhs.isUnassigned
            }
            if lhs.isCurrent != rhs.isCurrent {
                return lhs.isCurrent
            }
            if lhs.startLocalDay != rhs.startLocalDay {
                return lhs.startLocalDay > rhs.startLocalDay
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
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
            let resolvedClosedAt: Date? = endLocalDay == nil ? nil : (trip.closedAt ?? now())
            try Trip.find(id)
                .update {
                    $0.title = #bind(title)
                    $0.description = #bind(description)
                    $0.startLocalDay = #bind(startLocalDay)
                    $0.endLocalDay = #bind(endLocalDay)
                    $0.closedAt = #bind(resolvedClosedAt)
                    $0.updatedAt = #bind(now())
                }
                .execute(db)
        }
    }

    func updateGalleryInterval(seconds: Int) throws {
        try database.write { db in
            let activeBlog = try requireActiveBlog(in: db)
            try Blog.find(activeBlog.id)
                .update {
                    $0.galleryIntervalSeconds = #bind(seconds)
                    $0.updatedAt = #bind(now())
                }
                .execute(db)
        }
    }

    func updateGalleryDistance(meters: Double) throws {
        try database.write { db in
            let activeBlog = try requireActiveBlog(in: db)
            try Blog.find(activeBlog.id)
                .update {
                    $0.galleryDistanceMeters = #bind(meters)
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
            guard let blog = try selectedBlog(in: db) else {
                throw JournalServiceError.missingBlog
            }
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
        temperatureCelsius: Double,
        weatherCondition: String
    ) throws {
        try updateBlogItem(
            BlogItemUpdateRequest(
                id: id,
                caption: caption,
                date: date,
                location: location,
                latitude: nil,
                longitude: nil,
                temperatureCelsius: temperatureCelsius,
                weatherCondition: weatherCondition,
                photoChange: .unchanged
            )
        )
    }

    func updateBlogItem(_ request: BlogItemUpdateRequest) throws {
        let timestamp = now()
        var preparedReplacement: PreparedMediaAsset?

        if case .replaced(let replacement) = request.photoChange {
            preparedReplacement = try prepareMediaAsset(
                imageData: replacement.imageData,
                mimeType: replacement.mimeType,
                photoLibraryAssetIdentifier: replacement.photoLibraryAssetIdentifier
            )
        }

        do {
            let pendingWeatherRefresh = try database.write { db in
                let activeBlog = try requireActiveBlog(in: db)
                let item = try BlogItem.find(db, key: request.id)
                guard item.blogID == activeBlog.id else {
                    throw JournalServiceError.inactiveBlogMutation
                }

                if let preparedReplacement {
                    let blogger = try selectedBlogger(in: db, blogID: activeBlog.id)
                    try MediaAsset.insert {
                        preparedReplacement.draft(
                            id: preparedReplacement.id,
                            blogID: activeBlog.id,
                            createdAt: timestamp,
                            photoLibraryAssetUploaderID: preparedReplacement.photoLibraryAssetIdentifier == nil ? nil : blogger?.id
                        )
                    }
                    .execute(db)
                }

                let localDay = localDay(for: request.date, timeZoneIdentifier: item.itemTimeZoneIdentifier)
                let replacementMediaID = preparedReplacement?.id
                let updatedLatitude = request.latitude ?? item.latitude
                let updatedLongitude = request.longitude ?? item.longitude
                let pendingWeatherRefresh = pendingHistoricalWeatherRefresh(
                    for: item,
                    request: request,
                    latitude: updatedLatitude,
                    longitude: updatedLongitude
                )
                let updatedPhotoAssetID: MediaAsset.ID? = switch request.photoChange {
                case .unchanged:
                    item.photoAssetID
                case .removed:
                    nil
                case .replaced:
                    replacementMediaID
                }

                try BlogItem.find(request.id)
                    .update {
                        $0.caption = #bind(request.caption)
                        $0.itemDate = #bind(request.date)
                        $0.localDay = #bind(localDay)
                        $0.locationName = #bind(request.location)
                        $0.latitude = #bind(updatedLatitude)
                        $0.longitude = #bind(updatedLongitude)
                        $0.weatherTemperatureCelsius = #bind(TemperatureValue.normalized(request.temperatureCelsius))
                        $0.weatherConditionCode = #bind(request.weatherCondition)
                        $0.photoAssetID = #bind(updatedPhotoAssetID)
                        $0.updatedAt = #bind(timestamp)
                    }
                    .execute(db)

                if let placement = try fetchPlacement(for: request.id, in: db) {
                    let dayItem = try DayItem.find(db, key: placement.dayItemID)
                    if dayItem.galleryID == nil {
                        try DayItem.find(dayItem.id)
                            .update {
                                $0.placementDate = #bind(request.date)
                                $0.placementTimeZoneIdentifier = #bind(item.itemTimeZoneIdentifier)
                                $0.localDay = #bind(localDay)
                                $0.updatedAt = #bind(timestamp)
                            }
                            .execute(db)
                    }
                }

                return pendingWeatherRefresh
            }

            if let pendingWeatherRefresh {
                Task {
                    await refreshHistoricalWeatherAfterEdit(pendingWeatherRefresh)
                }
            }
        } catch {
            if let preparedReplacement, preparedReplacement.createdOriginal {
                try? fileManager.removeItem(at: preparedReplacement.mediaURL)
            }
            throw error
        }
    }

    private func prepareMediaAsset(
        imageData: Data,
        mimeType: String,
        photoLibraryAssetIdentifier: String? = nil
    ) throws -> PreparedMediaAsset {
        let contentHash = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }
            .joined()
        let fileExtension = MediaStoragePaths.preferredFileExtension(for: mimeType)
        let storedFilename = "\(contentHash).\(fileExtension)"
        let mediaURL = mediaDirectoryURL.appendingPathComponent(storedFilename)

        try fileManager.createDirectory(
            at: mediaDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let createdOriginal = !fileManager.fileExists(atPath: mediaURL.path)
        if createdOriginal {
            try imageData.write(to: mediaURL, options: .atomic)
        }

        return PreparedMediaAsset(
            id: UUID(),
            storedFilename: storedFilename,
            mimeType: mimeType,
            photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
            contentHash: contentHash,
            createdOriginal: createdOriginal,
            mediaURL: mediaURL
        )
    }

    func deleteBlogItem(id: BlogItem.ID) throws {
        try database.write { db in
            let activeBlog = try requireActiveBlog(in: db)
            let item = try BlogItem.find(db, key: id)
            guard item.blogID == activeBlog.id else {
                throw JournalServiceError.inactiveBlogMutation
            }
            let timestamp = now()
            try BlogItem.find(id)
                .update {
                    $0.deletedAt = #bind(timestamp)
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)
            if let placement = try fetchPlacement(for: id, in: db) {
                let dayItem = try DayItem.find(db, key: placement.dayItemID)
                try BlogItemPlacement.find(placement.id).delete().execute(db)
                if dayItem.galleryID == nil {
                    try DayItem.find(dayItem.id).delete().execute(db)
                } else {
                    let remainingItems = try BlogItemPlacement
                        .where { $0.dayItemID.eq(dayItem.id) }
                        .fetchCount(db)
                    if remainingItems == 0 {
                        try DayItem.find(dayItem.id)
                            .update {
                                $0.deletedAt = #bind(timestamp)
                                $0.updatedAt = #bind(timestamp)
                            }
                            .execute(db)
                        if let galleryID = dayItem.galleryID {
                            try Gallery.find(galleryID)
                                .update {
                                    $0.deletedAt = #bind(timestamp)
                                    $0.updatedAt = #bind(timestamp)
                                }
                                .execute(db)
                        }
                    }
                }
            }
        }
    }

    func createGallery(
        title: String,
        description: String,
        placementDate: Date,
        timeZoneIdentifier: String?,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        temperatureCelsius: Double? = nil,
        weatherConditionCode: String? = nil
    ) throws -> Gallery.ID {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw JournalServiceError.missingGalleryTitle }
        return try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let timestamp = now()
            let galleryID = UUID()
            try Gallery.insert {
                Gallery.Draft(
                    id: galleryID,
                    blogID: blog.id,
                    title: trimmedTitle,
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    latitude: latitude,
                    longitude: longitude,
                    locationName: locationName,
                    weatherTemperatureCelsius: temperatureCelsius,
                    weatherConditionCode: weatherConditionCode,
                    sortMode: GallerySortMode.date.rawValue,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    deletedAt: nil
                )
            }
            .execute(db)
            try DayItem.insert {
                DayItem.Draft(
                    id: UUID(),
                    blogID: blog.id,
                    galleryID: galleryID,
                    placementDate: placementDate,
                    placementTimeZoneIdentifier: timeZoneIdentifier,
                    localDay: localDay(
                        for: placementDate,
                        timeZoneIdentifier: timeZoneIdentifier
                    ),
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    deletedAt: nil
                )
            }
            .execute(db)
            return galleryID
        }
    }

    func updateGallery(
        id: Gallery.ID,
        title: String,
        description: String,
        locationName: String,
        latitude: Double?,
        longitude: Double?,
        temperatureCelsius: Double?,
        weatherConditionCode: String?
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw JournalServiceError.missingGalleryTitle }
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let gallery = try Gallery.find(db, key: id)
            guard gallery.blogID == blog.id else {
                throw JournalServiceError.inactiveBlogMutation
            }
            let timestamp = now()
            try Gallery.find(id)
                .update {
                    $0.title = #bind(trimmedTitle)
                    $0.description = #bind(description.trimmingCharacters(in: .whitespacesAndNewlines))
                    $0.locationName = #bind(locationName)
                    $0.latitude = #bind(latitude)
                    $0.longitude = #bind(longitude)
                    $0.weatherTemperatureCelsius = #bind(temperatureCelsius)
                    $0.weatherConditionCode = #bind(weatherConditionCode)
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)
        }
    }

    func moveBlogItems(_ itemIDs: [BlogItem.ID], toGallery galleryID: Gallery.ID) throws {
        let uniqueIDs = Array(Set(itemIDs))
        guard !uniqueIDs.isEmpty else { return }
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let gallery = try Gallery.find(db, key: galleryID)
            guard gallery.blogID == blog.id, gallery.deletedAt == nil else {
                throw JournalServiceError.inactiveBlogMutation
            }
            let destination = try requireGalleryDayItem(galleryID: galleryID, in: db)
            let timestamp = now()
            var position = try nextGalleryPosition(dayItemID: destination.id, in: db)
            for itemID in uniqueIDs {
                let item = try BlogItem.find(db, key: itemID)
                guard item.blogID == blog.id, item.deletedAt == nil else {
                    throw JournalServiceError.inactiveBlogMutation
                }
                guard let placement = try fetchPlacement(for: itemID, in: db) else {
                    throw JournalServiceError.missingBlogItemPlacement
                }
                if placement.dayItemID == destination.id { continue }
                let sourceDayItem = try DayItem.find(db, key: placement.dayItemID)
                try BlogItemPlacement.find(placement.id)
                    .update {
                        $0.dayItemID = #bind(destination.id)
                        $0.position = #bind(position)
                        $0.updatedAt = #bind(timestamp)
                    }
                    .execute(db)
                position += 1
                if sourceDayItem.galleryID == nil {
                    try DayItem.find(sourceDayItem.id).delete().execute(db)
                }
            }
            try DayItem.find(destination.id)
                .update { $0.updatedAt = #bind(timestamp) }
                .execute(db)
            try Gallery.find(galleryID)
                .update { $0.updatedAt = #bind(timestamp) }
                .execute(db)
        }
    }

    func moveBlogItemOutOfGallery(_ itemID: BlogItem.ID) throws {
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let item = try BlogItem.find(db, key: itemID)
            guard item.blogID == blog.id else { throw JournalServiceError.inactiveBlogMutation }
            guard let placement = try fetchPlacement(for: itemID, in: db) else {
                throw JournalServiceError.missingBlogItemPlacement
            }
            let source = try DayItem.find(db, key: placement.dayItemID)
            guard let sourceGalleryID = source.galleryID else { return }
            let timestamp = now()
            let newDayItemID = UUID()
            try DayItem.insert {
                DayItem.Draft(
                    id: newDayItemID,
                    blogID: blog.id,
                    galleryID: nil,
                    placementDate: placementDate(
                        localDay: source.localDay,
                        captureDate: item.itemDate,
                        timeZoneIdentifier: source.placementTimeZoneIdentifier
                            ?? item.itemTimeZoneIdentifier
                    ),
                    placementTimeZoneIdentifier: source.placementTimeZoneIdentifier
                        ?? item.itemTimeZoneIdentifier,
                    localDay: source.localDay,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    deletedAt: nil
                )
            }
            .execute(db)
            try BlogItemPlacement.find(placement.id)
                .update {
                    $0.dayItemID = #bind(newDayItemID)
                    $0.position = 0
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)

            let remainingItems = try BlogItemPlacement
                .where { $0.dayItemID.eq(source.id) }
                .fetchCount(db)
            if remainingItems == 0 {
                try DayItem.find(source.id)
                    .update {
                        $0.deletedAt = #bind(timestamp)
                        $0.updatedAt = #bind(timestamp)
                    }
                    .execute(db)
                try Gallery.find(sourceGalleryID)
                    .update {
                        $0.deletedAt = #bind(timestamp)
                        $0.updatedAt = #bind(timestamp)
                    }
                    .execute(db)
            }
        }
    }

    func reorderGallery(_ galleryID: Gallery.ID, itemIDs: [BlogItem.ID]) throws {
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let gallery = try Gallery.find(db, key: galleryID)
            guard gallery.blogID == blog.id else { throw JournalServiceError.inactiveBlogMutation }
            let dayItem = try requireGalleryDayItem(galleryID: galleryID, in: db)
            let existing = try BlogItemPlacement
                .where { $0.dayItemID.eq(dayItem.id) }
                .fetchAll(db)
            guard Set(existing.map(\.blogItemID)) == Set(itemIDs),
                  existing.count == itemIDs.count else {
                throw JournalServiceError.invalidGalleryOrder
            }
            let timestamp = now()
            for (position, itemID) in itemIDs.enumerated() {
                guard let placement = existing.first(where: { $0.blogItemID == itemID }) else {
                    throw JournalServiceError.invalidGalleryOrder
                }
                try BlogItemPlacement.find(placement.id)
                    .update {
                        $0.position = #bind(position)
                        $0.updatedAt = #bind(timestamp)
                    }
                    .execute(db)
            }
            try Gallery.find(galleryID)
                .update {
                    $0.sortMode = #bind(GallerySortMode.manual.rawValue)
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)
        }
    }

    func deleteGallery(id: Gallery.ID, deletingEntries: Bool) throws {
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let gallery = try Gallery.find(db, key: id)
            guard gallery.blogID == blog.id else { throw JournalServiceError.inactiveBlogMutation }
            let dayItem = try requireGalleryDayItem(galleryID: id, in: db)
            let placements = try BlogItemPlacement
                .where { $0.dayItemID.eq(dayItem.id) }
                .order { ($0.position, $0.blogItemID) }
                .fetchAll(db)
            let timestamp = now()
            for (offset, placement) in placements.enumerated() {
                if deletingEntries {
                    try BlogItem.find(placement.blogItemID)
                        .update {
                            $0.deletedAt = #bind(timestamp)
                            $0.updatedAt = #bind(timestamp)
                        }
                        .execute(db)
                    try BlogItemPlacement.find(placement.id).delete().execute(db)
                } else {
                    let item = try BlogItem.find(db, key: placement.blogItemID)
                    let directID = UUID()
                    try DayItem.insert {
                        DayItem.Draft(
                            id: directID,
                            blogID: blog.id,
                            galleryID: nil,
                            placementDate: placementDate(
                                localDay: dayItem.localDay,
                                captureDate: item.itemDate.addingTimeInterval(Double(offset)),
                                timeZoneIdentifier: dayItem.placementTimeZoneIdentifier
                                    ?? item.itemTimeZoneIdentifier
                            ),
                            placementTimeZoneIdentifier: dayItem.placementTimeZoneIdentifier
                                ?? item.itemTimeZoneIdentifier,
                            localDay: dayItem.localDay,
                            createdAt: timestamp,
                            updatedAt: timestamp,
                            deletedAt: nil
                        )
                    }
                    .execute(db)
                    try BlogItemPlacement.find(placement.id)
                        .update {
                            $0.dayItemID = #bind(directID)
                            $0.position = 0
                            $0.updatedAt = #bind(timestamp)
                        }
                        .execute(db)
                }
            }
            try DayItem.find(dayItem.id)
                .update {
                    $0.deletedAt = #bind(timestamp)
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)
            try Gallery.find(id)
                .update {
                    $0.deletedAt = #bind(timestamp)
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)
        }
    }

    func restoreUnplacedBlogItem(_ itemID: BlogItem.ID) throws {
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let item = try BlogItem.find(db, key: itemID)
            guard item.blogID == blog.id, item.deletedAt == nil else {
                throw JournalServiceError.inactiveBlogMutation
            }
            guard try fetchPlacement(for: itemID, in: db) == nil else { return }
            let timestamp = now()
            try insertDirectPlacement(
                for: item.id,
                blogID: blog.id,
                placementDate: item.itemDate,
                timeZoneIdentifier: item.itemTimeZoneIdentifier,
                localDay: item.localDay,
                timestamp: timestamp,
                in: db
            )
        }
    }

    func loadUnplacedBlogItems() throws -> [BlogItem] {
        try database.read { db in
            let blog = try requireActiveBlog(in: db)
            let placedIDs = Set(
                try BlogItemPlacement
                    .select(\.blogItemID)
                    .fetchAll(db)
            )
            return try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.itemDate.desc(), $0.id) }
                .fetchAll(db)
                .filter { !placedIDs.contains($0.id) }
        }
    }

    func galleryContaining(_ itemID: BlogItem.ID) throws -> Gallery.ID? {
        try database.read { db in
            guard let placement = try fetchPlacement(for: itemID, in: db),
                  let dayItem = try DayItem.find(placement.dayItemID).fetchOne(db) else {
                return nil
            }
            return dayItem.galleryID
        }
    }

    func retryAutomaticGalleryPlacement(for itemID: BlogItem.ID) throws {
        try database.write { db in
            let blog = try requireActiveBlog(in: db)
            let item = try BlogItem.find(db, key: itemID)
            guard item.blogID == blog.id, item.deletedAt == nil,
                  let placement = try fetchPlacement(for: itemID, in: db),
                  let dayItem = try DayItem.find(placement.dayItemID).fetchOne(db),
                  dayItem.galleryID == nil else {
                return
            }
            try applyAutomaticGalleryPlacement(
                for: itemID,
                blog: blog,
                timestamp: now(),
                in: db
            )
        }
    }

    private func fetchPlacement(
        for blogItemID: BlogItem.ID,
        in db: Database
    ) throws -> BlogItemPlacement? {
        try BlogItemPlacement
            .where { $0.blogItemID.eq(blogItemID) }
            .order { ($0.updatedAt.desc(), $0.id.desc()) }
            .fetchOne(db)
    }

    private func requireGalleryDayItem(
        galleryID: Gallery.ID,
        in db: Database
    ) throws -> DayItem {
        let request = DayItem
            .where { $0.galleryID.eq(galleryID) }
            .where { !$0.deletedAt.isNot(nil) }
        guard let dayItem = try request.fetchOne(db) else {
            throw JournalServiceError.missingGalleryPlacement
        }
        return dayItem
    }

    private func placementDate(
        localDay: String,
        captureDate: Date,
        timeZoneIdentifier: String?
    ) -> Date {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return captureDate }
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = calendar.dateComponents([.hour, .minute, .second], from: captureDate)
        return calendar.date(
            from: DateComponents(
                timeZone: timeZone,
                year: parts[0],
                month: parts[1],
                day: parts[2],
                hour: time.hour,
                minute: time.minute,
                second: time.second
            )
        ) ?? captureDate
    }

    func deleteTrip(id: Trip.ID, includingEntries: Bool) throws {
        try database.write { db in
            let activeBlog = try requireActiveBlog(in: db)
            let trip = try Trip.find(db, key: id)
            guard trip.blogID == activeBlog.id else {
                throw JournalServiceError.inactiveBlogMutation
            }

            let timestamp = now()
            let effectiveEndLocalDay = effectiveEndLocalDay(for: trip, referenceDate: timestamp)

            if includingEntries {
                let dayItemsToDelete = try DayItem
                    .where { $0.blogID.eq(activeBlog.id) }
                    .where { !$0.deletedAt.isNot(nil) }
                    .fetchAll(db)
                    .filter { dayItem in
                        dayItem.localDay >= trip.startLocalDay
                            && dayItem.localDay <= effectiveEndLocalDay
                    }
                for dayItem in dayItemsToDelete {
                    let placements = try BlogItemPlacement
                        .where { $0.dayItemID.eq(dayItem.id) }
                        .fetchAll(db)
                    for placement in placements {
                        try BlogItem.find(placement.blogItemID)
                            .update {
                                $0.deletedAt = #bind(timestamp)
                                $0.updatedAt = #bind(timestamp)
                            }
                            .execute(db)
                        try BlogItemPlacement.find(placement.id).delete().execute(db)
                    }
                    if let galleryID = dayItem.galleryID {
                        try Gallery.find(galleryID)
                            .update {
                                $0.deletedAt = #bind(timestamp)
                                $0.updatedAt = #bind(timestamp)
                            }
                            .execute(db)
                    }
                    try DayItem.find(dayItem.id).delete().execute(db)
                }
            }

            try Trip.find(id)
                .update {
                    $0.deletedAt = #bind(timestamp)
                    $0.updatedAt = #bind(timestamp)
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
        photoLibraryAssetIdentifier: String? = nil,
        pixelWidth: Int?,
        pixelHeight: Int?,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        destinationGalleryID: Gallery.ID? = nil
    ) throws -> BlogItem.ID {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionValue = trimmedCaption.isEmpty ? nil : trimmedCaption
        let timestamp = now()
        let blogItemID = UUID()
        let preparedMedia = try prepareMediaAsset(
            imageData: imageData,
            mimeType: mimeType,
            photoLibraryAssetIdentifier: photoLibraryAssetIdentifier
        )

        do {
            try database.write { db in
                let blog = try selectedBlog(in: db)
                let blogger = try selectedBlogger(in: db, blogID: blog?.id)
                guard let blog, let blogger else {
                    throw JournalCreationError.missingWorkspace
                }
                let localDay = localDay(for: date, timeZoneIdentifier: timeZoneIdentifier)

                try MediaAsset.insert {
                    preparedMedia.draft(
                        id: preparedMedia.id,
                        blogID: blog.id,
                        createdAt: timestamp,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight,
                        photoLibraryAssetUploaderID: photoLibraryAssetIdentifier == nil ? nil : blogger.id
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
                        latitude: latitude,
                        longitude: longitude,
                        locationName: locationName,
                        photoAssetID: preparedMedia.id
                    )
                }
                .execute(db)

                if let destinationGalleryID {
                    let gallery = try Gallery.find(db, key: destinationGalleryID)
                    guard gallery.blogID == blog.id, gallery.deletedAt == nil else {
                        throw JournalServiceError.inactiveBlogMutation
                    }
                    let destination = try requireGalleryDayItem(
                        galleryID: destinationGalleryID,
                        in: db
                    )
                    let destinationPosition = try nextGalleryPosition(
                        dayItemID: destination.id,
                        in: db
                    )
                    try BlogItemPlacement.insert {
                        BlogItemPlacement.Draft(
                            id: UUID(),
                            blogItemID: blogItemID,
                            dayItemID: destination.id,
                            position: destinationPosition,
                            createdAt: timestamp,
                            updatedAt: timestamp
                        )
                    }
                    .execute(db)
                } else {
                    try insertDirectPlacement(
                        for: blogItemID,
                        blogID: blog.id,
                        placementDate: date,
                        timeZoneIdentifier: timeZoneIdentifier,
                        localDay: localDay,
                        timestamp: timestamp,
                        in: db
                    )
                    try applyAutomaticGalleryPlacement(
                        for: blogItemID,
                        blog: blog,
                        timestamp: timestamp,
                        in: db
                    )
                }
            }
        } catch {
            if preparedMedia.createdOriginal {
                try? fileManager.removeItem(at: preparedMedia.mediaURL)
            }
            throw error
        }

        return blogItemID
    }

    private func applyAutomaticGalleryPlacement(
        for blogItemID: BlogItem.ID,
        blog: Blog,
        timestamp: Date,
        in db: Database
    ) throws {
        let item = try BlogItem.find(db, key: blogItemID)
        guard let placement = try fetchPlacement(for: blogItemID, in: db) else {
            throw JournalServiceError.missingBlogItemPlacement
        }
        let directDayItem = try DayItem.find(db, key: placement.dayItemID)
        let dayItems = try DayItem
            .where { $0.blogID.eq(blog.id) && $0.localDay.eq(directDayItem.localDay) }
            .where { !$0.deletedAt.isNot(nil) }
            .order { ($0.placementDate, $0.id) }
            .fetchAll(db)
        guard let insertedIndex = dayItems.firstIndex(where: { $0.id == directDayItem.id }) else {
            return
        }

        let adjacent = [
            insertedIndex > dayItems.startIndex ? dayItems[dayItems.index(before: insertedIndex)] : nil,
            dayItems.index(after: insertedIndex) < dayItems.endIndex
                ? dayItems[dayItems.index(after: insertedIndex)]
                : nil,
        ].compactMap { $0 }

        let galleriesByID = Dictionary(
            try Gallery
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .fetchAll(db)
                .map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.updatedAt > current.updatedAt ? candidate : current
            }
        )
        let matchingGalleries = adjacent.compactMap { candidate -> (DayItem, Gallery)? in
            guard let galleryID = candidate.galleryID,
                  let gallery = galleriesByID[galleryID],
                  creationMatch(
                    itemDate: item.itemDate,
                    latitude: item.latitude,
                    longitude: item.longitude,
                    anchorDate: candidate.placementDate,
                    anchorLatitude: gallery.latitude,
                    anchorLongitude: gallery.longitude,
                    interval: blog.galleryIntervalSeconds,
                    distance: blog.galleryDistanceMeters
                  ) else {
                return nil
            }
            return (candidate, gallery)
        }
        if let destination = matchingGalleries.min(by: {
            abs($0.0.placementDate.timeIntervalSince(item.itemDate))
                < abs($1.0.placementDate.timeIntervalSince(item.itemDate))
        }) {
            let destinationPosition = try nextGalleryPosition(
                dayItemID: destination.0.id,
                in: db
            )
            try BlogItemPlacement.find(placement.id)
                .update {
                    $0.dayItemID = #bind(destination.0.id)
                    $0.position = #bind(destinationPosition)
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)
            try DayItem.find(directDayItem.id).delete().execute(db)
            return
        }

        var matchingDirectItems: [(dayItem: DayItem, item: BlogItem)] = []
        for candidate in adjacent where candidate.galleryID == nil {
            let candidatePlacement = try BlogItemPlacement
                .where { $0.dayItemID.eq(candidate.id) }
                .fetchOne(db)
            guard let candidatePlacement,
                  let candidateItem = try BlogItem.find(candidatePlacement.blogItemID).fetchOne(db)
            else {
                continue
            }
            guard creationMatch(
                itemDate: item.itemDate,
                latitude: item.latitude,
                longitude: item.longitude,
                anchorDate: candidateItem.itemDate,
                anchorLatitude: candidateItem.latitude,
                anchorLongitude: candidateItem.longitude,
                interval: blog.galleryIntervalSeconds,
                distance: blog.galleryDistanceMeters
            ) else {
                continue
            }
            matchingDirectItems.append((candidate, candidateItem))
        }
        guard !matchingDirectItems.isEmpty else { return }

        let allMembers = (matchingDirectItems.map(\.item) + [item]).sorted {
            if $0.itemDate != $1.itemDate { return $0.itemDate < $1.itemDate }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let anchor = allMembers.first else { return }
        let galleryID = UUID()
        try Gallery.insert {
            Gallery.Draft(
                id: galleryID,
                blogID: blog.id,
                title: anchor.locationName?.isEmpty == false ? anchor.locationName! : "Gallery",
                description: "",
                latitude: anchor.latitude,
                longitude: anchor.longitude,
                locationName: anchor.locationName,
                countryCode: anchor.countryCode,
                weatherTemperatureCelsius: anchor.weatherTemperatureCelsius,
                weatherConditionCode: anchor.weatherConditionCode,
                sortMode: GallerySortMode.date.rawValue,
                createdAt: timestamp,
                updatedAt: timestamp,
                deletedAt: nil
            )
        }
        .execute(db)
        try DayItem.find(directDayItem.id)
            .update {
                $0.galleryID = #bind(galleryID)
                $0.placementDate = #bind(anchor.itemDate)
                $0.placementTimeZoneIdentifier = #bind(anchor.itemTimeZoneIdentifier)
                $0.updatedAt = #bind(timestamp)
            }
            .execute(db)
        for (position, member) in allMembers.enumerated() {
            guard let memberPlacement = try fetchPlacement(for: member.id, in: db) else {
                throw JournalServiceError.missingBlogItemPlacement
            }
            try BlogItemPlacement.find(memberPlacement.id)
                .update {
                    $0.dayItemID = #bind(directDayItem.id)
                    $0.position = #bind(position)
                    $0.updatedAt = #bind(timestamp)
                }
                .execute(db)
        }
        for candidate in matchingDirectItems {
            try DayItem.find(candidate.dayItem.id).delete().execute(db)
        }
    }

    private func nextGalleryPosition(dayItemID: DayItem.ID, in db: Database) throws -> Int {
        let placements = try BlogItemPlacement
            .where { $0.dayItemID.eq(dayItemID) }
            .fetchAll(db)
        return (placements.map(\.position).max() ?? -1) + 1
    }

    private func creationMatch(
        itemDate: Date,
        latitude: Double?,
        longitude: Double?,
        anchorDate: Date,
        anchorLatitude: Double?,
        anchorLongitude: Double?,
        interval: Int,
        distance: Double
    ) -> Bool {
        guard abs(itemDate.timeIntervalSince(anchorDate)) <= Double(interval) else {
            return false
        }
        guard let latitude, let longitude, let anchorLatitude, let anchorLongitude else {
            return false
        }
        let first = CLLocation(latitude: latitude, longitude: longitude)
        let second = CLLocation(latitude: anchorLatitude, longitude: anchorLongitude)
        return first.distance(from: second) <= distance
    }

    private func insertDirectPlacement(
        for blogItemID: BlogItem.ID,
        blogID: Blog.ID,
        placementDate: Date,
        timeZoneIdentifier: String?,
        localDay: String,
        timestamp: Date,
        in db: Database
    ) throws {
        let dayItemID = UUID()
        try DayItem.insert {
            DayItem.Draft(
                id: dayItemID,
                blogID: blogID,
                galleryID: nil,
                placementDate: placementDate,
                placementTimeZoneIdentifier: timeZoneIdentifier,
                localDay: localDay,
                createdAt: timestamp,
                updatedAt: timestamp,
                deletedAt: nil
            )
        }
        .execute(db)
        try BlogItemPlacement.insert {
            BlogItemPlacement.Draft(
                id: UUID(),
                blogItemID: blogItemID,
                dayItemID: dayItemID,
                position: 0,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
        .execute(db)
    }

    func captureWeather(for id: BlogItem.ID) async {
        do {
            WeatherEnrichmentLog.notice("Starting weather enrichment for BlogItem \(id.uuidString).")
            let capture = try await fetchWeatherCapture()
            let location = WeatherLocation(latitude: capture.latitude, longitude: capture.longitude)
            let placeName = try await fetchPlaceName(for: location)
            try await persistWeatherEnrichment(for: id, location: location, placeName: placeName, weather: capture)
            WeatherEnrichmentLog.notice("Weather enrichment persisted for BlogItem \(id.uuidString).")
        } catch {
            WeatherEnrichmentLog.error("Weather enrichment failed for BlogItem \(id.uuidString).", error: error)
            return
        }
    }

    func captureHistoricalWeather(
        for id: BlogItem.ID,
        at date: Date,
        latitude: Double,
        longitude: Double
    ) async {
        let location = WeatherLocation(latitude: latitude, longitude: longitude)
        await refreshHistoricalWeather(
            for: id,
            at: date,
            location: location,
            locationName: { try await fetchPlaceName(for: location) },
            context: "historical weather enrichment"
        )
    }

    func capturePlaceName(
        for id: BlogItem.ID,
        latitude: Double,
        longitude: Double
    ) async {
        do {
            let placeName = try await fetchPlaceName(
                for: WeatherLocation(latitude: latitude, longitude: longitude)
            )
            try await database.write { db in
                guard try BlogItem.find(id).fetchOne(db) != nil else { return }
                try BlogItem.find(id)
                    .update {
                        $0.locationName = #bind(placeName)
                        $0.updatedAt = #bind(now())
                    }
                    .execute(db)
            }
        } catch {
            WeatherEnrichmentLog.error("Place-name enrichment failed for BlogItem \(id.uuidString).", error: error)
        }
    }

    private func fetchWeatherCapture() async throws -> WeatherCapture {
        try await weatherCapturePrimer.capture(now: now()) {
            let location = try await locationProvider.currentLocation()
            return try await weatherProvider.currentWeather(for: location)
        }
    }

    private func fetchPlaceName(for location: WeatherLocation) async throws -> String? {
        try await placeNameProvider.placeName(for: location)
    }

    private func pendingHistoricalWeatherRefresh(
        for item: BlogItem,
        request: BlogItemUpdateRequest,
        latitude: Double?,
        longitude: Double?
    ) -> PendingHistoricalWeatherRefresh? {
        guard let latitude, let longitude else { return nil }

        let existingLocation = item.latitude.flatMap { latitude in
            item.longitude.map { longitude in
                WeatherLocation(latitude: latitude, longitude: longitude)
            }
        }
        let updatedLocation = WeatherLocation(latitude: latitude, longitude: longitude)
        let didChangeLocation = existingLocation != updatedLocation
        let didChangeDate = item.itemDate != request.date

        guard didChangeLocation || didChangeDate else { return nil }

        return PendingHistoricalWeatherRefresh(
            id: item.id,
            date: request.date,
            location: updatedLocation,
            locationName: request.location
        )
    }

    private func refreshHistoricalWeatherAfterEdit(_ refresh: PendingHistoricalWeatherRefresh) async {
        await refreshHistoricalWeather(
            for: refresh.id,
            at: refresh.date,
            location: refresh.location,
            locationName: { refresh.locationName },
            context: "historical weather refresh after edit"
        )
    }

    private func refreshHistoricalWeather(
        for id: BlogItem.ID,
        at date: Date,
        location: WeatherLocation,
        locationName: @escaping @Sendable () async throws -> String?,
        context: String
    ) async {
        do {
            WeatherEnrichmentLog.notice("Starting \(context) for BlogItem \(id.uuidString).")
            let placeName = try await locationName()
            let weather = try await weatherProvider.weather(for: location, near: date)
            try await persistWeatherEnrichment(for: id, location: location, placeName: placeName, weather: weather)
            WeatherEnrichmentLog.notice("\(context.capitalized) persisted for BlogItem \(id.uuidString).")
        } catch {
            WeatherEnrichmentLog.error("\(context.capitalized) failed for BlogItem \(id.uuidString).", error: error)
        }
    }

    private func persistWeatherEnrichment(
        for id: BlogItem.ID,
        location: WeatherLocation,
        placeName: String?,
        weather: WeatherCapture?
    ) async throws {
        try await database.write { db in
            guard try BlogItem.find(id).fetchOne(db) != nil else { return }
            try BlogItem.find(id)
                .update {
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

    private func selectedBlog(in db: Database) throws -> Blog? {
        try requireActiveBlog(in: db)
    }

    private func validateTripRange(
        in db: Database,
        candidate: TripValidationCandidate
    ) throws {
        let activeBlog = try requireActiveBlog(in: db)
        let trips = try Trip
            .where { $0.blogID.eq(activeBlog.id) }
            .where { !$0.deletedAt.isNot(nil) }
            .fetchAll(db)
            .map {
                TripValidationCandidate(
                    id: $0.id,
                    startLocalDay: $0.startLocalDay,
                    endLocalDay: $0.endLocalDay
                )
            }
        let status = TripValidation.validate(
            candidate: candidate,
            against: trips,
            todayLocalDay: localDay(for: now(), timeZoneIdentifier: nil)
        )
        switch status {
        case .valid:
            return
        case .overlapsAnotherTrip:
            throw JournalServiceError.overlapsAnotherTrip
        case .multipleOpenTrips:
            throw JournalServiceError.multipleOpenTrips
        }
    }

    private func selectedBlogger(in db: Database, blogID: Blog.ID?) throws -> Blogger? {
        guard let blogID else { return nil }
        if let bloggerID {
            let blogger = try Blogger.find(bloggerID).fetchOne(db)
            guard blogger?.blogID == blogID else {
                throw JournalServiceError.inactiveBlogger
            }
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
            .fetchOne(db)
            ?? nil
        let oldestBlogID = try Blog
            .order { ($0.createdAt, $0.id) }
            .select(\.id)
            .fetchOne(db)
        let activeBlogID = workspaceBlogID ?? blogID ?? oldestBlogID
        guard let activeBlogID else {
            throw JournalServiceError.missingBlog
        }
        guard blogID == nil || blogID == activeBlogID else {
            throw JournalServiceError.inactiveBlogMutation
        }
        guard let blog = try Blog.find(activeBlogID).fetchOne(db) else {
            throw JournalServiceError.missingBlog
        }
        if let bloggerID {
            guard let blogger = try Blogger.find(bloggerID).fetchOne(db),
                  blogger.blogID == blog.id
            else {
                throw JournalServiceError.inactiveBlogger
            }
        }
        return blog
    }

    private func makeDisplayTrip(
        _ trip: Trip,
        entries: [JournalPlacedEntry]
    ) -> TripDisplay {
        return TripDisplay(
            id: trip.id,
            kind: .trip,
            title: trip.title,
            description: trip.description,
            startLocalDay: trip.startLocalDay,
            endLocalDay: trip.endLocalDay,
            closedAt: trip.closedAt,
            days: displayDays(from: entries)
        )
    }

    private func makeUnassignedDisplay(entries: [JournalPlacedEntry]) -> TripDisplay {
        let days = displayDays(from: entries)

        return TripDisplay(
            id: TripDisplay.unassignedID,
            kind: .unassigned,
            title: "Unassigned",
            description: "",
            startLocalDay: days.first?.localDay ?? "",
            endLocalDay: days.last?.localDay,
            closedAt: nil,
            days: days
        )
    }

    private func displayDays(from entries: [JournalPlacedEntry]) -> [DayPostDisplay] {
        let entriesByDay = Dictionary(grouping: entries) { $0.dayItem.localDay }
        var previousDayFinalLocation: String?
        return entriesByDay.keys.sorted().compactMap { localDay -> DayPostDisplay? in
            guard let dayEntries = entriesByDay[localDay]?.sorted(by: placedEntrySort),
                  let firstEntry = dayEntries.first else {
                return nil
            }
            let items = dayEntries.flatMap(\.items)
            let dayRoute = route(for: items, startingAt: previousDayFinalLocation)
            previousDayFinalLocation = finalRouteLocation(for: items) ?? previousDayFinalLocation
            return DayPostDisplay(
                id: firstEntry.dayItem.id,
                date: firstEntry.dayItem.placementDate,
                localDay: localDay,
                route: dayRoute,
                entries: dayEntries.map(\.entry)
            )
        }
    }

    private func placedEntrySort(_ lhs: JournalPlacedEntry, _ rhs: JournalPlacedEntry) -> Bool {
        if lhs.dayItem.placementDate != rhs.dayItem.placementDate {
            return lhs.dayItem.placementDate < rhs.dayItem.placementDate
        }
        return lhs.dayItem.id.uuidString < rhs.dayItem.id.uuidString
    }

    private func isDayItem(_ dayItem: DayItem, includedIn trip: Trip, referenceDate: Date) -> Bool {
        guard dayItem.localDay >= trip.startLocalDay else { return false }
        return dayItem.localDay <= effectiveEndLocalDay(for: trip, referenceDate: referenceDate)
    }

    private func effectiveEndLocalDay(for trip: Trip, referenceDate: Date) -> String {
        trip.endLocalDay ?? localDay(
            for: referenceDate,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier
        )
    }

    private func makeDisplayItem(
        _ item: BlogItem,
        bloggersByID: [Blogger.ID: Blogger],
        mediaByID: [MediaAsset.ID: MediaAsset],
        localImagePathsByMediaID: [MediaAsset.ID: String],
        isShared: Bool,
        isUploaded: Bool,
        isMediaUploaded: Bool,
        isMediaFailed: Bool
    ) -> BlogItemDisplay {
        let conditionCode = item.weatherConditionCode
        let mediaAsset = item.photoAssetID.flatMap { mediaByID[$0] }
        let resolvedLocalImagePath = item.photoAssetID.flatMap { localImagePathsByMediaID[$0] }
        let isLocalMediaAvailable = resolvedLocalImagePath != nil
        let palette: JournalPalette? = mediaAsset.flatMap {
            guard resolvedLocalImagePath == nil else { return nil }
            return JournalPalette(rawValue: ($0.filename as NSString).deletingPathExtension)
        }
        let hasDownloadableCloudAsset = mediaAsset?.cloudAssetIdentifier?.isEmpty == false
        var photoAvailability: BlogItemPhotoAvailability
        if item.photoAssetID == nil || palette != nil {
            photoAvailability = .none
        } else if isLocalMediaAvailable {
            photoAvailability = .available
        } else if hasDownloadableCloudAsset, !isMediaFailed {
            photoAvailability = .downloading
        } else {
            photoAvailability = .unavailable
        }
        if let photoAvailabilityOverride, item.photoAssetID != nil {
            photoAvailability = photoAvailabilityOverride
        }
        let recordState: SyncDependencyState = isUploaded ? .synced : .pending
        let mediaState: SyncDependencyState
        if mediaAsset != nil {
            mediaState = if isMediaFailed || photoAvailability == .unavailable {
                .failed
            } else if isMediaUploaded && isLocalMediaAvailable {
                .synced
            } else {
                .pending
            }
        } else {
            mediaState = .notRequired
        }
        let syncStatus = if let syncStatusOverride {
            syncStatusOverride
        } else if photoAvailability == .downloading {
            BlogItemSyncStatus.pending
        } else if photoAvailability == .unavailable {
            BlogItemSyncStatus.failed
        } else {
            BlogItemSyncStatus.resolve(
                record: recordState,
                media: mediaState,
                isShared: isShared
            )
        }

        return BlogItemDisplay(
            id: item.id,
            author: bloggersByID[item.authorID]?.displayName ?? BootstrapDefaults.bloggerDisplayName,
            date: item.itemDate,
            timeZoneIdentifier: item.itemTimeZoneIdentifier,
            caption: item.caption ?? "",
            location: item.locationName ?? "",
            latitude: item.latitude,
            longitude: item.longitude,
            weather: WeatherDisplay(
                temperatureCelsius: item.weatherTemperatureCelsius.map(TemperatureValue.normalized),
                conditionCode: conditionCode,
                condition: conditionCode.map(WeatherConditionCatalog.description(for:)),
                systemImage: conditionCode.map(WeatherConditionCatalog.systemImage(for:))
            ),
            hasPhoto: item.photoAssetID != nil,
            photoAvailability: photoAvailability,
            localImagePath: resolvedLocalImagePath,
            palette: palette,
            syncStatus: syncStatus
        )
    }

    private func makeDisplayGallery(
        _ gallery: Gallery,
        dayItem: DayItem,
        items: [BlogItemDisplay]
    ) -> GalleryDisplay {
        let conditionCode = gallery.weatherConditionCode
        return GalleryDisplay(
            id: gallery.id,
            dayItemID: dayItem.id,
            title: gallery.title,
            description: gallery.description,
            location: gallery.locationName ?? "",
            latitude: gallery.latitude,
            longitude: gallery.longitude,
            weather: WeatherDisplay(
                temperatureCelsius: gallery.weatherTemperatureCelsius.map(TemperatureValue.normalized),
                conditionCode: conditionCode,
                condition: conditionCode.map(WeatherConditionCatalog.description(for:)),
                systemImage: conditionCode.map(WeatherConditionCatalog.systemImage(for:))
            ),
            placementDate: dayItem.placementDate,
            localDay: dayItem.localDay,
            sortMode: GallerySortMode(rawValue: gallery.sortMode) ?? .date,
            items: items
        )
    }

    private func resolveExistingLocalImagePath(for mediaAsset: MediaAsset) -> String? {
        let currentContainerPath = durableMediaURL(for: mediaAsset).path
        if isReadableRegularFile(atPath: currentContainerPath) {
            return currentContainerPath
        }

        if let storedPath = mediaAsset.localOriginalPath {
            let storedURL = URL(fileURLWithPath: storedPath)
            let resolvedURL = storedPath.hasPrefix("/")
                ? storedURL
                : mediaDirectoryURL.appendingPathComponent(storedPath)
            if isContainedInMediaDirectory(path: resolvedURL.path),
               isReadableRegularFile(atPath: resolvedURL.path) {
                return resolvedURL.path
            }

            // App-container UUIDs can change across an install or migration while the
            // relative media filename remains valid. Retry only the basename inside
            // this app's own media directory; never read the stale absolute location.
            let containedLegacyURL = mediaDirectoryURL
                .appendingPathComponent(storedURL.lastPathComponent)
            if isReadableRegularFile(atPath: containedLegacyURL.path) {
                return containedLegacyURL.path
            }
        }

        return nil
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
              let resourceValues = try? URL(fileURLWithPath: path).resourceValues(
                forKeys: [.isRegularFileKey]
              ) else {
            return false
        }
        return resourceValues.isRegularFile == true
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

    private func entries(
        for items: [BlogItemDisplay],
        galleryInterval: Int,
        galleryDistance: Double
    ) -> [DayPostEntry] {
        var result: [DayPostEntry] = []
        var index = items.startIndex

        while index < items.endIndex {
            let item = items[index]
            var galleryItems = [item]
            var nextIndex = items.index(after: index)
            while nextIndex < items.endIndex {
                let candidate = items[nextIndex]
                guard isWithinGalleryDistance(
                          candidate,
                          of: item,
                          limitMeters: galleryDistance
                      ),
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

    private func isWithinGalleryDistance(
        _ candidate: BlogItemDisplay,
        of item: BlogItemDisplay,
        limitMeters: Double
    ) -> Bool {
        guard let itemLatitude = item.latitude,
              let itemLongitude = item.longitude,
              let candidateLatitude = candidate.latitude,
              let candidateLongitude = candidate.longitude else {
            return candidate.location == item.location
        }
        let itemLocation = CLLocation(latitude: itemLatitude, longitude: itemLongitude)
        let candidateLocation = CLLocation(latitude: candidateLatitude, longitude: candidateLongitude)
        return candidateLocation.distance(from: itemLocation) <= limitMeters
    }

    private func route(for items: [BlogItemDisplay], startingAt location: String? = nil) -> [String] {
        var route: [String] = []
        var seenLocations = Set<String>()

        func append(_ location: String?) {
            guard let displayLocation = routeLocationDisplay(for: location) else { return }
            let key = routeLocationKey(for: displayLocation)
            guard !seenLocations.contains(key) else { return }
            seenLocations.insert(key)
            route.append(displayLocation)
        }

        append(location)
        for item in items {
            append(item.location)
        }
        return route
    }

    private func finalRouteLocation(for items: [BlogItemDisplay]) -> String? {
        items.reversed().lazy.compactMap { routeLocationDisplay(for: $0.location) }.first
    }

    private func routeLocationDisplay(for location: String?) -> String? {
        guard let location else { return nil }
        let town = location
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? location
        let trimmedTown = town.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTown.isEmpty ? nil : trimmedTown
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
        let applicationSupportDirectory = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return applicationSupportDirectory.appendingPathComponent("BlogItemMedia", isDirectory: true)
    }

    private static func defaultMediaCacheDirectoryURL(fileManager: FileManager) -> URL {
        let cachesDirectory = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return cachesDirectory.appendingPathComponent("BlogItemMedia", isDirectory: true)
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

private struct JournalLoadSnapshot {
    let blog: Blog
    let trips: [Trip]
    let bloggers: [Blogger]
    let mediaAssets: [MediaAsset]
    let items: [BlogItem]
    let galleries: [Gallery]
    let dayItems: [DayItem]
    let placements: [BlogItemPlacement]
    let isShared: Bool
    let uploadedItemIDs: Set<BlogItem.ID>
    let uploadedMediaIDs: Set<MediaAsset.ID>
    let failedMediaIDs: Set<MediaAsset.ID>
}

private struct JournalPlacedEntry {
    let dayItem: DayItem
    let entry: DayPostEntry
    let items: [BlogItemDisplay]
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
    case missingGalleryTitle
    case missingGalleryPlacement
    case missingBlogItemPlacement
    case invalidGalleryOrder

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
        case .missingGalleryTitle:
            "A Gallery title is required."
        case .missingGalleryPlacement:
            "The Gallery could not be found in the Journal."
        case .missingBlogItemPlacement:
            "The entry could not be found in the Journal."
        case .invalidGalleryOrder:
            "The Gallery order did not contain exactly its current entries."
        }
    }
}

private nonisolated extension String {
    func capitalizingFirstCharacter() -> String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
