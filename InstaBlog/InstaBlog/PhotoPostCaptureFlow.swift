import AVFoundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

struct PhotoPostCaptureFlow: View {
    let journalService: JournalService?
    let onSave: (TripDisplay) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraCaptureModel()
    @State private var selectedLibraryItem: PhotosPickerItem?
    @State private var draft: PhotoPostDraft?
    @State private var isShowingLibraryPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    PhotoPostEditorView(
                        draft: draft,
                        isSaving: isSaving,
                        onCancel: { dismiss() },
                        onSave: savePhotoPost
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
            matching: .images
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
        Task {
            do {
                let capturedPhoto = try await camera.capturePhoto()
                draft = PhotoPostDraft(
                    previewImage: capturedPhoto.image,
                    imageData: capturedPhoto.data,
                    mimeType: capturedPhoto.mimeType,
                    createdAt: Date.now,
                    timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                    pixelWidth: Int(capturedPhoto.image.size.width),
                    pixelHeight: Int(capturedPhoto.image.size.height)
                )
            } catch {
                errorMessage = "The camera photo could not be captured. Please try again."
            }
        }
    }

    private func loadLibraryPhoto(from item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw PhotoPostFlowError.invalidLibrarySelection
                }
                await MainActor.run {
                    draft = PhotoPostDraft(
                        previewImage: image,
                        imageData: data,
                        mimeType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg",
                        createdAt: Date.now,
                        timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                        pixelWidth: Int(image.size.width),
                        pixelHeight: Int(image.size.height)
                    )
                }
            } catch {
                await MainActor.run {
                    errorMessage = "The selected photo could not be loaded."
                }
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
                    pixelHeight: pixelHeight
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
        pixelHeight: Int?
    ) async throws -> TripDisplay? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try journalService.createPhotoBlogItem(
                        caption: caption,
                        date: createdAt,
                        timeZoneIdentifier: timeZoneIdentifier,
                        imageData: imageData,
                        mimeType: mimeType,
                        pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight
                    )
                    let trip = try journalService.loadCurrentTrip()
                    continuation.resume(returning: trip)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
            previewImage: image,
            imageData: imageData,
            mimeType: "image/jpeg",
            createdAt: Date.now,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height)
        )
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
                CameraPreviewView(session: camera.session)
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

    @State private var caption: String

    init(
        draft: PhotoPostDraft,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.draft = draft
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        _caption = State(initialValue: ProcessInfo.processInfo.environment["UI_TEST_PHOTO_POST_CAPTION"] ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(uiImage: draft.previewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 24))

                Text("Add a caption now; location, weather, and other enrichment can be layered in later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $caption)
                    .font(.body)
                    .frame(minHeight: 150)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                    .accessibilityIdentifier("Photo post caption")
                    .disabled(isSaving)

                LabeledContent("Date", value: draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
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
                    // TODO: Attach weather and other automatic enrichment here once those services land.
                    onSave(caption)
                }
                .disabled(isSaving)
            }
        }
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

final class CameraCaptureModel: NSObject, ObservableObject {
    enum State: Equatable {
        case requestingPermission
        case ready
        case denied
        case unavailable
        case failed
    }

    @Published private(set) var state: State = .requestingPermission

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "instablog.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false
    private let captureContinuationLock = NSLock()
    private var captureContinuation: CheckedContinuation<CapturedPhoto, Error>?

    func prepare() async {
        let accessGranted = await requestCameraAccessIfNeeded()
        guard accessGranted else {
            publishState(.denied)
            return
        }

        do {
            try await configureIfNeeded()
            try await startSession()
            publishState(.ready)
        } catch {
            publishState(.failed)
        }
    }

    fileprivate func capturePhoto() async throws -> CapturedPhoto {
        guard state == .ready else {
            throw PhotoPostFlowError.cameraUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                self.storeCaptureContinuation(continuation)
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

    private func configureIfNeeded() async throws {
        if isConfigured { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                        throw PhotoPostFlowError.cameraUnavailable
                    }
                    let input = try AVCaptureDeviceInput(device: camera)

                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                    }
                    if self.session.canAddOutput(self.photoOutput) {
                        self.session.addOutput(self.photoOutput)
                    }
                    self.session.commitConfiguration()
                    self.isConfigured = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startSession() async throws {
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

    private func publishState(_ newState: State) {
        DispatchQueue.main.async {
            self.state = newState
        }
    }

    private func storeCaptureContinuation(
        _ continuation: CheckedContinuation<CapturedPhoto, Error>
    ) {
        captureContinuationLock.lock()
        captureContinuation = continuation
        captureContinuationLock.unlock()
    }

    nonisolated private func takeCaptureContinuation() -> CheckedContinuation<CapturedPhoto, Error>? {
        captureContinuationLock.lock()
        defer { captureContinuationLock.unlock() }
        let continuation = captureContinuation
        captureContinuation = nil
        return continuation
    }
}

extension CameraCaptureModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            takeCaptureContinuation()?.resume(throwing: error)
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            takeCaptureContinuation()?.resume(throwing: PhotoPostFlowError.invalidCapture)
            return
        }

        let mimeType = photo.resolvedSettings.photoDimensions.width > 0 ? "image/jpeg" : "image/jpeg"
        takeCaptureContinuation()?.resume(
            returning: CapturedPhoto(
                image: image,
                data: data,
                mimeType: mimeType
            )
        )
    }
}

private struct PhotoPostDraft {
    let previewImage: UIImage
    let imageData: Data
    let mimeType: String
    let createdAt: Date
    let timeZoneIdentifier: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

private struct CapturedPhoto {
    let image: UIImage
    let data: Data
    let mimeType: String
}

private enum PhotoPostFlowError: Error {
    case cameraUnavailable
    case invalidCapture
    case invalidLibrarySelection
}
