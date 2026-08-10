import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreLocation
import ImageIO

nonisolated struct SharedPhotoLibrarySelection {
    let data: Data?
    let mimeType: String
    let assetIdentifier: String?
    let createdAt: Date?
    let coordinate: CLLocationCoordinate2D?
    let previewImage: UIImage?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let embeddedMetadata: PhotoAssetMetadata?
    let dataLoader: SharedPhotoLibraryDataLoader?

    init(
        data: Data?,
        mimeType: String,
        assetIdentifier: String?,
        createdAt: Date?,
        coordinate: CLLocationCoordinate2D?,
        previewImage: UIImage? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        embeddedMetadata: PhotoAssetMetadata? = nil,
        dataLoader: SharedPhotoLibraryDataLoader? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.assetIdentifier = assetIdentifier
        self.createdAt = createdAt
        self.coordinate = coordinate
        self.previewImage = previewImage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.embeddedMetadata = embeddedMetadata
        self.dataLoader = dataLoader
    }
}

nonisolated final class SharedPhotoLibraryDataLoader: @unchecked Sendable {
    private let result: PHPickerResult
    private let typeIdentifier: String
    private let assetIdentifier: String?
    private let createdAt: Date?
    private let coordinate: CLLocationCoordinate2D?

    init(
        result: PHPickerResult,
        typeIdentifier: String,
        assetIdentifier: String?,
        createdAt: Date?,
        coordinate: CLLocationCoordinate2D?
    ) {
        self.result = result
        self.typeIdentifier = typeIdentifier
        self.assetIdentifier = assetIdentifier
        self.createdAt = createdAt
        self.coordinate = coordinate
    }

    func loadOriginal() async throws -> SharedPhotoLibrarySelection {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SharedPhotoLibraryPickerError.missingImageData)
                }
            }
        }
        let inspection = await PhotoLibraryImageInspection.inspect(data)
        return SharedPhotoLibrarySelection(
            data: data,
            mimeType: UTType(typeIdentifier)?.preferredMIMEType ?? "image/jpeg",
            assetIdentifier: assetIdentifier,
            createdAt: createdAt,
            coordinate: coordinate,
            previewImage: inspection.previewCGImage.map(UIImage.init(cgImage:)),
            pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight,
            embeddedMetadata: inspection.metadata,
            dataLoader: nil
        )
    }

    func loadPreviewImage() async -> UIImage? {
        let box: PreviewImageBox = await withCheckedContinuation { continuation in
            result.itemProvider.loadPreviewImage(options: nil) { image, _ in
                continuation.resume(returning: PreviewImageBox(image: image as? UIImage))
            }
        }
        return box.image
    }
}

private struct PreviewImageBox: @unchecked Sendable {
    let image: UIImage?
}

struct SharedPhotoLibraryPicker: UIViewControllerRepresentable {
    let onComplete: (Result<SharedPhotoLibrarySelection?, Error>) -> Void
    var onPreview: ((SharedPhotoLibrarySelection) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onPreview: onPreview)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 1
        configuration.filter = .images
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: (Result<SharedPhotoLibrarySelection?, Error>) -> Void
        private let onPreview: ((SharedPhotoLibrarySelection) -> Void)?
        private var hasCompleted = false

        init(
            onComplete: @escaping (Result<SharedPhotoLibrarySelection?, Error>) -> Void,
            onPreview: ((SharedPhotoLibrarySelection) -> Void)?
        ) {
            self.onComplete = onComplete
            self.onPreview = onPreview
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !hasCompleted else { return }
            hasCompleted = true

            guard let result = results.first else {
                DispatchQueue.main.async {
                    self.onComplete(.success(nil))
                }
                return
            }

            let provider = result.itemProvider
            let asset: PHAsset? = result.assetIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier).map { $0.conforms(to: .image) } ?? false
            } ?? UTType.image.identifier

            provider.loadPreviewImage(options: nil) { [weak self] image, _ in
                guard let self,
                      let image = image as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.8) else {
                    return
                }

                let selection = SharedPhotoLibrarySelection(
                    data: data,
                    mimeType: "image/jpeg",
                    assetIdentifier: result.assetIdentifier,
                    createdAt: asset?.creationDate,
                    coordinate: asset?.location.map {
                        CLLocationCoordinate2D(
                            latitude: $0.coordinate.latitude,
                            longitude: $0.coordinate.longitude
                        )
                    }
                )
                DispatchQueue.main.async {
                    self.onPreview?(selection)
                }
            }

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                DispatchQueue.main.async {
                    if let error {
                        self.onComplete(.failure(error))
                        return
                    }

                    guard let data else {
                        self.onComplete(.failure(SharedPhotoLibraryPickerError.missingImageData))
                        return
                    }

                    let mimeType = UTType(typeIdentifier)?.preferredMIMEType ?? "image/jpeg"
                    self.onComplete(
                        .success(
                            SharedPhotoLibrarySelection(
                                data: data,
                                mimeType: mimeType,
                                assetIdentifier: result.assetIdentifier,
                                createdAt: asset?.creationDate,
                                coordinate: asset?.location.map {
                                    CLLocationCoordinate2D(
                                        latitude: $0.coordinate.latitude,
                                        longitude: $0.coordinate.longitude
                                    )
                                }
                            )
                        )
                    )
                }
            }
        }
    }
}

