import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import InstaBlog

@Suite("Oriented image dimensions")
struct OrientedImageDimensionsTests {
    @Test func swapsWidthAndHeightForRotatedOrientations() {
        #expect(
            OrientedImageDimensions.oriented(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 1)
                == (4_032, 3_024)
        )
        #expect(
            OrientedImageDimensions.oriented(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 4)
                == (4_032, 3_024)
        )
        #expect(
            OrientedImageDimensions.oriented(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 5)
                == (3_024, 4_032)
        )
        #expect(
            OrientedImageDimensions.oriented(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 6)
                == (3_024, 4_032)
        )
        #expect(
            OrientedImageDimensions.oriented(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 7)
                == (3_024, 4_032)
        )
        #expect(
            OrientedImageDimensions.oriented(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 8)
                == (3_024, 4_032)
        )
    }

    @Test func reportsOrientedDimensionsForRotatedJPEGData() throws {
        let data = try makeOrientedJPEG(rawWidth: 4_032, rawHeight: 3_024, exifOrientation: 6)

        let dimensions = try #require(OrientedImageDimensions.orientedDimensions(of: data))
        #expect(dimensions == (3_024, 4_032))
    }

    @Test func reportsUnalteredDimensionsWithoutExifOrientation() throws {
        let data = try makeOrientedJPEG(rawWidth: 800, rawHeight: 600, exifOrientation: 1)

        let dimensions = try #require(OrientedImageDimensions.orientedDimensions(of: data))
        #expect(dimensions == (800, 600))
    }

    private func makeOrientedJPEG(rawWidth: Int, rawHeight: Int, exifOrientation: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: rawWidth,
                  height: rawHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage()
        else { throw OrientedImageDimensionsTestError.encodingFailed }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw OrientedImageDimensionsTestError.encodingFailed }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: exifOrientation]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OrientedImageDimensionsTestError.encodingFailed
        }
        return encoded as Data
    }
}

private enum OrientedImageDimensionsTestError: Error {
    case encodingFailed
}
