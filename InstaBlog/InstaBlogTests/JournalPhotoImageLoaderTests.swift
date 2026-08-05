import Testing
import UIKit
@testable import InstaBlog

@MainActor
@Suite(.serialized)
struct JournalPhotoImageLoaderTests {
    @Test func downscalesLargeImagesAndCachesByAssetVersion() async throws {
        JournalPhotoImageLoader.clearCache()
        let url = URL.temporaryDirectory.appending(path: "journal-photo-loader-test.png")
        defer { try? FileManager.default.removeItem(at: url) }

        try image(color: .red, size: CGSize(width: 1_000, height: 600)).pngData()!.write(to: url)
        let first = await JournalPhotoImageLoader.load(
            path: url.path,
            cacheKey: "asset-v1",
            maxPixelSize: 160
        )

        #expect(first?.cgImage?.width == 160)
        #expect(first?.cgImage?.height == 96)

        try image(color: .blue, size: CGSize(width: 1_000, height: 600)).pngData()!.write(to: url)
        let replacement = await JournalPhotoImageLoader.load(
            path: url.path,
            cacheKey: "asset-v2",
            maxPixelSize: 160
        )

        #expect(replacement?.averageColor == .blue)
    }

    @Test func reusesCachedImageWithoutDecodingAgain() async throws {
        JournalPhotoImageLoader.clearCache()
        JournalPhotoDecodeMetrics.shared.reset()
        let url = URL.temporaryDirectory.appending(path: "journal-loader-cache-hit.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try image(color: .red, size: CGSize(width: 1_000, height: 600)).pngData()!.write(to: url)

        _ = await JournalPhotoImageLoader.load(path: url.path, cacheKey: "cache-hit", maxPixelSize: 800)
        let second = await JournalPhotoImageLoader.load(path: url.path, cacheKey: "cache-hit", maxPixelSize: 800)

        #expect(second != nil)
        #expect(JournalPhotoDecodeMetrics.shared.snapshot.totalDecodes == 1)
    }

    @Test func deduplicatesConcurrentLoadsForTheSameKey() async throws {
        JournalPhotoImageLoader.clearCache()
        JournalPhotoDecodeMetrics.shared.reset()
        let url = URL.temporaryDirectory.appending(path: "journal-loader-dedup.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try image(color: .green, size: CGSize(width: 2_000, height: 1_500)).pngData()!.write(to: url)

        async let first = JournalPhotoImageLoader.load(path: url.path, cacheKey: "dedup", maxPixelSize: 800)
        async let second = JournalPhotoImageLoader.load(path: url.path, cacheKey: "dedup", maxPixelSize: 800)
        let results = await [first, second]

        #expect(results.compactMap { $0 }.count == 2)
        #expect(JournalPhotoDecodeMetrics.shared.snapshot.totalDecodes == 1)
    }

    @Test func boundsConcurrentDecodesAcrossDistinctPhotos() async throws {
        JournalPhotoImageLoader.clearCache()
        JournalPhotoDecodeMetrics.shared.reset()
        let urls = (0..<6).map {
            URL.temporaryDirectory.appending(path: "journal-loader-concurrency-\($0).png")
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in urls {
            try image(color: .purple, size: CGSize(width: 3_000, height: 2_000)).pngData()!.write(to: url)
        }
        let paths = urls.map(\.path)

        async let first = JournalPhotoImageLoader.load(path: paths[0], cacheKey: "c-0", maxPixelSize: 800)
        async let second = JournalPhotoImageLoader.load(path: paths[1], cacheKey: "c-1", maxPixelSize: 800)
        async let third = JournalPhotoImageLoader.load(path: paths[2], cacheKey: "c-2", maxPixelSize: 800)
        async let fourth = JournalPhotoImageLoader.load(path: paths[3], cacheKey: "c-3", maxPixelSize: 800)
        async let fifth = JournalPhotoImageLoader.load(path: paths[4], cacheKey: "c-4", maxPixelSize: 800)
        async let sixth = JournalPhotoImageLoader.load(path: paths[5], cacheKey: "c-5", maxPixelSize: 800)
        let results = await [first, second, third, fourth, fifth, sixth]

        #expect(results.compactMap { $0 }.count == 6)
        #expect(JournalPhotoDecodeMetrics.shared.snapshot.totalDecodes == 6)
        #expect(JournalPhotoDecodeMetrics.shared.snapshot.peakConcurrency <= 2)
        #expect(JournalPhotoDecodeMetrics.shared.snapshot.peakConcurrency >= 2)
    }

    @Test func cacheEvictsOlderImagesSoDecodedMemoryStaysBounded() async throws {
        JournalPhotoImageLoader.clearCache()
        JournalPhotoDecodeMetrics.shared.reset()
        let urls = (0..<25).map {
            URL.temporaryDirectory.appending(path: "journal-loader-evict-\($0).png")
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        for url in urls {
            try image(color: .orange, size: CGSize(width: 1_200, height: 1_000)).pngData()!.write(to: url)
        }

        for (index, url) in urls.enumerated() {
            _ = await JournalPhotoImageLoader.load(path: url.path, cacheKey: "evict-\(index)", maxPixelSize: 800)
        }
        #expect(JournalPhotoDecodeMetrics.shared.snapshot.totalDecodes == 25)

        _ = await JournalPhotoImageLoader.load(path: urls[0].path, cacheKey: "evict-0", maxPixelSize: 800)

        #expect(JournalPhotoDecodeMetrics.shared.snapshot.totalDecodes == 26)
    }

    @Test func clearCacheReleasesImages() async throws {
        JournalPhotoImageLoader.clearCache()
        JournalPhotoDecodeMetrics.shared.reset()
        let url = URL.temporaryDirectory.appending(path: "journal-loader-clear.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try image(color: .cyan, size: CGSize(width: 1_000, height: 600)).pngData()!.write(to: url)

        _ = await JournalPhotoImageLoader.load(path: url.path, cacheKey: "clear", maxPixelSize: 800)
        JournalPhotoImageLoader.clearCache()
        _ = await JournalPhotoImageLoader.load(path: url.path, cacheKey: "clear", maxPixelSize: 800)

        #expect(JournalPhotoDecodeMetrics.shared.snapshot.totalDecodes == 2)
    }

    private func image(color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

private extension UIImage {
    var averageColor: UIColor? {
        guard let cgImage else { return nil }
        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { pixel.deallocate() }
        guard let context = CGContext(
            data: pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255)
    }
}
