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
        sharingService: (any BlogSharingServiceProtocol)?
    ) {
        self.blog = blog
        self.sharingService = sharingService
        _identity = State(
            initialValue: SettingsIdentityModel(displayName: blogger.displayName) { name in
                guard let sharingService else { return }
                try await sharingService.updateDisplayName(name, bloggerID: blogger.id)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Blog Sharing") {
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

                Section("Your Identity") {
                    EditableDisplayNameChip(
                        displayName: $identity.displayName,
                        isEditing: $isEditingDisplayName,
                        isSaving: identity.isSaving
                    ) {
                        saveDisplayName()
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

private struct EditableDisplayNameChipLayout: Equatable {
    let showsConfirmationButton: Bool

    init(isEditing: Bool) {
        showsConfirmationButton = isEditing
    }
}

private struct EditableDisplayNameChip: View {
    @Binding var displayName: String
    let isEditing: FocusState<Bool>.Binding
    let isSaving: Bool
    let save: () -> Void

    @State private var showsConfirmationButton = false

    private var buttonAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.52)
    }

    private var layout: EditableDisplayNameChipLayout {
        EditableDisplayNameChipLayout(isEditing: showsConfirmationButton)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Display name")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .trailing) {
                TextField("Display name", text: $displayName)
                    .focused(isEditing)
                    .textContentType(.name)
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
                .accessibilityLabel("Edit display name")

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
