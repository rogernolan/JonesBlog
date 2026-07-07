import AVFoundation
import Combine
import CoreLocation
import ImageIO
import OSLog
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PhotoPostCaptureStartMode {
    case sourcePicker
    case camera
}

private enum PhotoPostCaptureStep {
    case sourcePicker
    case camera
}

struct PhotoPostCaptureFlow: View {
    let journalService: JournalService?
    var startMode: PhotoPostCaptureStartMode = .camera
    var destinationGalleryID: Gallery.ID? = nil
    var onAutomaticGalleryPlacement: (BlogItem.ID, Gallery.ID) -> Void = { _, _ in }
    let onSave: (TripDisplay) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraCaptureModel()
    @StateObject private var photoLibrary = PhotoLibrarySourcePickerModel()
    @State private var draft: PhotoPostDraft?
    @State private var isSaving = false
    @State private var isLoadingLibrarySelection = false
    @State private var errorMessage: String?
    @StateObject private var captureProfiling = PhotoCaptureProfilingSession()
    @State private var hasPrimedWeather = false
    @State private var currentStep: PhotoPostCaptureStep

    init(
        journalService: JournalService?,
        startMode: PhotoPostCaptureStartMode = .camera,
        destinationGalleryID: Gallery.ID? = nil,
        onAutomaticGalleryPlacement: @escaping (BlogItem.ID, Gallery.ID) -> Void = { _, _ in },
        onSave: @escaping (TripDisplay) -> Void
    ) {
        self.journalService = journalService
        self.startMode = startMode
        self.destinationGalleryID = destinationGalleryID
        self.onAutomaticGalleryPlacement = onAutomaticGalleryPlacement
        self.onSave = onSave
        _currentStep = State(initialValue: startMode == .camera ? .camera : .sourcePicker)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    PhotoPostEditorView(
                        draft: draft,
                        isSaving: isSaving,
                        onCancel: { dismiss() },
                        onSave: savePhotoPost,
                        onAppear: { captureProfiling.markEditorAppeared() },
                        onFocusRequested: { captureProfiling.markCaptionFocusRequested() },
                        onFocusAcquired: { captureProfiling.markCaptionFocusAcquired() }
                    )
                } else {
                    switch currentStep {
                    case .sourcePicker:
                        PhotoLibrarySourcePickerView(
                            model: photoLibrary,
                            isLoadingSelection: isLoadingLibrarySelection,
                            onCancel: { dismiss() },
                            onShowCamera: showCamera,
                            onSelectAsset: selectLibraryAsset
                        )
                    case .camera:
                        PhotoCaptureWorkspace(
                            camera: camera,
                            onChooseLibrary: showSourcePicker,
                            onCapture: capturePhoto,
                            onCancel: handleCameraCancel
                        )
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: currentStep) {
            guard draft == nil else { return }
            if let seededDraft = Self.uiTestingSeededDraft() {
                draft = seededDraft
            } else {
                if let journalService, !Self.isRunningUITests, !hasPrimedWeather {
                    hasPrimedWeather = true
                    Task {
                        await journalService.primeWeatherCapture()
                    }
                }

                switch currentStep {
                case .sourcePicker:
                    camera.stop()
                    await photoLibrary.prepare()
                case .camera:
                    await camera.prepare()
                }
            }
        }
        .onDisappear {
            camera.stop()
        }
        .alert("Unable to create photo post", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func showSourcePicker() {
        camera.stop()
        currentStep = .sourcePicker
    }

    private func showCamera() {
        currentStep = .camera
    }

    private func handleCameraCancel() {
        if startMode == .sourcePicker {
            showSourcePicker()
        } else {
            dismiss()
        }
    }

    private func capturePhoto() {
        captureProfiling.beginCaptureToCaption()
        Task {
            do {
                let capturedPhoto = try await camera.capturePhoto()
                await MainActor.run {
                    captureProfiling.markPhotoCaptureReturned()
                }
                await MainActor.run {
                    camera.stop()
                    draft = PhotoPostDraft(
                        source: .camera,
                        previewImage: nil,
                        imageData: capturedPhoto.data,
                        mimeType: capturedPhoto.mimeType,
                        createdAt: Date.now,
                        timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                        coordinate: nil,
                        pixelWidth: capturedPhoto.pixelWidth,
                        pixelHeight: capturedPhoto.pixelHeight
                    )
                    captureProfiling.markDraftReadyForEditing()
                }
                loadDraftPreviewImage(from: capturedPhoto.data)
            } catch {
                await MainActor.run {
                    captureProfiling.markCaptureFailed()
                }
                await MainActor.run {
                    errorMessage = "The camera photo could not be captured. Please try again."
                }
            }
        }
    }

    private func selectLibraryAsset(_ asset: PHAsset) {
        Task {
            await MainActor.run {
                isLoadingLibrarySelection = true
            }

            defer {
                Task { @MainActor in
                    isLoadingLibrarySelection = false
                }
            }

            guard let selection = await photoLibrary.loadSelection(for: asset) else {
                await MainActor.run {
                    errorMessage = "The selected photo could not be loaded."
                }
                return
            }

            await loadLibraryPhoto(from: selection)
        }
    }

    @MainActor
    private func loadLibraryPhoto(from selection: SharedPhotoLibrarySelection) async {
        let data = selection.data
        let metadata = PhotoAssetMetadata.extract(from: data)
        let pixelSize = PhotoPreviewImageFactory.pixelSize(from: data)
        draft = PhotoPostDraft(
            source: .library,
            previewImage: nil,
            imageData: data,
            mimeType: selection.mimeType,
            createdAt: selection.createdAt ?? metadata.createdAt ?? Date.now,
            timeZoneIdentifier: metadata.timeZoneIdentifier,
            coordinate: selection.coordinate ?? metadata.coordinate,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height
        )
        loadDraftPreviewImage(from: data)
    }

    private func loadDraftPreviewImage(from data: Data) {
        Task.detached(priority: .userInitiated) {
            let previewImage = PhotoPreviewImageFactory.makePreviewImage(from: data)
            await MainActor.run {
                guard let draft, draft.imageData == data else { return }
                self.draft = PhotoPostDraft(
                    source: draft.source,
                    previewImage: previewImage,
                    imageData: draft.imageData,
                    mimeType: draft.mimeType,
                    createdAt: draft.createdAt,
                    timeZoneIdentifier: draft.timeZoneIdentifier,
                    coordinate: draft.coordinate,
                    pixelWidth: draft.pixelWidth,
                    pixelHeight: draft.pixelHeight
                )
            }
        }
    }

    private func savePhotoPost(caption: String) {
        guard let journalService, let draft else {
            dismiss()
            return
        }

        let createdAt = draft.createdAt
        let timeZoneIdentifier = draft.timeZoneIdentifier
        let imageData = draft.imageData
        let mimeType = draft.mimeType
        let pixelWidth = draft.pixelWidth
        let pixelHeight = draft.pixelHeight
        let coordinate = draft.coordinate
        let shouldEnrichWithCurrentWeather = draft.source == .camera
        isSaving = true
        Task {
            do {
                let trip = try await persistPhotoPost(
                    using: journalService,
                    caption: caption,
                    createdAt: createdAt,
                    timeZoneIdentifier: timeZoneIdentifier,
                    imageData: imageData,
                    mimeType: mimeType,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    coordinate: coordinate,
                    shouldEnrichWithCurrentWeather: shouldEnrichWithCurrentWeather
                )
                if let trip {
                    onSave(trip)
                }
                dismiss()
            } catch {
                isSaving = false
                errorMessage = "The new BlogItem could not be saved."
            }
        }
    }

    private func persistPhotoPost(
        using journalService: JournalService,
        caption: String,
        createdAt: Date,
        timeZoneIdentifier: String?,
        imageData: Data,
        mimeType: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        coordinate: CLLocationCoordinate2D?,
        shouldEnrichWithCurrentWeather: Bool
    ) async throws -> TripDisplay? {
        let blogItemID = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let blogItemID = try journalService.createPhotoBlogItem(
                        caption: caption,
                        date: createdAt,
                        timeZoneIdentifier: timeZoneIdentifier,
                        imageData: imageData,
                        mimeType: mimeType,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight,
                        latitude: coordinate?.latitude,
                        longitude: coordinate?.longitude,
                        destinationGalleryID: destinationGalleryID
                    )
                    continuation.resume(returning: blogItemID)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        if shouldEnrichWithCurrentWeather {
            await journalService.captureWeather(for: blogItemID)
        } else if let coordinate {
            await journalService.captureHistoricalWeather(
                for: blogItemID,
                at: createdAt,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }

        if destinationGalleryID == nil {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try journalService.retryAutomaticGalleryPlacement(for: blogItemID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        let trip: TripDisplay? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try journalService.loadCurrentTrip())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        if destinationGalleryID == nil,
           let galleryID = try journalService.galleryContaining(blogItemID) {
            await MainActor.run {
                onAutomaticGalleryPlacement(blogItemID, galleryID)
            }
        }
        return trip
    }

    private static func uiTestingSeededDraft() -> PhotoPostDraft? {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-photo-post-draft") else {
            return nil
        }

        let size = CGSize(width: 12, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            return nil
        }

        return PhotoPostDraft(
            source: .camera,
            previewImage: image,
            imageData: imageData,
            mimeType: "image/jpeg",
            createdAt: Date.now,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            coordinate: nil,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height)
        )
    }

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database")
    }
}

private enum PhotoPreviewImageFactory {
    nonisolated static func makePreviewImage(from data: Data, maxPixelSize: Int = 1_600) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    nonisolated static func pixelSize(from data: Data) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }

