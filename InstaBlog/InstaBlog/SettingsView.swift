import CloudKit
import Observation
import SQLiteData
import SwiftUI

nonisolated struct SettingsSharingPresentation: Equatable {
    let status: String
    let actionTitle: String
    let isActionEnabled: Bool
    let alertMessage: String?

    init(state: BlogShareState, isLoading: Bool) {
        switch state {
        case .notShared:
            status = "This Blog is private."
            actionTitle = "Share Blog"
            alertMessage = nil
        case .sharedOwner:
            status = "You own this shared Blog."
            actionTitle = "Manage Sharing"
            alertMessage = nil
        case .sharedParticipant:
            status = "You participate in this shared Blog."
            actionTitle = "Manage Sharing"
            alertMessage = nil
        case let .unavailable(message):
            status = "Blog sharing is unavailable."
            actionTitle = "Sharing Unavailable"
            alertMessage = message
        case let .error(message):
            status = "Blog sharing could not be loaded."
            actionTitle = "Try Again"
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

    @State private var shareState: BlogShareState = .notShared
    @State private var isLoadingShare = false
    @State private var sharedRecord: SharedRecord?
    @State private var isPresentingShare = false
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

                    Button(presentation.actionTitle, action: sharingAction)
                        .disabled(!presentation.isActionEnabled || sharingService == nil)

                    if isLoadingShare {
                        ProgressView()
                    }
                }

                Section("Your Identity") {
                    TextField("Display name", text: $identity.displayName)
                        .textContentType(.name)
                    Button("Save") {
                        Task {
                            await identity.save()
                            if let message = identity.errorMessage {
                                alert = SettingsAlert(
                                    title: "Could Not Save Name",
                                    message: message
                                )
                            }
                        }
                    }
                    .disabled(identity.isSaving)
                }
            }
            .navigationTitle("Settings")
            .task { await reloadShareState() }
            .sheet(isPresented: $isPresentingShare, onDismiss: {
                sharedRecord = nil
                Task { await reloadShareState() }
            }) {
                if let sharedRecord {
                    CloudSharingView(
                        sharedRecord: sharedRecord,
                        availablePermissions: BlogSharingService.availablePermissions
                    )
                }
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

    private func sharingAction() {
        switch shareState {
        case .notShared:
            Task { await prepareShare() }
        case .sharedOwner, .sharedParticipant:
            alert = SettingsAlert(
                title: "Manage Sharing",
                message: "Sharing management is coming later"
            )
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
            isPresentingShare = true
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
