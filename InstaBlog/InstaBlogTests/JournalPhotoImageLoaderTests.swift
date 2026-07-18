import Testing
import UIKit
@testable import InstaBlog

@MainActor
struct JournalPhotoImageLoaderTests {
    @Test func downscalesLargeImagesAndCachesByAssetVersion() async throws {
        JournalPhotoImageLoader.clearCache()
        let url = URL.temporaryDirectory.appending(path: "journal-photo-loader-test.png")
        defer { try? FileManager.default.removeItem(at: url) }

        try image(color: .red).pngData()!.write(to: url)
        let first = await JournalPhotoImageLoader.load(
            path: url.path,
            cacheKey: "asset-v1",
            maxPixelSize: 160
        )

        #expect(first?.cgImage?.width == 160)
        #expect(first?.cgImage?.height == 96)

        try image(color: .blue).pngData()!.write(to: url)
        let replacement = await JournalPhotoImageLoader.load(
            path: url.path,
            cacheKey: "asset-v2",
            maxPixelSize: 160
        )

        #expect(replacement?.averageColor == .blue)
    }

    private func image(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1_000, height: 600)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 600))
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