        return (
            properties[kCGImagePropertyPixelWidth] as? Int,
            properties[kCGImagePropertyPixelHeight] as? Int
        )
    }
}

private struct PhotoAssetMetadata {
    let createdAt: Date?
    let timeZoneIdentifier: String?
    let coordinate: CLLocationCoordinate2D?

    static func extract(from data: Data) -> Self {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return Self(createdAt: nil, timeZoneIdentifier: nil, coordinate: nil)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        return Self(
            createdAt: captureDate(exif: exif, tiff: tiff),
            timeZoneIdentifier: nil,
            coordinate: coordinate(from: gps)
        )
    }

    private static func captureDate(
        exif: [CFString: Any]?,
        tiff: [CFString: Any]?
    ) -> Date? {
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let offsetString = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String

        guard let dateString else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if let offsetString {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: dateString + offsetString) {
                return date
            }
        }

        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: dateString)
    }

    private static func coordinate(from gps: [CFString: Any]?) -> CLLocationCoordinate2D? {
        guard let gps,
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }

        let latitudeRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let longitudeRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()

        let signedLatitude = latitudeRef == "S" ? -latitude : latitude
        let signedLongitude = longitudeRef == "W" ? -longitude : longitude
        return CLLocationCoordinate2D(latitude: signedLatitude, longitude: signedLongitude)
    }
}

