import CloudKit
import Observation
import SQLiteData
import SwiftUI

nonisolated struct SettingsSharingPresentation: Equatable {
    let status: String
    let actionTitle: String
    let showsDisclosureIndicator: Bool
    let isActionEnabled: Bool
    let alertMessage: String?

    init(state: BlogShareState, isLoading: Bool) {
        switch state {
        case .notShared:
            status = "This Blog is private."
            actionTitle = "Share Blog"
            showsDisclosureIndicator = false
            alertMessage = nil
        case .sharedOwner:
            status = "You own this shared Blog."
            actionTitle = "Manage Sharing"
            showsDisclosureIndicator = true
            alertMessage = nil
        case .sharedParticipant:
            status = "You participate in this shared Blog."
            actionTitle = "Manage Sharing"
            showsDisclosureIndicator = true
            alertMessage = nil
        case let .unavailable(message):
            status = "Blog sharing is unavailable."
            actionTitle = "Sharing Unavailable"
            showsDisclosureIndicator = false
            alertMessage = message
        case let .error(message):
            status = "Blog sharing could not be loaded."
            actionTitle = "Try Again"
            showsDisclosureIndicator = false
            alertMessage = message
        }
        isActionEnabled = !isLoading
    }
}

private struct UnplacedItemsView: View {
    let journalService: JournalService

