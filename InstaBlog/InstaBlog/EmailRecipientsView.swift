import Observation
import SwiftUI

@MainActor
@Observable
final class EmailRecipientsModel {
    private(set) var recipients: [Subscriber] = []
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?
    private(set) var contactGroups: [ContactGroup] = []
    private(set) var isLoadingGroups = false
    private(set) var allContacts: [ContactEntry] = []
    private(set) var isLoadingContacts = false
    private(set) var importOutcome: ContactRecipientImportOutcome?

    @ObservationIgnored private let store: EmailRecipientStore
    @ObservationIgnored private let contactsProvider: any ContactsGroupProviding

    init(
        store: EmailRecipientStore,
        contactsProvider: any ContactsGroupProviding = LiveContactsGroupProvider()
    ) {
        self.store = store
        self.contactsProvider = contactsProvider
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            recipients = try await JournalMutationRunner.run {
                try self.store.loadRecipients()
            }
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = "The recipient list could not be loaded."
            AppTelemetry.log(
                "Failed to load email recipients",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    func addRecipient(emailAddress: String, displayName: String?) async throws {
        _ = try await JournalMutationRunner.run {
            try self.store.addRecipient(emailAddress: emailAddress, displayName: displayName)
        }
        await load()
    }

    func updateRecipient(id: Subscriber.ID, emailAddress: String, displayName: String?) async throws {
        try await JournalMutationRunner.run {
            try self.store.updateRecipient(id: id, emailAddress: emailAddress, displayName: displayName)
        }
        await load()
    }

    func deleteRecipient(id: Subscriber.ID) async {
        do {
            try await JournalMutationRunner.run {
                try self.store.deleteRecipient(id: id)
            }
            await load()
        } catch {
            loadErrorMessage = "The recipient could not be removed."
            AppTelemetry.log(
                "Failed to delete email recipient",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    func requestContactsAccessIfNeeded() async -> ContactsAuthorizationStatus {
        var status = await contactsProvider.authorizationStatus
        if status == .notDetermined {
            status = await contactsProvider.requestAccess()
        }
        return status
    }

    func loadContactGroups() async {
        isLoadingGroups = true
        defer { isLoadingGroups = false }
        do {
            contactGroups = try await JournalMutationRunner.run {
                try self.contactsProvider.loadGroups()
            }
        } catch {
            importOutcome = ContactRecipientImportOutcome.error("Your contact groups could not be loaded.")
            AppTelemetry.log(
                "Failed to load contact groups",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    func loadAllContacts() async {
        isLoadingContacts = true
        defer { isLoadingContacts = false }
        do {
            allContacts = try await JournalMutationRunner.run {
                try self.contactsProvider.loadAllContacts()
            }
        } catch {
            importOutcome = ContactRecipientImportOutcome.error("Your contacts could not be loaded.")
            AppTelemetry.log(
                "Failed to load contacts",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    func importRecipients(from group: ContactGroup) async {
        do {
            let candidates = try await JournalMutationRunner.run {
                try self.contactsProvider.recipients(inGroup: group.identifier)
            }
            let summary = try await JournalMutationRunner.run {
                try self.store.importRecipients(candidates)
            }
            importOutcome = ContactRecipientImportOutcome.summary(summary)
            await load()
        } catch {
            importOutcome = ContactRecipientImportOutcome.error("The selected group could not be imported.")
            AppTelemetry.log(
                "Failed to import email recipients from Contacts",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    func importRecipients(from entries: [ContactEntry]) async {
        do {
            let candidates = self.contactsProvider.recipients(from: entries)
            let summary = try await JournalMutationRunner.run {
                try self.store.importRecipients(candidates)
            }
            importOutcome = ContactRecipientImportOutcome.summary(summary)
            await load()
        } catch {
            importOutcome = ContactRecipientImportOutcome.error("The selected contacts could not be imported.")
            AppTelemetry.log(
                "Failed to import email recipients from Contacts",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    func clearImportOutcome() {
        importOutcome = nil
    }
}

nonisolated struct ContactRecipientImportOutcome: Identifiable, Equatable {
    enum Kind: Equatable {
        case summary(ContactRecipientImportSummary)
        case error(String)
    }

    let id = UUID()
    let kind: Kind

    static func summary(_ summary: ContactRecipientImportSummary) -> ContactRecipientImportOutcome {
        ContactRecipientImportOutcome(kind: .summary(summary))
    }

    static func error(_ message: String) -> ContactRecipientImportOutcome {
        ContactRecipientImportOutcome(kind: .error(message))
    }
}

private struct RecipientSection: Identifiable {
    let letter: String
    let recipients: [Subscriber]

    var id: String { letter }
}

private struct RecipientListView: View {
    let model: EmailRecipientsModel
    @Binding var editingRecipient: Subscriber?

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(header: Text(section.letter)) {
                    ForEach(section.recipients) { recipient in
                        RecipientRow(
                            recipient: recipient,
                            onSelect: { editingRecipient = recipient },
                            onDelete: { Task { await model.deleteRecipient(id: recipient.id) } }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var sections: [RecipientSection] {
        let grouped = Dictionary(grouping: model.recipients) {
            RecipientDisplay.sortKey($0).prefix(1).uppercased()
        }
        return grouped.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { RecipientSection(letter: $0, recipients: grouped[$0] ?? []) }
    }
}

struct EmailRecipientsView: View {
    @State private var model: EmailRecipientsModel
    @State private var editingRecipient: Subscriber?
    @State private var isCreatingRecipient = false
    @State private var isShowingContactPicker = false
    @State private var isPreparingImport = false
    @State private var activeAlert: RecipientsAlert?

    init(
        store: EmailRecipientStore,
        contactsProvider: any ContactsGroupProviding = LiveContactsGroupProvider()
    ) {
        _model = State(initialValue: EmailRecipientsModel(
            store: store,
            contactsProvider: contactsProvider
        ))
    }

    var body: some View {
        Group {
            if let loadErrorMessage = model.loadErrorMessage {
                ContentUnavailableView(
                    "Could Not Load Recipients",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadErrorMessage)
                )
            } else if model.recipients.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("No Recipients", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add the email addresses you want to receive shared journal posts.")
                } actions: {
                    Button("Add Recipient") {
                        isCreatingRecipient = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("Add first recipient")
                }
            } else {
                RecipientListView(
                    model: model,
                    editingRecipient: $editingRecipient
                )
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Recipients")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isPreparingImport {
                    ProgressView()
                } else {
                    Button {
                        isCreatingRecipient = true
                    } label: {
                        Label("Add recipient", systemImage: "plus")
                    }
                    .accessibilityIdentifier("Add recipient")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: beginContactsImport) {
                    Label("Import from contacts", systemImage: "person.crop.circle.badge.plus")
                }
                .accessibilityIdentifier("Import from contacts")
            }
        }
        .task { await model.load() }
        .onChange(of: model.importOutcome) { _, outcome in
            if let outcome {
                activeAlert = RecipientsAlert(kind: .importOutcome(outcome))
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert.kind {
            case .importOutcome:
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK")) {
                        model.clearImportOutcome()
                    }
                )
            case .contactsDenied:
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Open Settings"), action: openSettings),
                    secondaryButton: .cancel(Text("Cancel"))
                )
            }
        }
        .sheet(item: $editingRecipient) { recipient in
            EmailRecipientEditor(
                mode: .edit,
                recipient: recipient,
                onSave: { email, name in
                    try await model.updateRecipient(
                        id: recipient.id,
                        emailAddress: email,
                        displayName: name
                    )
                }
            )
        }
        .sheet(isPresented: $isCreatingRecipient) {
            EmailRecipientEditor(
                mode: .create,
                recipient: nil,
                onSave: { email, name in
                    try await model.addRecipient(emailAddress: email, displayName: name)
                }
            )
        }
        .sheet(isPresented: $isShowingContactPicker) {
            ContactSourcePickerView(
                model: model,
                groups: model.contactGroups,
                onImport: { entries in
                    isShowingContactPicker = false
                    Task { await model.importRecipients(from: entries) }
                },
                onSelectGroup: { group in
                    isShowingContactPicker = false
                    Task { await model.importRecipients(from: group) }
                },
                onCancel: {
                    isShowingContactPicker = false
                }
            )
        }
    }

    private func beginContactsImport() {
        Task {
            isPreparingImport = true
            defer { isPreparingImport = false }
            let status = await model.requestContactsAccessIfNeeded()
            switch status {
            case .authorized:
                await model.loadContactGroups()
                isShowingContactPicker = true
            case .notDetermined:
                break
            case .denied, .restricted:
                activeAlert = RecipientsAlert(kind: .contactsDenied)
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private enum RecipientDisplay {
    static func sortKey(_ recipient: Subscriber) -> String {
        let name = recipient.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : recipient.emailAddress
    }

    static func initials(for recipient: Subscriber) -> String {
        let key = sortKey(recipient)
        let words = key.split(separator: " ").filter { !$0.isEmpty }
        let first = words.first?.prefix(1) ?? key.prefix(1)
        let second = words.dropFirst().first?.prefix(1) ?? ""
        return "\(first)\(second)".uppercased()
    }

    static let avatarColors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown,
    ]

    static func avatarColor(for recipient: Subscriber) -> Color {
        let key = recipient.displayName ?? recipient.emailAddress
        let hash = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let index = Int(UInt(hash.magnitude) % UInt(avatarColors.count))
        return avatarColors[index]
    }
}

private struct RecipientRow: View {
    let recipient: Subscriber
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(RecipientDisplay.avatarColor(for: recipient))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(RecipientDisplay.initials(for: recipient))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(RecipientDisplay.sortKey(recipient))
                    .font(.body)
                    .foregroundStyle(.primary)
                if recipient.displayName != nil {
                    Text(recipient.emailAddress)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct RecipientsAlert: Identifiable {
    enum Kind {
        case importOutcome(ContactRecipientImportOutcome)
        case contactsDenied
    }

    let id = UUID()
    let kind: Kind

    var title: String {
        switch kind {
        case .importOutcome: "Imported from Contacts"
        case .contactsDenied: "Contacts Access Needed"
        }
    }

    var message: String {
        switch kind {
        case .importOutcome(let outcome):
            switch outcome.kind {
            case .summary(let summary):
                var parts = [
                    "Added \(summary.added) recipient\(summary.added == 1 ? "" : "s") to your list."
                ]
                if summary.skipped > 0 {
                    parts.append("Skipped \(summary.skipped) already in your list or without an email.")
                }
                return parts.joined(separator: " ")
            case .error(let message):
                return message
            }
        case .contactsDenied:
            return "Allow InstaBlog to access Contacts in Settings, then try importing again."
        }
    }
}

private struct ContactSourcePickerView: View {
    let model: EmailRecipientsModel
    let groups: [ContactGroup]
    let onImport: ([ContactEntry]) -> Void
    let onSelectGroup: (ContactGroup) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AllContactsPickerView(model: model, onImport: onImport)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.fill")
                                .font(.body)
                                .foregroundStyle(AppColors.controlTint)
                                .frame(width: 32)
                            Text("All Contacts")
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }

                if groups.isEmpty {
                    Section {
                        Text("You can also create groups in the Contacts app to import a curated list.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Groups") {
                        ForEach(groups) { group in
                            Button {
                                onSelectGroup(group)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.3.fill")
                                        .font(.body)
                                        .foregroundStyle(AppColors.controlTint)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name)
                                            .foregroundStyle(.primary)
                                        Text("\(group.contactCount) contact\(group.contactCount == 1 ? "" : "s")")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Import From Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

private struct AllContactsPickerView: View {
    let model: EmailRecipientsModel
    let onImport: ([ContactEntry]) -> Void

    @State private var selection = Set<String>()
    @State private var searchText = ""

    var body: some View {
        Group {
            if model.isLoadingContacts {
                ProgressView("Loading contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.allContacts.isEmpty {
                ContentUnavailableView(
                    "No Contacts",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("No contacts with email addresses were found.")
                )
            } else {
                List {
                    ForEach(filteredContacts) { contact in
                        Button {
                            toggleSelection(contact.id)
                        } label: {
                            HStack(spacing: 12) {
                                ContactSelectionRow(contact: contact)
                                Spacer()
                                Image(systemName: isSelected(contact.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(
                                        isSelected(contact.id) ? AppColors.controlTint : Color.secondary
                                    )
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(contact.displayName ?? contact.preferredEmail ?? "Unnamed contact")"
                        )
                        .accessibilityAddTraits(isSelected(contact.id) ? .isSelected : [])
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search contacts"
                )
            }
        }
        .navigationTitle("All Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    importSelection()
                } label: {
                    Text(selection.isEmpty ? "Import" : "Import (\(selection.count))")
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("Import selected contacts")
            }
        }
        .task { await model.loadAllContacts() }
    }

    private var filteredContacts: [ContactEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.allContacts }
        return model.allContacts.filter { entry in
            (entry.displayName?.lowercased().contains(query) ?? false)
                || entry.emails.contains { $0.address.lowercased().contains(query) }
        }
    }

    private func isSelected(_ id: String) -> Bool {
        selection.contains(id)
    }

    private func toggleSelection(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func importSelection() {
        let selected = model.allContacts.filter { selection.contains($0.id) }
        onImport(selected)
    }
}

private struct ContactSelectionRow: View {
    let contact: ContactEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(contact.displayName ?? contact.preferredEmail ?? "Unnamed contact")
                .foregroundStyle(.primary)
            if let email = contact.preferredEmail {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EmailRecipientEditor: View {
    enum Mode {
        case create
        case edit
    }

    let mode: Mode
    let recipient: Subscriber?
    let onSave: (String, String?) async throws -> Void

    @State private var emailAddress: String
    @State private var displayName: String
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @FocusState private var focusedField: Field?

    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case email
        case displayName
    }

    init(
        mode: Mode,
        recipient: Subscriber?,
        onSave: @escaping (String, String?) async throws -> Void
    ) {
        self.mode = mode
        self.recipient = recipient
        self.onSave = onSave
        _emailAddress = State(initialValue: recipient?.emailAddress ?? "")
        _displayName = State(initialValue: recipient?.displayName ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorHeader

                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Email address")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField(
                                focusedField == .email ? "" : "name@example.com",
                                text: $emailAddress
                            )
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .focused($focusedField, equals: .email)
                                .onSubmit { focusedField = nil }
                                .accessibilityLabel("Email address")
                                .accessibilityIdentifier("Recipient email")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Display name (optional)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                TextField("Jane", text: $displayName)
                                    .textInputAutocapitalization(.words)
                                    .submitLabel(.done)
                                    .focused($focusedField, equals: .displayName)
                                    .onSubmit { focusedField = nil }
                                    .accessibilityLabel("Display name")
                                    .accessibilityIdentifier("Recipient display name")
                                JournalClearTextButton(
                                    accessibilityLabel: "Clear recipient display name",
                                    isVisible: focusedField == .displayName && !displayName.isEmpty
                                ) {
                                    displayName = ""
                                }
                            }
                        }
                    } footer: {
                        if let saveErrorMessage {
                            Label(
                                saveErrorMessage,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppColors.alertRed)
                        }
                    }
                }
                .environment(\.defaultMinListRowHeight, 44)
                .listSectionSpacing(.compact)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .interactiveDismissDisabled(isSaving || hasChanges)
    }

    private var editorHeader: some View {
        HStack {
            Button(action: { dismiss() }) {
                Text("Cancel")
                    .font(.headline)
                    .frame(minWidth: 84, minHeight: 44)
            }
            .buttonStyle(.glass)

            Spacer()

            Text(mode == .create ? "New Recipient" : "Edit Recipient")
                .font(.title3.weight(.semibold))

            Spacer()

            Button {
                Task { await save() }
            } label: {
                Text(mode == .create ? "Add" : "Save")
                    .font(.headline)
                    .foregroundStyle(AppColors.controlTint)
                    .frame(minWidth: 84, minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var trimmedEmail: String {
        emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedEmail.isEmpty && !isSaving
    }

    private var hasChanges: Bool {
        trimmedEmail != (recipient?.emailAddress ?? "")
            || trimmedName != (recipient?.displayName ?? "")
    }

    private func save() async {
        saveErrorMessage = nil
        guard !trimmedEmail.isEmpty else {
            saveErrorMessage = "Enter an email address."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(trimmedEmail, trimmedName.isEmpty ? nil : trimmedName)
            dismiss()
        } catch {
            saveErrorMessage = Self.message(for: error)
        }
    }

    private nonisolated static func message(for error: any Error) -> String {
        if let validation = error as? ModelValidationError {
            switch validation {
            case .emptySubscriberEmail:
                return "Enter an email address."
            case .duplicateSubscriberEmail:
                return "This email is already in your recipient list."
            default:
                return validation.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
