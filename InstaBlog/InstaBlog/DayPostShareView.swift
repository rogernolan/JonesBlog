import MessageUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private enum DayPostShareRangeMode: String, CaseIterable, Identifiable {
    case yesterday = "Yesterday"
    case today = "Today"
    case dateRange = "Date range"

    var id: Self { self }
}

struct DayPostShareView: View {
    let trips: [TripDisplay]
    var recipientStore: EmailRecipientStore? = nil
    var embedsNavigationStack = true
    var onOpenSidebar: (() -> Void)?

    @State private var rangeMode: DayPostShareRangeMode = .today
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    @State private var isUpdatingPreset = false
    @State private var draft: DayPostEmailDraft?
    @State private var draftBccRecipients: [String] = []
    @State private var draftBccLoadFailed = false
    @State private var isGenerating = false
    @State private var activeDatePicker: ShareDatePickerField?
    @State private var recipientCount = 0

    var body: some View {
        if embedsNavigationStack {
            NavigationStack {
                VStack(spacing: 0) {
                    Text("Share")
                        .font(AppTypography.screenTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    content
                }
                    .background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle("Share")
                    .toolbar(.hidden, for: .navigationBar)
            }
        } else {
            content
        }
    }

    private var content: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    JournalDetailRowIcon(systemName: "calendar.badge.clock")
                    Picker("Date range", selection: $rangeMode) {
                        ForEach(DayPostShareRangeMode.allCases) { mode in
                            Text(mode.rawValue)
                                .font(.system(size: 23))
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text(
                    "Select dates to generate a mail or HTML text from. "
                        + "All posts between these dates will be used regardless of the Trip."
                )
                .textCase(nil)
            }

            Section {
                dateButton(
                    title: "Start date",
                    systemImage: "backward.end.fill",
                    date: startDate,
                    field: .start
                )
                dateButton(
                    title: "End date",
                    systemImage: "forward.end.fill",
                    date: endDate,
                    field: .end
                )
            } header: {
                Text("Dates")
            } footer: {
                if isRangeInvalid {
                    Label(
                        "End date must be on or after start date",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppColors.alertRed)
                }
            }

            Section {
                Button {
                    generatePost()
                } label: {
                    HStack(spacing: 12) {
                        JournalDetailRowIcon(systemName: "envelope")
                        Text(isGenerating ? "Generating post" : "Generate post")
                            .foregroundStyle(AppColors.controlTint)
                        Spacer()
                        Text(entryCountLabel)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        if isGenerating {
                            ProgressView()
                        }
                        Image(systemName: "chevron.right")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isRangeInvalid || isGenerating || selectedEntryCount == 0)
                .opacity(isRangeInvalid || isGenerating || selectedEntryCount == 0 ? 0.45 : 1)
                .accessibilityIdentifier("Generate shared post")
            }

            if let store = recipientStore {
                Section {
                    NavigationLink {
                        EmailRecipientsView(store: store)
                    } label: {
                        HStack(spacing: 12) {
                            JournalDetailRowIcon(systemName: "person.crop.circle.badge.plus")
                            Text("Email recipients")
                                .foregroundStyle(AppColors.controlTint)
                            Spacer()
                            Text(recipientCountLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Recipients")
                } footer: {
                    Text("These addresses are added to the BCC field when you email a shared post.")
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 44)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.visible)
        .onAppear {
            applyPreset(rangeMode)
        }
        .task {
            await loadRecipientCount()
        }
        .onChange(of: rangeMode) { _, mode in
            applyPreset(mode)
        }
        .sheet(isPresented: draftPresentation) {
            if let draft {
                DayPostEmailPreviewView(
                    draft: draft,
                    recipientStore: recipientStore,
                    initialBccRecipients: draftBccRecipients,
                    initialBccLoadFailed: draftBccLoadFailed
                )
            }
        }
    }

    private var recipientCountLabel: String {
        "\(recipientCount) recipient\(recipientCount == 1 ? "" : "s")"
    }

    private func loadRecipientCount() async {
        guard let recipientStore else { return }
        do {
            recipientCount = try await JournalMutationRunner.run {
                try recipientStore.loadRecipients().count
            }
        } catch {
            recipientCount = 0
            AppTelemetry.log(
                "Failed to load recipient count for sharing",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    private func dateButton(
        title: String,
        systemImage: String,
        date: Date,
        field: ShareDatePickerField
    ) -> some View {
        Button {
            activeDatePicker = field
        } label: {
            HStack(spacing: 12) {
                JournalDetailRowIcon(systemName: systemImage)
                Text(title)
                    .foregroundStyle(AppColors.controlTint)
                Spacer(minLength: 12)
                Text(Self.dateButtonFormatter.string(from: date))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { activeDatePicker == field },
                set: { isPresented in
                    if !isPresented, activeDatePicker == field {
                        activeDatePicker = nil
                    }
                }
            )
        ) {
            ShareCalendarPopover(
                title: title,
                selection: dateBinding(for: field)
            )
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("\(title), \(Self.dateButtonFormatter.string(from: date))")
    }

    private func dateBinding(for field: ShareDatePickerField) -> Binding<Date> {
        Binding(
            get: {
                switch field {
                case .start: startDate
                case .end: endDate
                }
            },
            set: { newValue in
                selectDate(newValue, for: field)
            }
        )
    }

    private var isRangeInvalid: Bool {
        endDate < startDate
    }

    private var selectedEntryCount: Int {
        DayPostShareDayCollector.entryCount(
            from: trips,
            startDate: startDate,
            endDate: endDate
        )
    }

    private var entryCountLabel: String {
        "\(selectedEntryCount) \(selectedEntryCount == 1 ? "entry" : "entries")"
    }

    private var draftPresentation: Binding<Bool> {
        Binding(
            get: { draft != nil },
            set: { isPresented in
                if !isPresented {
                    draft = nil
                }
            }
        )
    }

    private func applyPreset(_ mode: DayPostShareRangeMode) {
        guard mode != .dateRange else { return }

        isUpdatingPreset = true
        defer { isUpdatingPreset = false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch mode {
        case .today:
            startDate = today
            endDate = today
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            startDate = yesterday
            endDate = yesterday
        case .dateRange:
            break
        }
    }

    private func generatePost() {
        guard !isRangeInvalid, !isGenerating else { return }

        let selectedTrips = trips
        let selectedStartDate = startDate
        let selectedEndDate = endDate
        isGenerating = true

        Task {
            let generatedDraft = await Task.detached(priority: .userInitiated) {
                let days = DayPostShareDayCollector.days(
                    from: selectedTrips,
                    startDate: selectedStartDate,
                    endDate: selectedEndDate
                )
                return DayPostEmailGenerator().generate(days: days, trips: selectedTrips)
            }.value

            let bcc = await loadRecipientsForSharing()
            isGenerating = false
            draftBccRecipients = bcc.addresses
            draftBccLoadFailed = bcc.failed
            draft = generatedDraft
        }
    }

    private func loadRecipientsForSharing() async -> (addresses: [String], failed: Bool) {
        guard let recipientStore else { return ([], false) }
        do {
            let addresses = try await JournalMutationRunner.run {
                try recipientStore.loadRecipientEmailAddresses()
            }
            return (addresses, false)
        } catch {
            AppTelemetry.log(
                "Failed to load email recipients for sharing",
                category: "share.recipients",
                level: .error,
                error: error
            )
            return ([], true)
        }
    }

    private func selectDate(_ newValue: Date, for field: ShareDatePickerField) {
        let selectedDate = Calendar.current.startOfDay(for: newValue)
        switch field {
        case .start:
            startDate = selectedDate
        case .end:
            endDate = selectedDate
        }
        if !isUpdatingPreset {
            rangeMode = .dateRange
        }
        activeDatePicker = nil
    }

    private static let dateButtonFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return formatter
    }()
}

private enum ShareDatePickerField {
    case start
    case end
}

private struct ShareCalendarPopover: View {
    let title: String
    @Binding var selection: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 14)

            DatePicker(
                title,
                selection: $selection,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()
        }
        .frame(minWidth: 320)
    }
}

private struct DayPostEmailPreviewView: View {
    let draft: DayPostEmailDraft
    let recipientStore: EmailRecipientStore?
    @Environment(\.dismiss) private var dismiss
    @State private var bccRecipients: [String]
    @State private var bccLoadFailed: Bool
    @State private var isShowingMailComposer = false
    @State private var isShowingMailUnavailableAlert = false

    init(
        draft: DayPostEmailDraft,
        recipientStore: EmailRecipientStore?,
        initialBccRecipients: [String],
        initialBccLoadFailed: Bool
    ) {
        self.draft = draft
        self.recipientStore = recipientStore
        _bccRecipients = State(initialValue: initialBccRecipients)
        _bccLoadFailed = State(initialValue: initialBccLoadFailed)
    }

    var body: some View {
        NavigationStack {
            DayPostHTMLPreview(html: draft.previewHTML)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .foregroundStyle(AppColors.controlTint)
                        }
                    }

                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text("Preview")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(bccSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .offset(x: 8)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Copy", action: copyPost)
                            .foregroundStyle(AppColors.controlTint)
                    }

                    ToolbarSpacer(.fixed, placement: .topBarTrailing)

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task {
                                await presentMailComposerIfPossible()
                            }
                        } label: {
                            Text("Email")
                                .foregroundStyle(AppColors.controlTint)
                        }
                    }
                }
        }
        .sheet(isPresented: $isShowingMailComposer) {
            DayPostMailComposer(draft: draft, bccRecipients: bccRecipients)
        }
        .alert("Email is unavailable", isPresented: $isShowingMailUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up Mail on this device to send the generated journal post.")
        }
    }

    private var bccSummary: String {
        if bccLoadFailed {
            return "Couldn't load recipients"
        }
        if bccRecipients.isEmpty {
            return recipientStore == nil ? "No recipient list" : "No recipients"
        }
        return "\(bccRecipients.count) recipient\(bccRecipients.count == 1 ? "" : "s") (BCC)"
    }

    private func presentMailComposerIfPossible() async {
        await loadBccRecipients()
        if MFMailComposeViewController.canSendMail() {
            isShowingMailComposer = true
        } else {
            isShowingMailUnavailableAlert = true
        }
    }

    private func loadBccRecipients() async {
        guard let recipientStore else { return }
        do {
            bccRecipients = try await JournalMutationRunner.run {
                try recipientStore.loadRecipientEmailAddresses()
            }
            bccLoadFailed = false
        } catch {
            bccLoadFailed = true
            bccRecipients = []
            AppTelemetry.log(
                "Failed to load email recipients for sharing",
                category: "share.recipients",
                level: .error,
                error: error
            )
        }
    }

    private func copyPost() {
        guard let htmlData = draft.previewHTML.data(using: .utf8) else { return }

        let plainText = (try? NSAttributedString(
            data: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ).string) ?? draft.previewHTML

        UIPasteboard.general.setItems([[
            UTType.html.identifier: htmlData,
            UTType.utf8PlainText.identifier: plainText
        ]])
    }
}

private struct DayPostMailComposer: UIViewControllerRepresentable {
    let draft: DayPostEmailDraft
    let bccRecipients: [String]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setSubject(draft.subject)
        // Mail Compose does not expose a way to assign Content-IDs to
        // addAttachmentData attachments. Use the resized JPEG data URLs
        // already generated for the preview so images render inline.
        composer.setMessageBody(draft.previewHTML, isHTML: true)
        if !bccRecipients.isEmpty {
            composer.setBccRecipients(bccRecipients)
        }

        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }
}

private struct DayPostHTMLPreview: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/"))
        context.coordinator.lastHTML = html
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastHTML: String?
    }
}
