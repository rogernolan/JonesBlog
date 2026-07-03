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
                .order { ($0.startLocalDay.desc(), $0.createdAt.desc()) }
                .fetchAll(db)
            let bloggers = try Blogger.where { $0.blogID.eq(blog.id) }.fetchAll(db)
            let items = try BlogItem
                .where { $0.blogID.eq(blog.id) }
                .where { !$0.deletedAt.isNot(nil) }
                .order { ($0.itemDate, $0.id) }
                .fetchAll(db)
            let displayedItems = items.filter { item in
                trips.contains { trip in isItem(item, includedIn: trip) }
            }
            let referencedMediaIDs = Array(Set(displayedItems.compactMap(\.photoAssetID)))
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
                for item in displayedItems {
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
                items: displayedItems,
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
            uniqueKeysWithValues: snapshot.bloggers.map { ($0.id, $0) }
        )
        let mediaByID: [MediaAsset.ID: MediaAsset] = Dictionary(
            uniqueKeysWithValues: snapshot.mediaAssets.map { ($0.id, $0) }
        )
        let displays = snapshot.trips.map { trip in
            makeDisplayTrip(
                trip,
                items: snapshot.items,
                galleryInterval: snapshot.blog.galleryIntervalSeconds,
                bloggersByID: bloggersByID,
                mediaByID: mediaByID,
                localImagePathsByMediaID: localImagePathsByMediaID,
                isShared: snapshot.isShared,
                uploadedItemIDs: snapshot.uploadedItemIDs,
                uploadedMediaIDs: snapshot.uploadedMediaIDs,
                failedMediaIDs: snapshot.failedMediaIDs
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
            guard let blog = try selectedBlog(in: db) else {
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
        temperatureCelsius: Int,
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
                mimeType: replacement.mimeType
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
                    try MediaAsset.insert {
                        preparedReplacement.draft(
                            id: preparedReplacement.id,
                            blogID: activeBlog.id,
                            createdAt: timestamp
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
                        $0.weatherTemperatureCelsius = #bind(Double(request.temperatureCelsius))
                        $0.weatherConditionCode = #bind(request.weatherCondition)
                        $0.photoAssetID = #bind(updatedPhotoAssetID)
                        $0.updatedAt = #bind(timestamp)
                    }
                    .execute(db)

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
        mimeType: String
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
        }
    }

    func createPhotoBlogItem(
        caption: String,
        date: Date,
        timeZoneIdentifier: String?,
        imageData: Data,
        mimeType: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) throws -> BlogItem.ID {
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionValue = trimmedCaption.isEmpty ? nil : trimmedCaption
        let timestamp = now()
        let blogItemID = UUID()
        let preparedMedia = try prepareMediaAsset(imageData: imageData, mimeType: mimeType)

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
                        pixelHeight: pixelHeight
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
                        photoAssetID: preparedMedia.id
                    )
                }
                .execute(db)
            }
        } catch {
            if preparedMedia.createdOriginal {
                try? fileManager.removeItem(at: preparedMedia.mediaURL)
            }
            throw error
        }

        return blogItemID
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
        items: [BlogItem],
        galleryInterval: Int,
        bloggersByID: [Blogger.ID: Blogger],
        mediaByID: [MediaAsset.ID: MediaAsset],
        localImagePathsByMediaID: [MediaAsset.ID: String],
        isShared: Bool,
        uploadedItemIDs: Set<BlogItem.ID>,
        uploadedMediaIDs: Set<MediaAsset.ID>,
        failedMediaIDs: Set<MediaAsset.ID>
    ) -> TripDisplay {
        let matchingItems = items.filter { isItem($0, includedIn: trip) }
        let displayItems = matchingItems.map {
            makeDisplayItem(
                $0,
                bloggersByID: bloggersByID,
                mediaByID: mediaByID,
                localImagePathsByMediaID: localImagePathsByMediaID,
                isShared: isShared,
                isUploaded: uploadedItemIDs.contains($0.id),
                isMediaUploaded: $0.photoAssetID.map(uploadedMediaIDs.contains) ?? true,
                isMediaFailed: $0.photoAssetID.map(failedMediaIDs.contains) ?? false
            )
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
    private func isItem(_ item: BlogItem, includedIn trip: Trip) -> Bool {
        guard item.localDay >= trip.startLocalDay else { return false }
        let effectiveEndLocalDay = trip.closedAt == nil
            ? localDay(for: now(), timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
            : trip.endLocalDay
        if let effectiveEndLocalDay {
            return item.localDay <= effectiveEndLocalDay
        }
        return true
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
        let recordState: SyncDependencyState = isUploaded ? .synced : .pending
        let mediaState: SyncDependencyState
        if mediaAsset != nil {
            mediaState = isMediaUploaded ? .synced : .pending
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
                temperatureCelsius: item.weatherTemperatureCelsius.map { Int($0.rounded()) },
                conditionCode: conditionCode,
                condition: conditionCode.map(WeatherConditionCatalog.description(for:)),
                systemImage: conditionCode.map(WeatherConditionCatalog.systemImage(for:))
            ),
            latitude: item.latitude,
            longitude: item.longitude,
            localImagePath: resolvedLocalImagePath,
            palette: mediaAsset.flatMap {
                guard resolvedLocalImagePath == nil else { return nil }
                return JournalPalette(rawValue: ($0.filename as NSString).deletingPathExtension)
            },
            syncStatus: syncStatusOverride ?? BlogItemSyncStatus.resolve(
                    record: recordState,
                    media: mediaState,
                    isShared: isShared
                )
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
    let contentHash: String
    let createdOriginal: Bool
    let mediaURL: URL

    func draft(
        id: MediaAsset.ID,
        blogID: Blog.ID,
        createdAt: Date,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) -> MediaAsset.Draft {
        MediaAsset.Draft(
            id: id,
            blogID: blogID,
            localOriginalPath: storedFilename,
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
    let isShared: Bool
    let uploadedItemIDs: Set<BlogItem.ID>
    let uploadedMediaIDs: Set<MediaAsset.ID>
    let failedMediaIDs: Set<MediaAsset.ID>
}

enum JournalCreationError: Error {
    case missingWorkspace
}

enum JournalServiceError: LocalizedError, Equatable {
    case missingBlog
    case inactiveBlogMutation
    case inactiveBlogger

    var errorDescription: String? {
        switch self {
        case .missingBlog:
            "The active Blog could not be found."
        case .inactiveBlogMutation:
            "This item belongs to a Blog that is no longer active."
        case .inactiveBlogger:
            "The active Blogger does not belong to the active Blog."
        }
    }
}

private nonisolated extension String {
    func capitalizingFirstCharacter() -> String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