private struct PhotoCaptureWorkspace: View {
    @ObservedObject var camera: CameraCaptureModel
    let onChooseLibrary: () -> Void
    let onCapture: () -> Void
    let onCancel: () -> Void
    @State private var isPinchingToZoom = false

    var body: some View {
        GeometryReader { proxy in
            let topReservedHeight = max(88, proxy.safeAreaInsets.top + 42)

            VStack(spacing: 0) {
                Color.black
                    .frame(height: topReservedHeight)

                previewSection
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)

                controls
            }
            .background(Color.black)
            .ignoresSafeArea()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.white)
            }
        }
    }

    private var previewSection: some View {
        ZStack(alignment: .bottom) {
            switch camera.state {
            case .ready:
                ZStack {
                    CameraPreviewView(
                        session: camera.session,
                        onPreviewLayerReady: camera.setPreviewLayer,
                        onPreviewViewReady: camera.setPreviewView
                    )
                    .clipShape(.rect(cornerRadius: 0))
                    .gesture(zoomGesture)
                    .opacity(camera.livePreviewOpacity)

                    if let outgoingSnapshotView = camera.outgoingPreviewSnapshotView {
                        if let incomingSnapshotView = camera.incomingPreviewSnapshotView {
                            ZStack {
                                PreviewSnapshotView(snapshotView: outgoingSnapshotView)
                                    .opacity(camera.flipCardAngle <= 90 ? 1 : 0)

                                PreviewSnapshotView(snapshotView: incomingSnapshotView)
                                    .rotation3DEffect(
                                        .degrees(180),
                                        axis: (x: 0, y: 1, z: 0)
                                    )
                                    .opacity(camera.flipCardAngle >= 90 ? 1 : 0)
                            }
                            .rotation3DEffect(
                                .degrees(camera.flipCardAngle),
                                axis: (x: 0, y: 1, z: 0),
                                perspective: 0.78
                            )
                        } else {
                            PreviewSnapshotView(snapshotView: outgoingSnapshotView)
                        }
                    }
                }
            case .requestingPermission:
                ProgressView("Preparing camera…")
                    .tint(.white)
                    .foregroundStyle(.white)
            case .denied:
                captureFallback(
                    title: "Camera access denied",
                    message: "Allow camera access in Settings to take a new photo. You can still choose one from the library."
                )
            case .unavailable:
                captureFallback(
                    title: "Camera unavailable",
                    message: "This device cannot show a live camera preview right now. Choose a photo from the library instead."
                )
            case .failed:
                captureFallback(
                    title: "Camera unavailable",
                    message: "The live camera preview could not start. Choose a photo from the library instead."
                )
            }

            if camera.state == .ready {
                zoomRail
                    .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private var controls: some View {
        VStack(spacing: 18) {
            if camera.state == .ready {
                Button(action: onCapture) {
                    Circle()
                        .fill(.white)
                        .frame(width: 68, height: 68)
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.35), lineWidth: 5)
                                .padding(-8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take photo")
            }

            HStack(alignment: .center) {
                Button(action: onChooseLibrary) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 28, weight: .medium))
                        Text("Library")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 60)
                }
                .buttonStyle(.plain)

                Spacer()

                Color.clear
                    .frame(width: 96, height: 54)

                Spacer()

                Button(action: camera.flipCamera) {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 26, weight: .medium))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.45), in: Circle())

                        Text(" ")
                            .font(.system(size: 16, weight: .medium))
                            .hidden()
                    }
                    .frame(width: 84, height: 60)
                }
                .buttonStyle(.plain)
                .disabled(!camera.canFlipCamera || camera.state != .ready || camera.isFlippingCamera)
                .opacity(camera.canFlipCamera && !camera.isFlippingCamera ? 1 : 0.45)
                .accessibilityLabel("Flip camera")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .background(Color.black)
    }

    private var zoomRail: some View {
        HStack(spacing: 12) {
            ForEach(camera.zoomOptions, id: \.self) { zoomFactor in
                Button(action: { camera.selectZoomFactor(zoomFactor) }) {
                    let isSelected = camera.isSelectedZoom(zoomFactor)

                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(Color(red: 0.29, green: 0.22, blue: 0.18).opacity(0.88))
                                .frame(width: 44, height: 44)
                        }

                        Text(zoomLabel(for: zoomFactor))
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.yellow : Color.white)
                            .frame(width: 44, height: 36)
                            .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    }
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(zoomLabel(for: zoomFactor)) zoom")
            }
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                if !isPinchingToZoom {
                    isPinchingToZoom = true
                    camera.beginInteractiveZoom()
                }
                camera.updateInteractiveZoom(with: magnification)
            }
            .onEnded { _ in
                isPinchingToZoom = false
                camera.endInteractiveZoom()
            }
    }

    private func zoomLabel(for factor: CGFloat) -> String {
        let rounded = (factor * 10).rounded() / 10
        let format = rounded == rounded.rounded() ? "%.0f" : "%.1f"
        let baseLabel = String(format: format, rounded)
        return camera.isSelectedZoom(factor) ? "\(baseLabel)x" : baseLabel
    }

    private func captureFallback(title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
            Text(title)
                .font(.title2.weight(.bold))
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(24)
    }
}

