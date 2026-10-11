import Foundation
import MapKit
import SwiftUI

nonisolated struct PostMapPin: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let title: String

    init?(latitude: Double?, longitude: Double?, title: String) {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-85...85).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.title = title
    }

    init?(item: BlogItemDisplay) {
        self.init(latitude: item.latitude, longitude: item.longitude, title: item.location)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated enum PostMapContent {
    static func isAvailable(latitude: Double?, longitude: Double?, otherItems: [BlogItemDisplay]) -> Bool {
        PostMapPin(latitude: latitude, longitude: longitude, title: "") != nil
            || otherItems.contains { PostMapPin(item: $0) != nil }
    }

    static func pins(for item: BlogItemDisplay, dayItems: [BlogItemDisplay]) -> [PostMapPin] {
        if let pin = PostMapPin(item: item) { return [pin] }
        var pins: [PostMapPin] = []
        for pin in dayItems.compactMap(PostMapPin.init(item:)) {
            if !pins.contains(where: { $0.latitude == pin.latitude && $0.longitude == pin.longitude }) {
                pins.append(pin)
            }
        }
        return pins
    }

    /// Fits a square Mercator map with at least 5km of space on each side.
    /// Unwrap longitude around the largest gap to keep dateline crossings local.
    static func mapRect(for pins: [PostMapPin]) -> MKMapRect? {
        guard !pins.isEmpty else { return nil }
        let worldWidth = MKMapRect.world.size.width
        let points = pins.map { MKMapPoint($0.coordinate) }
        let xs = points.map(\.x).sorted()
        var gap = -Double.infinity
        var start = xs[0]
        for index in xs.indices {
            let next = index + 1 < xs.count ? xs[index + 1] : xs[0] + worldWidth
            if next - xs[index] > gap {
                gap = next - xs[index]
                // Preserve the original value: adding/subtracting worldWidth can
                // round it above the first point and unwrap that point a whole world.
                start = xs[(index + 1) % xs.count]
            }
        }
        let unwrapped = points.map { point in
            MKMapPoint(x: point.x < start ? point.x + worldWidth : point.x, y: point.y)
        }
        let minX = unwrapped.map(\.x).min()!
        let maxX = unwrapped.map(\.x).max()!
        let minY = unwrapped.map(\.y).min()!
        let maxY = unwrapped.map(\.y).max()!
        let padding = pins.map { MKMapPointsPerMeterAtLatitude($0.latitude) * 5_000 }.max()!
        let side = max(maxX - minX, maxY - minY) + padding * 2
        return MKMapRect(x: (minX + maxX - side) / 2, y: (minY + maxY - side) / 2,
                         width: side, height: side)
    }

    static func creationDate(date: Date, timeZoneIdentifier: String?, isMapOnly: Bool) -> Date {
        guard isMapOnly else { return date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        return calendar.startOfDay(for: date).addingTimeInterval(1)
    }
}

struct PostMapView: View {
    let pins: [PostMapPin]

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                if let rect = PostMapContent.mapRect(for: pins) {
                    Map(position: .constant(.rect(rect)), interactionModes: []) {
                        ForEach(pins, id: \.self) { pin in
                            Marker(pin.title.isEmpty ? "Location" : pin.title, coordinate: pin.coordinate)
                        }
                    }
                    .ignoresSafeArea()
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .allowsHitTesting(false)
                } else {
                    ContentUnavailableView("No locations for this day", systemImage: "map")
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityIdentifier("Journal blog item map")
    }
}

@MainActor
struct PostMapSnapshotter {
    func imageData(for pins: [PostMapPin]) async throws -> Data? {
        guard let rect = PostMapContent.mapRect(for: pins) else { return nil }
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = CGSize(width: 720, height: 720)
        options.scale = 1
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        options.pointOfInterestFilter = .excludingAll
        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await withTaskCancellationHandler {
            try await snapshotter.start()
        } onCancel: {
            snapshotter.cancel()
        }
        try Task.checkCancellation()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: options.size, format: format).pngData { _ in
            snapshot.image.draw(at: .zero)
            for pin in pins {
                let point = snapshot.point(for: pin.coordinate)
                let marker = UIImage(systemName: "mappin.circle.fill")?
                    .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
                marker?.draw(in: CGRect(x: point.x - 12, y: point.y - 24, width: 24, height: 24))
            }
        }
    }
}
