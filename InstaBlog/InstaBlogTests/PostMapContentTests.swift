import Foundation
import MapKit
import SwiftUI
import Testing
@testable import InstaBlog

@Suite("Post maps", .serialized)
struct PostMapContentTests {
    @MainActor @Test(arguments: [0.75, 1.5])
    func photoAndMapKeepIndependentAspectRatios(photoAspectRatio: Double) async throws {
        let imageSize = CGSize(width: 300 * photoAspectRatio, height: 300)
        let photoImage = UIGraphicsImageRenderer(size: imageSize).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-photo-\(UUID()).png")
        try #require(photoImage.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var post = item(latitude: 53.83736666666667, longitude: -0.42569166666666663)
        post.showMap = true
        post.photos = [PhotoItemDisplay(date: post.date, localImagePath: url.path,
                                       pixelWidth: Int(imageSize.width), pixelHeight: Int(imageSize.height))]
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let controller = UIHostingController(rootView: NavigationStack {
            ScrollView {
                BlogItemCard(item: post, dayItems: [post]).padding(18)
            }
            .environment(\.journalViewportSize, window.bounds.size)
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(1))
        controller.view.layoutIfNeeded()
        let map = try #require(findMap(in: controller.view))
        let contentWidth = window.bounds.width - 36
        #expect(abs(map.bounds.width - contentWidth) < 1)
        #expect(abs(map.bounds.width - map.bounds.height) < 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(rendered.pngData()).write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("map-photo-render-\(photoAspectRatio).png"))
        let cgImage = try #require(rendered.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                                                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        let photoRows = (0..<cgImage.height).filter { y in
            let offset = (y * cgImage.width + cgImage.width / 2) * 4
            return pixels[offset] > 240 && pixels[offset + 1] < 20 && pixels[offset + 2] > 240
        }
        let firstRow = try #require(photoRows.first)
        let lastRow = try #require(photoRows.last)
        let height = lastRow - firstRow + 1
        #expect(abs(Double(height) - Double(contentWidth) / photoAspectRatio) < 3)
    }