private struct PhotoLibrarySourcePickerView: View {
    @ObservedObject var model: PhotoLibrarySourcePickerModel
    let isLoadingSelection: Bool
    let onCancel: () -> Void
    let onShowCamera: () -> Void
    let onSelectAsset: (PHAsset) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                content
            }

            if isLoadingSelection {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                        .padding(24)
                        .background(.black.opacity(0.72), in: .rect(cornerRadius: 18))
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)

            Spacer()

            Button(action: onShowCamera) {
                Image(systemName: "camera")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            Spacer()
            ProgressView()
                .tint(.white)
            Spacer()
        case .ready:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.assets, id: \.localIdentifier) { asset in
                        Button(action: { onSelectAsset(asset) }) {
                            PhotoLibraryAssetThumbnailView(asset: asset, imageManager: model.imageManager)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingSelection)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        case .empty:
            permissionMessage(
                title: "No photos available",
                message: "Choose the camera to take a new photo instead."
            )
        case .denied:
            permissionMessage(
                title: "Photo access is off",
                message: "Allow photo library access in Settings to choose a photo here."
            )
        }
    }

    private func permissionMessage(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}

private struct PhotoLibraryAssetThumbnailView: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.08))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .tint(.white.opacity(0.7))
            }
        }
        .clipped()
        .task(id: asset.localIdentifier) {
            loadImage()
        }
        .onDisappear {
            if let requestID {
                imageManager.cancelImageRequest(requestID)
            }
        }
    }

    private func loadImage() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 420, height: 420),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            self.image = image
        }
    }
}

@MainActor
private final class PhotoLibrarySourcePickerModel: ObservableObject {
    enum State {
        case loading
        case ready
        case empty
        case denied
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var assets: [PHAsset] = []

    let imageManager = PHCachingImageManager()

    func prepare() async {
        let status = await ensureAuthorization()
        guard status == .authorized || status == .limited else {
            state = .denied
            assets = []
            return
        }

        state = .loading

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]

        let fetchedAssets = PHAsset.fetchAssets(with: .image, options: options)
        var resolvedAssets: [PHAsset] = []
        resolvedAssets.reserveCapacity(fetchedAssets.count)
        fetchedAssets.enumerateObjects { asset, _, _ in
            resolvedAssets.append(asset)
        }

        assets = resolvedAssets
        state = resolvedAssets.isEmpty ? .empty : .ready
    }

    func loadSelection(for asset: PHAsset) async -> SharedPhotoLibrarySelection? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }

                let mimeType = dataUTI.flatMap { UTType($0)?.preferredMIMEType } ?? "image/jpeg"
                continuation.resume(
                    returning: SharedPhotoLibrarySelection(
                        data: data,
                        mimeType: mimeType,
                        createdAt: asset.creationDate,
                        coordinate: asset.location.map {
                            CLLocationCoordinate2D(
                                latitude: $0.coordinate.latitude,
                                longitude: $0.coordinate.longitude
                            )
                        }
                    )
                )
            }
        }
    }

    private func ensureAuthorization() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch currentStatus {
        case .authorized, .limited:
            return currentStatus
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .restricted, .denied:
            return currentStatus
        @unknown default:
            return .denied
        }
    }
}

