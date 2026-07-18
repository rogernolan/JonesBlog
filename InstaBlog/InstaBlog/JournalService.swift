import Foundation
import CoreLocation
import MapKit
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
    static func notice(_ message: String) {
        AppTelemetry.log(message, category: "weather.enrichment")
    }

    static func error(_ message: String, error: Error? = nil) {
        AppTelemetry.log(
            message,
            category: "weather.enrichment",
            level: .error,
            error: error
        )
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
