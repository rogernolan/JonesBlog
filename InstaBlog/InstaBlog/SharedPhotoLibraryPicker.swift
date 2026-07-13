import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import CoreLocation

struct SharedPhotoLibrarySelection {
    let data: Data
    let mimeType: String
    let assetIdentifier: String?
    let createdAt: Date?
    let coordinate: CLLocationCoordinate2D?
}

struct SharedPhotoLibraryPicker: UIViewControllerRepresentable {
    let onComplete: (Result<SharedPhotoLibrarySelection?, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
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
        private var hasCompleted = false

        init(onComplete: @escaping (Result<SharedPhotoLibrarySelection?, Error>) -> Void) {
            self.onComplete = onComplete
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