private struct PhotoPostEditorView: View {
    let draft: PhotoPostDraft
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (String) -> Void
    let onAppear: () -> Void
    let onFocusRequested: () -> Void
    let onFocusAcquired: () -> Void

    @State private var caption: String
    @FocusState private var isCaptionFocused: Bool

    init(
        draft: PhotoPostDraft,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void,
        onAppear: @escaping () -> Void = {},
        onFocusRequested: @escaping () -> Void = {},
        onFocusAcquired: @escaping () -> Void = {}
    ) {
        self.draft = draft
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        self.onAppear = onAppear
        self.onFocusRequested = onFocusRequested
        self.onFocusAcquired = onFocusAcquired
        _caption = State(initialValue: ProcessInfo.processInfo.environment["UI_TEST_PHOTO_POST_CAPTION"] ?? "")
    }

    var body: some View {
        ScrollViewReader { scrollView in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Group {
                        if let previewImage = draft.previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                ProgressView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 24))
                    .clipped()

                    Text("Say something about this photo:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $caption)
                        .font(.body)
                        .frame(minHeight: 170)
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                        .accessibilityIdentifier("Photo post caption")
                        .disabled(isSaving)
                        .focused($isCaptionFocused)
                        .id("photo-post-caption-editor")

                    LabeledContent("Date", value: draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: isCaptionFocused) { _, focused in
                guard focused else { return }
                onFocusAcquired()
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollView.scrollTo("photo-post-caption-editor", anchor: .bottom)
                }
            }
            .task {
                guard !isSaving else { return }
                onFocusRequested()
                await MainActor.run {
                    isCaptionFocused = true
                }
            }
            .onAppear(perform: onAppear)
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                        ProgressView("Saving photo post...")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(.regularMaterial, in: .rect(cornerRadius: 18))
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("New entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        onSave(caption)
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

@MainActor
private final class PhotoCaptureProfilingSession: ObservableObject {
    private let signposter = OSSignposter(
        logger: Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "InstaBlog",
            category: "PointsOfInterest"
        )
    )
    private var intervalState: OSSignpostIntervalState?
    private var signpostID: OSSignpostID?

    func beginCaptureToCaption() {
        endCaptureToCaptionIfNeeded()
        let signpostID = signposter.makeSignpostID()
        self.signpostID = signpostID
        intervalState = signposter.beginInterval("Capture to caption focus", id: signpostID)
        signposter.emitEvent("Capture button tapped", id: signpostID)
    }

    func markPhotoCaptureReturned() {
        emitEvent("Photo capture returned")
    }

    func markDraftReadyForEditing() {
        emitEvent("Draft ready for editing")
    }

    func markEditorAppeared() {
        emitEvent("Editor appeared")
    }

    func markCaptionFocusRequested() {
        emitEvent("Caption focus requested")
    }

    func markCaptionFocusAcquired() {
        emitEvent("Caption focus acquired")
        endCaptureToCaptionIfNeeded()
    }

    func markCaptureFailed() {
        emitEvent("Capture failed")
        endCaptureToCaptionIfNeeded()
    }

    private func emitEvent(_ name: StaticString) {
        guard let signpostID else { return }
        signposter.emitEvent(name, id: signpostID)
    }

    private func endCaptureToCaptionIfNeeded() {
        guard let intervalState else { return }
        signposter.endInterval("Capture to caption focus", intervalState)
        self.intervalState = nil
        signpostID = nil
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onPreviewLayerReady: (AVCaptureVideoPreviewLayer) -> Void
    let onPreviewViewReady: (CameraPreviewUIView) -> Void

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onPreviewLayerReady(view.previewLayer)
        onPreviewViewReady(view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer.session = session
        onPreviewLayerReady(uiView.previewLayer)
        onPreviewViewReady(uiView)
    }
}

private final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private struct PreviewSnapshotView: UIViewRepresentable {
    let snapshotView: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attachSnapshot(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attachSnapshot(to: uiView)
    }

    private func attachSnapshot(to container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        snapshotView.frame = container.bounds
        snapshotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(snapshotView)
    }
}

@MainActor
final class CameraCaptureModel: NSObject, ObservableObject {
    enum State: Equatable {
        case requestingPermission
        case ready
        case denied
        case unavailable
        case failed
    }

    @Published private(set) var state: State = .requestingPermission
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var zoomOptions: [CGFloat] = [0.5, 1, 2, 5]
    @Published private(set) var canFlipCamera = false
    @Published private(set) var isFlippingCamera = false
    @Published private(set) var flipCardAngle: Double = 0
    @Published private(set) var incomingPreviewSnapshotView: UIView?
    @Published private(set) var outgoingPreviewSnapshotView: UIView?
    @Published private(set) var livePreviewOpacity: Double = 1

    private let sessionController = CameraSessionController()
    private weak var previewView: CameraPreviewUIView?

    var session: AVCaptureSession {
        sessionController.session
    }

    func prepare() async {
        let accessGranted = await requestCameraAccessIfNeeded()
        guard accessGranted else {
            state = .denied
            return
        }

        do {
            try await sessionController.configureIfNeeded()
            try await sessionController.startSession()
            await refreshCameraControls()
            state = .ready
        } catch {
            state = .failed
        }
    }

    fileprivate func capturePhoto() async throws -> CapturedPhoto {
        guard state == .ready else {
            throw PhotoPostFlowError.cameraUnavailable
        }

        return try await sessionController.capturePhoto()
    }

    fileprivate func setPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        sessionController.setPreviewLayer(previewLayer)
    }

    fileprivate func setPreviewView(_ previewView: CameraPreviewUIView) {
        self.previewView = previewView
    }

    func selectZoomFactor(_ zoomFactor: CGFloat) {
        sessionController.setZoomFactor(zoomFactor) { [weak self] displayZoomFactor in
            DispatchQueue.main.async {
                self?.zoomFactor = self?.nearestZoomOption(to: displayZoomFactor) ?? displayZoomFactor
            }
        }
    }

    func beginInteractiveZoom() {
        sessionController.beginInteractiveZoom()
    }

    func updateInteractiveZoom(with magnification: CGFloat) {
        sessionController.updateInteractiveZoom(with: magnification) { [weak self] displayZoomFactor in
            DispatchQueue.main.async {
                self?.zoomFactor = self?.nearestZoomOption(to: displayZoomFactor) ?? displayZoomFactor
            }
        }
    }

    func endInteractiveZoom() {
        sessionController.endInteractiveZoom()
    }

    func flipCamera() {
        guard !isFlippingCamera else { return }

        Task {
            isFlippingCamera = true
            outgoingPreviewSnapshotView = capturePreviewSnapshotView(afterScreenUpdates: true)
            incomingPreviewSnapshotView = nil
            flipCardAngle = 0
            livePreviewOpacity = 1

            do {
                try await sessionController.flipCamera()
                await refreshCameraControls()
                try? await Task.sleep(for: .milliseconds(90))
                incomingPreviewSnapshotView = capturePreviewSnapshotView(afterScreenUpdates: true)

                let animationDuration = 0.48
                if outgoingPreviewSnapshotView != nil, incomingPreviewSnapshotView != nil {
                    livePreviewOpacity = 0
                    withAnimation(.easeInOut(duration: animationDuration)) {
                        flipCardAngle = 180
                    }
                    try? await Task.sleep(for: .milliseconds(480))
                }
            } catch {
                state = .failed
            }

            livePreviewOpacity = 1
            incomingPreviewSnapshotView = nil
            outgoingPreviewSnapshotView = nil
            flipCardAngle = 0
            isFlippingCamera = false
        }
    }

    func stop() {
        sessionController.stop()
    }

    func isSelectedZoom(_ zoomFactor: CGFloat) -> Bool {
        nearestZoomOption(to: self.zoomFactor) == zoomFactor
    }

    private func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func refreshCameraControls() async {
        let status = await sessionController.cameraControlStatus()
        zoomFactor = status.selectedDisplayZoomFactor
        zoomOptions = status.zoomOptions
        canFlipCamera = status.canFlipCamera
    }

    private func nearestZoomOption(to zoomFactor: CGFloat) -> CGFloat? {
        zoomOptions.min(by: { abs($0 - zoomFactor) < abs($1 - zoomFactor) })
    }

    private func capturePreviewSnapshotView(afterScreenUpdates: Bool) -> UIView? {
        guard let previewView else { return nil }
        previewView.layoutIfNeeded()
        return previewView.resizableSnapshotView(
            from: previewView.bounds,
            afterScreenUpdates: afterScreenUpdates,
            withCapInsets: .zero
        ) ?? previewView.snapshotView(afterScreenUpdates: afterScreenUpdates)
    }
}

private final class CaptureContinuationStore: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<CapturedPhoto, Error>?

    nonisolated func store(_ continuation: CheckedContinuation<CapturedPhoto, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    nonisolated func take() -> CheckedContinuation<CapturedPhoto, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

private final class CameraSessionController: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    struct ControlStatus: Sendable {
        let selectedDisplayZoomFactor: CGFloat
        let zoomOptions: [CGFloat]
        let canFlipCamera: Bool
    }

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "instablog.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private let captureContinuationStore = CaptureContinuationStore()
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var activeCameraPosition: AVCaptureDevice.Position = .back
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var interactiveZoomAnchor: CGFloat?
    private var selectedDisplayZoomFactor: CGFloat?

    func configureIfNeeded() async throws {
        if isConfigured { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(for: .back, reconfiguringExistingInput: false)
                    self.configureRotationCoordinatorIfPossible()
                    self.isConfigured = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func setPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async {
            self.previewLayer = previewLayer
            self.configureRotationCoordinatorIfPossible()
        }
    }

    func startSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                guard self.isConfigured else {
                    continuation.resume(throwing: PhotoPostFlowError.cameraUnavailable)
                    return
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    func capturePhoto() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .speed
                if let connection = self.photoOutput.connection(with: .video),
                   let rotationCoordinator = self.rotationCoordinator {
                    let angle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
                    connection.videoRotationAngle = angle
                }
                self.captureContinuationStore.store(continuation)
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func cameraControlStatus() async -> ControlStatus {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: self.makeControlStatus())
            }
        }
    }

    func setZoomFactor(_ zoomFactor: CGFloat, onChange: @escaping @Sendable (CGFloat) -> Void) {
        sessionQueue.async {
            self.selectedDisplayZoomFactor = zoomFactor
            let actualZoomFactor = self.applyZoomFactor(self.actualZoomFactor(forDisplayZoomFactor: zoomFactor))
            let displayZoomFactor = self.displayZoomFactor(forActualZoomFactor: actualZoomFactor)
            DispatchQueue.main.async {
                onChange(displayZoomFactor)
            }
        }
    }

    func beginInteractiveZoom() {
        sessionQueue.async {
            self.interactiveZoomAnchor = self.captureDevice?.videoZoomFactor ?? 1
        }
    }

    func updateInteractiveZoom(with magnification: CGFloat, onChange: @escaping @Sendable (CGFloat) -> Void) {
        sessionQueue.async {
            self.selectedDisplayZoomFactor = nil
            let anchor = self.interactiveZoomAnchor ?? (self.captureDevice?.videoZoomFactor ?? 1)
            let requestedZoomFactor = anchor * magnification
            let actualZoomFactor = self.applyZoomFactor(requestedZoomFactor)
            let displayZoomFactor = self.displayZoomFactor(forActualZoomFactor: actualZoomFactor)
            DispatchQueue.main.async {
                onChange(displayZoomFactor)
            }
        }
    }

    func endInteractiveZoom() {
        sessionQueue.async {
            self.interactiveZoomAnchor = nil
        }
    }

    func flipCamera() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let nextPosition: AVCaptureDevice.Position = self.activeCameraPosition == .back ? .front : .back
                    try self.configureSession(for: nextPosition, reconfiguringExistingInput: true)
                    self.configureRotationCoordinatorIfPossible(forceReset: true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSession(
        for position: AVCaptureDevice.Position,
        reconfiguringExistingInput: Bool
    ) throws {
        guard let camera = preferredCamera(for: position) else {
            throw PhotoPostFlowError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        if reconfiguringExistingInput {
            if let videoInput {
                session.removeInput(videoInput)
            }
        }

        guard session.canAddInput(input) else {
            throw PhotoPostFlowError.cameraUnavailable
        }
        session.addInput(input)
        videoInput = input
        captureDevice = camera
        activeCameraPosition = position

        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                throw PhotoPostFlowError.cameraUnavailable
            }
            session.addOutput(photoOutput)
        }

        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }
        if photoOutput.isFastCapturePrioritizationSupported {
            photoOutput.isFastCapturePrioritizationEnabled = true
        }

        selectedDisplayZoomFactor = 1
        _ = applyZoomFactor(actualZoomFactor(forDisplayZoomFactor: 1))
    }

