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
    var embedsNavigationStack = true
    var onOpenSidebar: (() -> Void)?

    @State private var rangeMode: DayPostShareRangeMode = .today
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    @State private var isUpdatingPreset = false
    @State private var draft: DayPostEmailDraft?
    @State private var isGenerating = false
    @State private var activeDatePicker: ShareDatePickerField?

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
                            .foregroundStyle(AppColors.controlOrange)
                        Spacer()
                        if isGenerating {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRangeInvalid || isGenerating)
                .opacity(isRangeInvalid || isGenerating ? 0.45 : 1)
                .accessibilityIdentifier("Generate shared post")
            }
        }
        .environment(\.defaultMinListRowHeight, 44)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.visible)
        .onAppear {
            applyPreset(rangeMode)
        }
        .onChange(of: rangeMode) { _, mode in
            applyPreset(mode)
        }
        .sheet(isPresented: draftPresentation) {
            if let draft {
                DayPostEmailPreviewView(draft: draft)
            }
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
                    .foregroundStyle(.primary)
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
                return DayPostEmailGenerator().generate(days: days)
            }.value

            isGenerating = false
            draft = generatedDraft
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
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingMailComposer = false
    @State private var isShowingMailUnavailableAlert = false

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
                                .foregroundStyle(AppColors.controlOrange)
                        }
                    }

                    ToolbarItem(placement: .principal) {
                        Text("Preview")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .offset(x: 8)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Copy", action: copyPost)
                            .foregroundStyle(AppColors.controlOrange)
                    }

                    ToolbarSpacer(.fixed, placement: .topBarTrailing)

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if MFMailComposeViewController.canSendMail() {
                                isShowingMailComposer = true
                            } else {
                                isShowingMailUnavailableAlert = true
                            }
                        } label: {
                            Text("Email")
                                .foregroundStyle(AppColors.controlOrange)
                        }
                    }
                }
        }
        .sheet(isPresented: $isShowingMailComposer) {
            DayPostMailComposer(draft: draft)
        }
        .alert("Email is unavailable", isPresented: $isShowingMailUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set up Mail on this device to send the generated journal post.")
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
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setSubject("InstaBlog journal post")
        // Mail Compose does not expose a way to assign Content-IDs to
        // addAttachmentData attachments. Use the resized JPEG data URLs
        // already generated for the preview so images render inline.
        composer.setMessageBody(draft.previewHTML, isHTML: true)

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
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/"))
    }
}