enum SharedPhotoLibraryPickerError: Error {
    case missingImageData
}

struct SharedMultiPhotoLibraryPicker: UIViewControllerRepresentable {
    static let maximumSelectionCount = 12

    let onComplete: (Result<[SharedPhotoLibrarySelection], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        // The editor intentionally retains each original until save. Keep that
        // memory bounded rather than accepting an unlimited set of originals.
        configuration.selectionLimit = Self.maximumSelectionCount
        configuration.filter = .images
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: (Result<[SharedPhotoLibrarySelection], Error>) -> Void
        private var hasCompleted = false

        init(onComplete: @escaping (Result<[SharedPhotoLibrarySelection], Error>) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !hasCompleted else { return }
            hasCompleted = true

            guard !results.isEmpty else {
                onComplete(.success([]))
                return
            }

            let pending = results.map(Self.makePendingSelection)
            Task { [weak self] in
                var selections: [SharedPhotoLibrarySelection] = []
                for selection in pending {
                    let preview = await selection.dataLoader?.loadPreviewImage()
                    selections.append(Self.selection(selection, preview: preview))
                }
                await MainActor.run {
                    self?.onComplete(.success(selections))
                }
            }
        }

        nonisolated private static func makePendingSelection(from result: PHPickerResult) -> SharedPhotoLibrarySelection {
            let provider = result.itemProvider
            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier).map { $0.conforms(to: .image) } ?? false
            } ?? UTType.image.identifier
            let asset: PHAsset? = result.assetIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            let createdAt = asset?.creationDate
            let coordinate = asset?.location.map {
                CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            }
            return SharedPhotoLibrarySelection(
                data: nil,
                mimeType: UTType(typeIdentifier)?.preferredMIMEType ?? "image/jpeg",
                assetIdentifier: result.assetIdentifier,
                createdAt: createdAt,
                coordinate: coordinate,
                dataLoader: SharedPhotoLibraryDataLoader(
                    result: result,
                    typeIdentifier: typeIdentifier,
                    assetIdentifier: result.assetIdentifier,
                    createdAt: createdAt,
                    coordinate: coordinate
                )
            )
        }

        nonisolated private static func selection(
            _ pending: SharedPhotoLibrarySelection,
            preview: UIImage?
        ) -> SharedPhotoLibrarySelection {
            SharedPhotoLibrarySelection(
                data: pending.data,
                mimeType: pending.mimeType,
                assetIdentifier: pending.assetIdentifier,
                createdAt: pending.createdAt,
                coordinate: pending.coordinate,
                previewImage: preview,
                pixelWidth: pending.pixelWidth,
                pixelHeight: pending.pixelHeight,
                embeddedMetadata: pending.embeddedMetadata,
                dataLoader: pending.dataLoader
            )
        }
    }
}

nonisolated private struct PhotoLibraryImageInspection: @unchecked Sendable {
    let metadata: PhotoAssetMetadata
    let pixelWidth: Int?
    let pixelHeight: Int?
    let previewCGImage: CGImage?

    static func inspect(_ data: Data) async -> Self {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.inspectSync(data))
            }
        }
    }

    static func inspectSync(_ data: Data) -> Self {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return Self(
                metadata: PhotoAssetMetadata(createdAt: nil, timeZoneIdentifier: nil, coordinate: nil),
                pixelWidth: nil,
                pixelHeight: nil,
                previewCGImage: nil
            )
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let previewOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_600
        ]
        let dimensions = OrientedImageDimensions.orientedDimensions(of: source)
        return Self(
            metadata: PhotoAssetMetadata.extract(from: source, properties: properties),
            pixelWidth: dimensions?.width,
            pixelHeight: dimensions?.height,
            previewCGImage: CGImageSourceCreateThumbnailAtIndex(source, 0, previewOptions as CFDictionary)
        )
    }
}
