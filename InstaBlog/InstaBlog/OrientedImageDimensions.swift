import Foundation
import ImageIO

/// Computes the pixel dimensions an image has once its EXIF orientation is
/// applied. Persisted dimensions drive the filmstrip tile layout, so they must
/// match what the decoded (orientation-transformed) image will display.
nonisolated enum OrientedImageDimensions {
    /// Dimensions after applying the EXIF orientation to the raw pixel size.
    static func oriented(rawWidth: Int, rawHeight: Int, exifOrientation: Int) -> (width: Int, height: Int) {
        switch exifOrientation {
        case 5, 6, 7, 8:
            (rawHeight, rawWidth)
        default:
            (rawWidth, rawHeight)
        }
    }

    static func orientedDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return orientedDimensions(of: source)
    }

    static func orientedDimensions(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return orientedDimensions(of: source)
    }

    static func orientedDimensions(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return oriented(rawWidth: width, rawHeight: height, exifOrientation: orientation)
    }
}