    @State private var items: [BlogItem] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Unplaced Items",
                    systemImage: "checkmark.circle",
                    description: Text("All saved entries are placed in the Journal.")
                )
            } else {
                List {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.caption?.isEmpty == false ? item.caption! : "Untitled entry")
                                .lineLimit(2)
                            Text(item.itemDate, format: .dateTime.day().month().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Restore to Journal") {
                                    restore(item)
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button("Delete Entry", role: .destructive) {
                                    delete(item)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Unplaced Items")
        .task { reload() }
        .alert("Recovery failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        do {
            items = try journalService.loadUnplacedBlogItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ item: BlogItem) {
        do {
            try journalService.restoreUnplacedBlogItem(item.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: BlogItem) {
        do {
            try journalService.deleteBlogItem(id: item.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class SettingsIdentityModel {
    var displayName: String
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let persist: (String) async throws -> Void

    init(
        displayName: String,
        persist: @escaping (String) async throws -> Void
    ) {
        self.displayName = displayName
        self.persist = persist
    }

    func save() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Display name cannot be empty."
            return
        }
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await persist(trimmedName)
            displayName = trimmedName
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class SettingsGalleryModel {
    var intervalMinutes: String
    var distanceMeters: String
    private(set) var isSavingInterval = false
    private(set) var isSavingDistance = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let persistInterval: (Int) async throws -> Void
    @ObservationIgnored private let persistDistance: (Double) async throws -> Void

    init(
        intervalSeconds: Int,
        distanceMeters: Double,
        persistInterval: @escaping (Int) async throws -> Void,
        persistDistance: @escaping (Double) async throws -> Void
    ) {
        intervalMinutes = Self.displayString(for: Double(intervalSeconds) / 60)
        self.distanceMeters = Self.displayString(for: distanceMeters)
        self.persistInterval = persistInterval
        self.persistDistance = persistDistance
    }

    func saveInterval() async {
        guard !isSavingInterval else { return }
        guard let minutes = Self.positiveNumber(from: intervalMinutes) else {
            errorMessage = "Gallery time must be greater than zero."
            return
        }
        let seconds = Int((minutes * 60).rounded())
        guard seconds > 0 else {
            errorMessage = "Gallery time must be at least one second."
            return
        }
        isSavingInterval = true
        defer { isSavingInterval = false }
        do {
            try await persistInterval(seconds)
            intervalMinutes = Self.displayString(for: Double(seconds) / 60)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveDistance() async {
        guard !isSavingDistance else { return }
        guard let meters = Self.positiveNumber(from: distanceMeters) else {
            errorMessage = "Gallery distance must be greater than zero."
            return
        }
        isSavingDistance = true
        defer { isSavingDistance = false }
        do {
            try await persistDistance(meters)
            distanceMeters = Self.displayString(for: meters)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func positiveNumber(from text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: "")
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }

    private nonisolated static func displayString(for value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct SettingsView: View {
    let blog: Blog
    let sharingService: (any BlogSharingServiceProtocol)?
    let journalService: JournalService?
    let onGallerySettingsChanged: () -> Void

    @FocusState private var isEditingDisplayName: Bool
    @FocusState private var isEditingGalleryDistance: Bool
    @FocusState private var isEditingGalleryInterval: Bool
    @State private var shareState: BlogShareState = .notShared
    @State private var isLoadingShare = false
    @State private var sharedRecord: SharedRecord?
    @State private var didStopSharing = false
    @State private var alert: SettingsAlert?
    @State private var identity: SettingsIdentityModel
    @State private var gallery: SettingsGalleryModel

    init(
        blog: Blog,
        blogger: Blogger,
        sharingService: (any BlogSharingServiceProtocol)?,
        journalService: JournalService? = nil,
        onGallerySettingsChanged: @escaping () -> Void = {}
    ) {
        self.blog = blog
        self.sharingService = sharingService
        self.journalService = journalService
        self.onGallerySettingsChanged = onGallerySettingsChanged
        _identity = State(
            initialValue: SettingsIdentityModel(displayName: blogger.displayName) { name in
                guard let sharingService else { return }
                try await sharingService.updateDisplayName(name, bloggerID: blogger.id)
            }
        )
        _gallery = State(
            initialValue: SettingsGalleryModel(
                intervalSeconds: blog.galleryIntervalSeconds,
                distanceMeters: blog.galleryDistanceMeters,
                persistInterval: { seconds in
                    try journalService?.updateGalleryInterval(seconds: seconds)
                },
                persistDistance: { meters in
                    try journalService?.updateGalleryDistance(meters: meters)
                }
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sharing") {
                    Text(presentation.status)
                        .foregroundStyle(.secondary)

                    Button(action: sharingAction) {
                        HStack {
                            Text(presentation.actionTitle)
                            Spacer()
                            if presentation.showsDisclosureIndicator {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                        .disabled(!presentation.isActionEnabled || sharingService == nil)

                    if isLoadingShare {
                        ProgressView()
                    }
                }

                Section("You") {
                    EditableSettingsTextChip(
                        title: "Display name",
                        text: $identity.displayName,
                        isEditing: $isEditingDisplayName,
                        isSaving: identity.isSaving,
                        textContentType: .name
                    ) {
                        saveDisplayName()
                    }
                }

                Section {
                    EditableSettingsTextChip(
                        title: "Distance (metres)",
                        text: $gallery.distanceMeters,
                        isEditing: $isEditingGalleryDistance,
                        isSaving: gallery.isSavingDistance,
                        keyboardType: .decimalPad,
                        removesGroupingSeparatorWhenEditing: true
                    ) {
                        saveGalleryDistance()
                    }

                    EditableSettingsTextChip(
                        title: "Time (minutes)",
                        text: $gallery.intervalMinutes,
                        isEditing: $isEditingGalleryInterval,
                        isSaving: gallery.isSavingInterval,
                        keyboardType: .decimalPad,
                        removesGroupingSeparatorWhenEditing: true
                    ) {
                        saveGalleryInterval()
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gallery")
                        Text(
                            "New Journal entries within these limits may be placed into a concrete Gallery. Existing Galleries are never regrouped."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    }
                }

                if let journalService {
                    Section("Recovery") {
                        NavigationLink {
                            UnplacedItemsView(journalService: journalService)
                        } label: {
                            Label("Unplaced Items", systemImage: "tray.full")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await reloadShareState() }
            .sheet(item: $sharedRecord, onDismiss: {
                if didStopSharing {
                    didStopSharing = false
                    return
                }
                Task { await reloadShareState() }
            }) { sharedRecord in
                CloudSharingView(
                    sharedRecord: sharedRecord,
                    availablePermissions: BlogSharingService.availablePermissions,
                    didStopSharing: {
                        didStopSharing = true
                        shareState = .notShared
                    }
                )
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var presentation: SettingsSharingPresentation {
        SettingsSharingPresentation(state: shareState, isLoading: isLoadingShare)
    }

    private func saveDisplayName() {
        Task {
            await identity.save()
            if let message = identity.errorMessage {
                alert = SettingsAlert(
                    title: "Could Not Save Name",
                    message: message
                )
            } else {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.52)) {
                    isEditingDisplayName = false
                }
            }
        }
    }

    private func saveGalleryDistance() {
        Task {
            await gallery.saveDistance()
            finishGallerySave(focus: $isEditingGalleryDistance)
        }
    }

    private func saveGalleryInterval() {
        Task {
            await gallery.saveInterval()
            finishGallerySave(focus: $isEditingGalleryInterval)
        }
    }

    private func finishGallerySave(focus: FocusState<Bool>.Binding) {
        if let message = gallery.errorMessage {
            alert = SettingsAlert(title: "Could Not Save Gallery Setting", message: message)
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.52)) {
                focus.wrappedValue = false
            }
            onGallerySettingsChanged()
        }
    }

    private func sharingAction() {
        switch shareState {
        case .notShared, .sharedOwner, .sharedParticipant:
            Task { await prepareShare() }
        case .error:
            Task { await reloadShareState() }
        case .unavailable:
            if let message = presentation.alertMessage {
                alert = SettingsAlert(title: "Sharing Unavailable", message: message)
            }
        }
    }

    private func prepareShare() async {
        guard let sharingService, !isLoadingShare else { return }
        isLoadingShare = true
        defer { isLoadingShare = false }
        do {
            sharedRecord = try await sharingService.prepareShare(for: blog.id, title: blog.title)
        } catch {
            shareState = .error(message: error.localizedDescription)
            alert = SettingsAlert(title: "Could Not Share Blog", message: error.localizedDescription)
        }
    }

    private func reloadShareState() async {
        guard let sharingService, !isLoadingShare else { return }
        isLoadingShare = true
        shareState = await sharingService.shareState(for: blog.id)
        isLoadingShare = false
    }
}

private struct EditableSettingsTextChipLayout: Equatable {
    let showsConfirmationButton: Bool

    init(isEditing: Bool) {
        showsConfirmationButton = isEditing
    }
}

private struct EditableSettingsTextChip: View {
    let title: String
    @Binding var text: String
    let isEditing: FocusState<Bool>.Binding
    let isSaving: Bool
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var removesGroupingSeparatorWhenEditing = false
    let save: () -> Void

    @State private var showsConfirmationButton = false

    private var buttonAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.52)
    }

    private var layout: EditableSettingsTextChipLayout {
        EditableSettingsTextChipLayout(isEditing: showsConfirmationButton)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .trailing) {
                TextField(title, text: $text)
                    .focused(isEditing)
                    .keyboardType(keyboardType)
                    .textContentType(textContentType)
                    .submitLabel(.done)
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 34)
                    .allowsHitTesting(isEditing.wrappedValue)
                    .onSubmit(save)

                Button {
                    beginEditing()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!isEditing.wrappedValue)
                .accessibilityLabel("Edit \(title)")

                Button(action: save) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.20, green: 0.71, blue: 0.40),
                                            Color(red: 0.10, green: 0.48, blue: 0.24)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .opacity(layout.showsConfirmationButton ? 1 : 0)
                .scaleEffect(layout.showsConfirmationButton ? 1 : 0.25)
                .allowsHitTesting(layout.showsConfirmationButton && !isSaving)
                .accessibilityHidden(!layout.showsConfirmationButton)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: beginEditing)
        .animation(buttonAnimation, value: layout)
        .onChange(of: isEditing.wrappedValue) { _, isFocused in
            withAnimation(buttonAnimation) {
                showsConfirmationButton = isFocused
            }
        }
    }

    private func beginEditing() {
        if removesGroupingSeparatorWhenEditing,
           let groupingSeparator = Locale.current.groupingSeparator {
            text = text.replacingOccurrences(of: groupingSeparator, with: "")
        }
        withAnimation(buttonAnimation) {
            showsConfirmationButton = true
        }
        isEditing.wrappedValue = true
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#Preview {
    let now = Date.now
    let blogID = UUID()
    SettingsView(
        blog: Blog(id: blogID, title: "My Blog", createdAt: now, updatedAt: now),
        blogger: Blogger(id: UUID(), blogID: blogID, displayName: "Rog", createdAt: now, updatedAt: now),
        sharingService: nil
    )
}

#Preview("Shared owner") {
    let now = Date.now
    let blogID = UUID()
    SettingsView(
        blog: Blog(id: blogID, title: "Jones Blog", createdAt: now, updatedAt: now),
        blogger: Blogger(id: UUID(), blogID: blogID, displayName: "Rog", createdAt: now, updatedAt: now),
        sharingService: PreviewBlogSharingService(state: .sharedOwner)
    )
}

@MainActor
private final class PreviewBlogSharingService: BlogSharingServiceProtocol {
    let state: BlogShareState

    init(state: BlogShareState) {
        self.state = state
    }

    func shareState(for blogID: Blog.ID) async -> BlogShareState {
        state
    }

    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord {
        throw PreviewSharingError()
    }

    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool {
        false
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog {
        throw PreviewSharingError()
    }

    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws {}
}

private struct PreviewSharingError: Error {}