    @MainActor @Test(arguments: [false, true])
    func savedPostRendersNativeMapWithPinsAndLocalCamera(dayMap: Bool) async throws {
        let first = item(latitude: 53.83736666666667, longitude: -0.42569166666666663)
        let second = item(latitude: 53.843311666666665, longitude: -0.4334616666666667)
        var post = dayMap ? item() : first
        post.showMap = true
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let controller = UIHostingController(rootView: NavigationStack {
            ScrollView {
                BlogItemCard(item: post, dayItems: [first, second]).padding(18)
            }
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        var nativeMap: MKMapView?
        for _ in 0..<50 {
            nativeMap = findMap(in: controller.view)
            if let nativeMap, nativeMap.annotations.count >= (dayMap ? 2 : 1) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        let map = try #require(nativeMap)
        #expect(map.annotations.count == (dayMap ? 2 : 1))
        #expect(map.bounds.width > 300)
        #expect(abs(map.bounds.width - map.bounds.height) < 1)
        #expect(map.visibleMapRect.width * MKMetersPerMapPointAtLatitude(53.84) < 12_000)
        for annotation in map.annotations {
            #expect(map.visibleMapRect.contains(MKMapPoint(annotation.coordinate)))
        }
    }

    @MainActor private func findMap(in view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        return view.subviews.lazy.compactMap { findMap(in: $0) }.first
    }

    @Test func phoneDayLocationsStayInALocalBoundingBox() throws {
        let pins = [
            try #require(PostMapPin(latitude: 53.83736666666667, longitude: -0.42569166666666663, title: "Woodmansey")),
            try #require(PostMapPin(latitude: 53.843311666666665, longitude: -0.4334616666666667, title: "Beverley"))
        ]
        let rect = try #require(PostMapContent.mapRect(for: pins))
        #expect(rect.width * MKMetersPerMapPointAtLatitude(53.84) < 12_000)
        for pin in pins {
            #expect(rect.contains(MKMapPoint(pin.coordinate)))
        }
    }

    @Test func showMapIsDisabledWithoutAnyCoordinates() {
        #expect(!PostMapContent.isAvailable(latitude: nil, longitude: nil, otherItems: [item()]))
        #expect(!PostMapContent.isAvailable(latitude: 51, longitude: nil, otherItems: []))
        #expect(PostMapContent.isAvailable(latitude: 51, longitude: 0, otherItems: []))
        #expect(PostMapContent.isAvailable(latitude: nil, longitude: nil, otherItems: [item(latitude: 51, longitude: 0)]))
    }

    @Test func ownLocationTakesPriorityAndDayLocationsAreDeduplicated() throws {
        let located = item(latitude: 51, longitude: 0)
        let other = item(latitude: 52, longitude: 1)
        #expect(PostMapContent.pins(for: located, dayItems: [located, other]).count == 1)
        #expect(PostMapContent.pins(for: item(), dayItems: [located, located, other]).count == 2)
        #expect(PostMapContent.pins(for: item(), dayItems: [item()]).isEmpty)
        #expect(PostMapPin(latitude: .nan, longitude: 0, title: "") == nil)
    }

    @Test func squareBoundsProvideFiveKilometresAroundASinglePin() throws {
        let pin = try #require(PostMapPin(latitude: 51, longitude: 0, title: "London"))
        let rect = try #require(PostMapContent.mapRect(for: [pin]))
        let meters = rect.size.width * MKMetersPerMapPointAtLatitude(51)
        #expect(abs(meters - 10_000) < 1)
        #expect(rect.size.width == rect.size.height)
        let point = MKMapPoint(pin.coordinate)
        #expect(abs(rect.midX - point.x) < 0.001)
        #expect(abs(rect.midY - point.y) < 0.001)
    }

    @Test func multiplePinsHavePaddingAndDatelineCrossingUsesShortArc() throws {
        let pins = [
            try #require(PostMapPin(latitude: 51, longitude: 179.9, title: "East")),
            try #require(PostMapPin(latitude: 51.1, longitude: -179.9, title: "West"))
        ]
        let rect = try #require(PostMapContent.mapRect(for: pins))
        #expect(rect.width < MKMapRect.world.width / 100)
        for pin in pins {
            let point = MKMapPoint(pin.coordinate)
            let x = point.x < rect.minX ? point.x + MKMapRect.world.width : point.x
            let margin = min(x - rect.minX, rect.maxX - x, point.y - rect.minY, rect.maxY - point.y)
            #expect(margin * MKMetersPerMapPointAtLatitude(pin.latitude) >= 4_999)
        }
    }

    @Test func mapOnlyCreationUsesSelectedLocalDayAcrossDaylightSaving() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-25T16:00:00Z"))
        let result = PostMapContent.creationDate(date: date, timeZoneIdentifier: "Europe/London", isMapOnly: true)
        #expect(result == ISO8601DateFormatter().date(from: "2026-10-24T23:00:01Z"))
        #expect(PostMapContent.creationDate(date: date, timeZoneIdentifier: "UTC", isMapOnly: false) == date)
    }

    @Test func emailIncludesPNGAfterPhotosAndBeforeText() {
        var post = item()
        post.showMap = true
        post.blogText = "After the map"
        let data = Data([1, 2, 3])
        let draft = DayPostEmailGenerator(mapImages: [post.id: data]).generate(
            days: [DayPostDisplay(date: post.date, route: [], blogItems: [post])]
        )
        #expect(draft.imageAttachments.count == 1)
        #expect(draft.imageAttachments.first?.mimeType == "image/png")
        #expect(draft.imageAttachments.first?.data == data)
        #expect(draft.html.contains("cid:map-\(post.id.uuidString)@instablog"))
        #expect(draft.previewHTML.contains("data:image/png;base64,AQID"))
        #expect(draft.html.range(of: "alt=\"Map\"")!.lowerBound < draft.html.range(of: "After the map")!.lowerBound)
    }

    private func item(latitude: Double? = nil, longitude: Double? = nil) -> BlogItemDisplay {
        BlogItemDisplay(author: "Me", date: Date(timeIntervalSince1970: 0), blogText: "", location: "",
                        latitude: latitude, longitude: longitude, weather: WeatherDisplay())
    }
}
