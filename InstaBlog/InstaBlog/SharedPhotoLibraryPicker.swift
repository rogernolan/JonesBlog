import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreLocation
import ImageIO

struct SharedPhotoLibrarySelection {
    let data: Data
    let mimeType: String
    let assetIdentifier: String?
    let createdAt: Date?
    let coordinate: CLLocationCoordinate2D?
    let previewImage: UIImage?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let embeddedMetadata: PhotoAssetMetadata?

    init(
        data: Data,
        mimeType: String,
        assetIdentifier: String?,
        createdAt: Date?,
        coordinate: CLLocationCoordinate2D?,
        previewImage: UIImage? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        embeddedMetadata: PhotoAssetMetadata? = nil
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
    }
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
    case importFailed(String)
}

struct SharedMultiPhotoLibraryPicker: UIViewControllerRepresentable {
    static let maximumSelectionCount = 12
    static let maximumConcurrentImports = 3

    let onComplete: (Result<[SharedPhotoLibrarySelection], Error>) -> Void
    var onPartialFailure: ((Int) -> Void)? = nil
    var onImportStarted: ((Int) -> Void)? = nil
    var onImportProgress: ((Int, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onComplete: onComplete,
            onPartialFailure: onPartialFailure,
            onImportStarted: onImportStarted,
            onImportProgress: onImportProgress
        )
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
        private let onPartialFailure: ((Int) -> Void)?
        private let onImportStarted: ((Int) -> Void)?
        private let onImportProgress: ((Int, Int) -> Void)?
        private var importTask: Task<Void, Never>?

        init(
            onComplete: @escaping (Result<[SharedPhotoLibrarySelection], Error>) -> Void,
            onPartialFailure: ((Int) -> Void)?,
            onImportStarted: ((Int) -> Void)?,
            onImportProgress: ((Int, Int) -> Void)?
        ) {
            self.onComplete = onComplete
            self.onPartialFailure = onPartialFailure
            self.onImportStarted = onImportStarted
            self.onImportProgress = onImportProgress
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                onComplete(.success([]))
                return
            }
            importTask?.cancel()
            let requests = results.map(PhotoLibraryImportRequest.init)
            onImportStarted?(requests.count)
            importTask = Task { [weak self] in
                let batch = await PhotoLibraryImportScheduler.process(
                    requests,
                    maximumConcurrentOperations: SharedMultiPhotoLibraryPicker.maximumConcurrentImports,
                    progress: { completed, total in
                        await MainActor.run { self?.onImportProgress?(completed, total) }
                    }
                ) { request in
                    try await Self.load(request)
                }

                guard !Task.isCancelled, let self else { return }
                let selections = batch.successes.map { Self.selection(from: $0.value) }
                await MainActor.run {
                    if selections.isEmpty, let failure = batch.failures.first {
                        self.onComplete(.failure(SharedPhotoLibraryPickerError.importFailed(failure.description)))
                    } else {
                        self.onComplete(.success(selections))
                        if !batch.failures.isEmpty {
                            self.onPartialFailure?(batch.failures.count)
                        }
                    }
                }
            }
        }

        deinit {
            importTask?.cancel()
        }

        private static func load(_ request: PhotoLibraryImportRequest) async throws -> LoadedPhotoLibrarySelection {
            let result = request.result
            let provider = result.itemProvider
            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier).map { $0.conforms(to: .image) } ?? false
            } ?? UTType.image.identifier
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: SharedPhotoLibraryPickerError.missingImageData)
                    }
                }
            }
            let asset: PHAsset? = result.assetIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            let inspection = await inspect(data)
            return LoadedPhotoLibrarySelection(
                data: data,
                mimeType: UTType(typeIdentifier)?.preferredMIMEType ?? "image/jpeg",
                assetIdentifier: result.assetIdentifier,
                createdAt: asset?.creationDate,
                coordinate: asset?.location.map {
                    CLLocationCoordinate2D(
                        latitude: $0.coordinate.latitude,
                        longitude: $0.coordinate.longitude
                    )
                },
                inspection: inspection
            )
        }

        private static func selection(from loaded: LoadedPhotoLibrarySelection) -> SharedPhotoLibrarySelection {
            SharedPhotoLibrarySelection(
                data: loaded.data,
                mimeType: loaded.mimeType,
                assetIdentifier: loaded.assetIdentifier,
                createdAt: loaded.createdAt,
                coordinate: loaded.coordinate,
                previewImage: loaded.inspection.previewCGImage.map(UIImage.init(cgImage:)),
                pixelWidth: loaded.inspection.pixelWidth,
                pixelHeight: loaded.inspection.pixelHeight,
                embeddedMetadata: loaded.inspection.metadata
            )
        }

        private static func inspect(_ data: Data) async -> PhotoLibraryImageInspection {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: PhotoLibraryImageInspection.inspect(data))
                }
            }
        }
    }
}

private struct PhotoLibraryImportRequest: @unchecked Sendable {
    let result: PHPickerResult

    nonisolated init(_ result: PHPickerResult) {
        self.result = result
    }
}

private struct LoadedPhotoLibrarySelection: @unchecked Sendable {
    let data: Data
    let mimeType: String
    let assetIdentifier: String?
    let createdAt: Date?
    let coordinate: CLLocationCoordinate2D?
    let inspection: PhotoLibraryImageInspection
}

private struct PhotoLibraryImageInspection: @unchecked Sendable {
    let metadata: PhotoAssetMetadata
    let pixelWidth: Int?
    let pixelHeight: Int?
    let previewCGImage: CGImage?

    static func inspect(_ data: Data) -> Self {
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
        return Self(
            metadata: PhotoAssetMetadata.extract(from: source, properties: properties),
            pixelWidth: properties?[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: properties?[kCGImagePropertyPixelHeight] as? Int,
            previewCGImage: CGImageSourceCreateThumbnailAtIndex(source, 0, previewOptions as CFDictionary)
        )
    }
}