    private func configureRotationCoordinatorIfPossible(forceReset: Bool = false) {
        if forceReset {
            previewRotationObservation = nil
            rotationCoordinator = nil
        }

        guard rotationCoordinator == nil,
              let captureDevice,
              let previewLayer else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: captureDevice,
            previewLayer: previewLayer
        )
        rotationCoordinator = coordinator
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak previewLayer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                previewLayer?.connection?.videoRotationAngle = angle
            }
        }
    }

    private func makeControlStatus() -> ControlStatus {
        let zoomOptions = availableDisplayZoomOptions(for: captureDevice)
        let canFlipCamera = preferredCamera(for: opposite(of: activeCameraPosition)) != nil
        return ControlStatus(
            selectedDisplayZoomFactor: nearestDisplayZoomFactor(to: displayZoomFactor(forActualZoomFactor: captureDevice?.videoZoomFactor ?? 1), in: zoomOptions),
            zoomOptions: zoomOptions,
            canFlipCamera: canFlipCamera
        )
    }

    private func availableDisplayZoomOptions(for device: AVCaptureDevice?) -> [CGFloat] {
        guard let device else { return [1] }

        let displayMultiplier = displayZoomFactorMultiplier(for: device)
        let minimumActualZoomFactor: CGFloat
        let maximumActualZoomFactor: CGFloat

        if #available(iOS 18.0, *),
           let zoomRange = device.activeFormat.systemRecommendedVideoZoomRange {
            minimumActualZoomFactor = zoomRange.lowerBound
            maximumActualZoomFactor = min(zoomRange.upperBound, device.maxAvailableVideoZoomFactor)
        } else {
            minimumActualZoomFactor = device.minAvailableVideoZoomFactor
            maximumActualZoomFactor = device.maxAvailableVideoZoomFactor
        }
        let desiredDisplayOptions: [CGFloat] = [0.5, 1, 2, 5]

        let filteredOptions = desiredDisplayOptions.filter { displayZoomFactor in
            let actualZoomFactor = displayZoomFactor / displayMultiplier
            return actualZoomFactor >= minimumActualZoomFactor - 0.01
                && actualZoomFactor <= maximumActualZoomFactor + 0.01
        }

        return filteredOptions.isEmpty ? [nearestDisplayZoomFactor(to: displayZoomFactor(forActualZoomFactor: 1), in: desiredDisplayOptions)] : filteredOptions
    }

    private func displayZoomFactorMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            return max(device.displayVideoZoomFactorMultiplier, 0.01)
        } else {
            return 1
        }
    }

    private func actualZoomFactor(forDisplayZoomFactor displayZoomFactor: CGFloat) -> CGFloat {
        guard let captureDevice else { return displayZoomFactor }
        return displayZoomFactor / displayZoomFactorMultiplier(for: captureDevice)
    }

    private func displayZoomFactor(forActualZoomFactor actualZoomFactor: CGFloat) -> CGFloat {
        guard let captureDevice else { return actualZoomFactor }
        return actualZoomFactor * displayZoomFactorMultiplier(for: captureDevice)
    }

    private func nearestDisplayZoomFactor(to displayZoomFactor: CGFloat, in options: [CGFloat]) -> CGFloat {
        if let selectedDisplayZoomFactor {
            return selectedDisplayZoomFactor
        }

        return options.min(by: { abs($0 - displayZoomFactor) < abs($1 - displayZoomFactor) }) ?? displayZoomFactor
    }

    private func applyZoomFactor(_ requestedZoomFactor: CGFloat) -> CGFloat {
        guard let captureDevice else { return 1 }

        let minimumZoomFactor = max(
            captureDevice.minAvailableVideoZoomFactor,
            actualZoomFactor(forDisplayZoomFactor: 0.5)
        )
        let maximumZoomFactor = min(
            max(captureDevice.maxAvailableVideoZoomFactor, minimumZoomFactor),
            actualZoomFactor(forDisplayZoomFactor: 5)
        )
        let clampedZoomFactor = min(max(requestedZoomFactor, minimumZoomFactor), maximumZoomFactor)

        do {
            try captureDevice.lockForConfiguration()
            captureDevice.videoZoomFactor = clampedZoomFactor
            captureDevice.unlockForConfiguration()
        } catch {
            return captureDevice.videoZoomFactor
        }

        return captureDevice.videoZoomFactor
    }

    private func preferredCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let orderedDeviceTypes: [AVCaptureDevice.DeviceType]
        switch position {
        case .back:
            orderedDeviceTypes = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera
            ]
        case .front:
            orderedDeviceTypes = [
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ]
        default:
            orderedDeviceTypes = [.builtInWideAngleCamera]
        }

        for deviceType in orderedDeviceTypes {
            if let device = AVCaptureDevice.default(deviceType, for: .video, position: position) {
                return device
            }
        }

        return nil
    }

    private func opposite(of position: AVCaptureDevice.Position) -> AVCaptureDevice.Position {
        position == .back ? .front : .back
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            captureContinuationStore.take()?.resume(throwing: error)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            captureContinuationStore.take()?.resume(throwing: PhotoPostFlowError.invalidCapture)
            return
        }

        let mimeType = photo.resolvedSettings.photoDimensions.width > 0 ? "image/jpeg" : "image/jpeg"
        captureContinuationStore.take()?.resume(
            returning: CapturedPhoto(
                data: data,
                mimeType: mimeType,
                pixelWidth: Int(photo.resolvedSettings.photoDimensions.width),
                pixelHeight: Int(photo.resolvedSettings.photoDimensions.height)
            )
        )
    }
}

private struct PhotoPostDraft {
    let source: PhotoPostSource
    let previewImage: UIImage?
    let imageData: Data
    let mimeType: String
    let createdAt: Date
    let timeZoneIdentifier: String?
    let coordinate: CLLocationCoordinate2D?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

private enum PhotoPostSource {
    case camera
    case library
}

private struct CapturedPhoto {
    let data: Data
    let mimeType: String
    let pixelWidth: Int?
    let pixelHeight: Int?
}

private enum PhotoPostFlowError: Error {
    case cameraUnavailable
    case invalidCapture
    case invalidLibrarySelection
}
