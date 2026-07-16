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

struct SettingsView: View {
    let blog: Blog
    let sharingService: (any BlogSharingServiceProtocol)?
    let journalService: JournalService?
    private let embedsNavigationStack: Bool
    private let onEditingDisplayNameChange: (Bool) -> Void

    @FocusState private var isEditingDisplayName: Bool
    @State private var shareState: BlogShareState = .notShared
    @State private var isLoadingShare = false
    @State private var sharedRecord: SharedRecord?
    @State private var didStopSharing = false
    @State private var alert: SettingsAlert?
    @State private var identity: SettingsIdentityModel

    init(
        blog: Blog,
        blogger: Blogger,
        sharingService: (any BlogSharingServiceProtocol)?,
        journalService: JournalService? = nil,
        embedsNavigationStack: Bool = true,
        onEditingDisplayNameChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.blog = blog
        self.sharingService = sharingService
        self.journalService = journalService
        self.embedsNavigationStack = embedsNavigationStack
        self.onEditingDisplayNameChange = onEditingDisplayNameChange
        _identity = State(
            initialValue: SettingsIdentityModel(displayName: blogger.displayName) { name in
                guard let sharingService else { return }
                try await sharingService.updateDisplayName(name, bloggerID: blogger.id)
            }
        )
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack {
                    settingsContent
                }
            } else {
                settingsContent
            }
        }
    }

    private var settingsContent: some View {
        Form {
                Section("Sharing") {
                    Text(presentation.status)
                        .foregroundStyle(.secondary)

                    Button(action: sharingAction) {
                        HStack {
                            Text(presentation.actionTitle)
                                .foregroundStyle(AppColors.controlOrange)
                            Spacer()
                            if presentation.showsDisclosureIndicator {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(AppColors.controlOrange.opacity(0.7))
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
                    if let journalService {
                        NavigationLink {
                            DeletedEntriesView(journalService: journalService)
                        } label: {
                            Label("Deleted entries", systemImage: "trash")
                        }
                    }
                }

            }
            .navigationTitle(embedsNavigationStack ? "Settings" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(embedsNavigationStack ? .automatic : .hidden, for: .navigationBar)
            .onChange(of: isEditingDisplayName) { _, isEditing in
                onEditingDisplayNameChange(isEditing)
            }
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

private struct DeletedEntriesView: View {
    let journalService: JournalService

    @State private var items: [BlogItemDisplay] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if items.isEmpty, errorMessage == nil {
                ContentUnavailableView(
                    "No Deleted Entries",
                    systemImage: "trash",
                    description: Text("Deleted posts will appear here until you recover or permanently delete them.")
                )
            } else {
                List(items) { item in
                    NavigationLink {
                        DeletedBlogItemDetailView(item: item, journalService: journalService) {
                            reload()
                        }
                    } label: {
                        DeletedEntryRow(item: item)
                    }
                }
            }
        }
        .navigationTitle("Deleted entries")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .alert("Could Not Load Deleted Entries", isPresented: errorIsPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func reload() {
        do {
            items = try journalService.loadDeletedBlogItems()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DeletedEntryRow: View {
    let item: BlogItemDisplay

    var body: some View {
        HStack(spacing: 12) {
            if let path = item.photos.first?.localImagePath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.blogText.isEmpty ? "Photo post" : item.blogText)
                    .lineLimit(2)
                Text(item.date, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeletedBlogItemDetailView: View {
    let item: BlogItemDisplay
    let journalService: JournalService
    let didChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Button("Recover", action: recover)
                        .buttonStyle(.borderedProminent)
                    Button("Delete forever", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(item.photos) { photo in
                    VStack(alignment: .leading, spacing: 6) {
                        JournalPhotoSurface(photo: photo)
                        if !photo.caption.isEmpty {
                            Text(photo.caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !item.blogText.isEmpty {
                    Text(item.blogText)
                }
                Text(item.date, format: .dateTime.weekday().day().month().year().hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !item.location.isEmpty {
                    Label(item.location, systemImage: "location")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Deleted entry")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete this entry forever?", isPresented: $showsDeleteConfirmation) {
            Button("Delete forever", role: .destructive, action: deleteForever)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This entry and its photos cannot be recovered.")
        }
        .alert("Could Not Update Entry", isPresented: errorIsPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func recover() {
        perform { try journalService.recoverBlogItem(id: item.id) }
    }

    private func deleteForever() {
        perform { try journalService.permanentlyDeleteBlogItem(id: item.id) }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            didChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        VStack(alignment: .leading, spacing: 2) {
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
                    .font(.body.weight(.semibold))
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
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
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

    func restoreAcceptedSharedBlogIfNeeded() async {}

    func synchronizeCloudState() async {}

    func recoverSharedJournalRelationships() async {}

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
