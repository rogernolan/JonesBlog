import AVFoundation
import Combine
import CoreLocation
import ImageIO
import OSLog
import PhotosUI
import SwiftUI
import UIKit

struct PhotoPostCaptureFlow: View {
    let journalService: JournalService?
    var destinationGalleryID: Gallery.ID? = nil
    var onAutomaticGalleryPlacement: (BlogItem.ID, Gallery.ID) -> Void = { _, _ in }
    let onSave: (TripDisplay) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraCaptureModel()
    @State private var selectedLibraryItem: PhotosPickerItem?
    @State private var draft: PhotoPostDraft?
    @State private var isShowingLibraryPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @StateObject private var captureProfiling = PhotoCaptureProfilingSession()

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
                    PhotoCaptureWorkspace(
                        camera: camera,
                        onChooseLibrary: { isShowingLibraryPicker = true },
                        onCapture: capturePhoto,
                        onCancel: { dismiss() }
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .photosPicker(
            isPresented: $isShowingLibraryPicker,
            selection: $selectedLibraryItem,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedLibraryItem) { _, newValue in
            guard let newValue else { return }
            loadLibraryPhoto(from: newValue)
        }
        .task {
            guard draft == nil else { return }
            if let seededDraft = Self.uiTestingSeededDraft() {
                draft = seededDraft
            } else {
                if let journalService, !Self.isRunningUITests {
                    Task {
                        await journalService.primeWeatherCapture()
                    }
                }
                await camera.prepare()
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

    private func loadLibraryPhoto(from item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PhotoPostFlowError.invalidLibrarySelection
                }
                let metadata = PhotoAssetMetadata.extract(from: data)
                let pixelSize = PhotoPreviewImageFactory.pixelSize(from: data)
                await MainActor.run {
                    draft = PhotoPostDraft(
                        source: .library,
                        previewImage: nil,
                        imageData: data,
                        mimeType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg",
                        createdAt: metadata.createdAt ?? Date.now,
                        timeZoneIdentifier: metadata.timeZoneIdentifier,
                        coordinate: metadata.coordinate,
                        pixelWidth: pixelSize.width,
                        pixelHeight: pixelSize.height
                    )
                }
                loadDraftPreviewImage(from: data)
            } catch {
                await MainActor.run {
                    errorMessage = "The selected photo could not be loaded."
                }
            }
        }
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

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            switch camera.state {
            case .ready:
                CameraPreviewView(
                    session: camera.session,
                    onPreviewLayerReady: camera.setPreviewLayer
                )
                    .ignoresSafeArea()
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

            controls
        }
        .navigationTitle("New Photo Post")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.white)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack {
                Button("Library", systemImage: "photo.on.rectangle", action: onChooseLibrary)
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.55))

                Spacer()

                if camera.state == .ready {
                    Button(action: onCapture) {
                        Circle()
                            .fill(.white)
                            .frame(width: 76, height: 76)
                            .overlay {
                                Circle()
                                    .stroke(.black.opacity(0.3), lineWidth: 2)
                                    .padding(6)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Take photo")
                }

                Spacer()

                Color.clear
                    .frame(width: 86, height: 44)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
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
            .navigationTitle("New BlogItem")
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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        onPreviewLayerReady(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        onPreviewLayerReady(uiView.previewLayer)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
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

    private let sessionController = CameraSessionController()

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

    func stop() {
        sessionController.stop()
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
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "instablog.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private let captureContinuationStore = CaptureContinuationStore()
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?

    func configureIfNeeded() async throws {
        if isConfigured { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        throw PhotoPostFlowError.cameraUnavailable
                    }
                    self.captureDevice = camera
                    let input = try AVCaptureDeviceInput(device: camera)

                    self.session.beginConfiguration()
                    self.session.sessionPreset = .high
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                    }
                    if self.session.canAddOutput(self.photoOutput) {
                        self.session.addOutput(self.photoOutput)
                    }
                    if self.photoOutput.isResponsiveCaptureSupported {
                        self.photoOutput.isResponsiveCaptureEnabled = true
                    }
                    if self.photoOutput.isFastCapturePrioritizationSupported {
                        self.photoOutput.isFastCapturePrioritizationEnabled = true
                    }
                    self.session.commitConfiguration()
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

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureRotationCoordinatorIfPossible() {
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
