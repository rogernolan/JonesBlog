import SwiftUI
import WebKit

private enum DayPostShareRangeMode: String, CaseIterable, Identifiable {
    case yesterday = "Yesterday"
    case today = "Today"
    case dateRange = "Date Range"

    var id: Self { self }
}

struct DayPostShareView: View {
    let trips: [TripDisplay]
    var embedsNavigationStack = true
    var onOpenSidebar: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
                content
                    .navigationTitle("Share")
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Picker("Date range", selection: $rangeMode) {
                        ForEach(DayPostShareRangeMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 480)

                    VStack(spacing: 14) {
                        Text("Choose Date Range")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)

                        dateControls
                    }
                    .frame(maxWidth: 680)

                    if isRangeInvalid {
                        Text("End date must be on or after start date")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppColors.alertRed)
                            .frame(maxWidth: 680, alignment: .leading)
                    }

                    Button {
                        generatePost()
                    } label: {
                        HStack(spacing: 10) {
                            if isGenerating {
                                ProgressView()
                            }
                            Text(isGenerating ? "Generating post" : "Generate post")
                        }
                        .font(.headline)
                        .frame(maxWidth: 320)
                        .padding(.vertical, 14)
                        .background(AppColors.controlOrange, in: .rect(cornerRadius: 16))
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRangeInvalid || isGenerating)
                    .opacity(isRangeInvalid || isGenerating ? 0.45 : 1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, onOpenSidebar == nil ? 28 : 18)
                .padding(.bottom, 40)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
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

    @ViewBuilder
    private var dateControls: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 18) {
                dateButton(title: "Start date", date: startDate, field: .start)
                dateButton(title: "End date", date: endDate, field: .end)
            }
        } else {
            VStack(spacing: 12) {
                dateButton(title: "Start date", date: startDate, field: .start)
                dateButton(title: "End date", date: endDate, field: .end)
            }
        }
    }

    private func dateButton(title: String, date: Date, field: ShareDatePickerField) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                activeDatePicker = field
            } label: {
                Text(Self.dateButtonFormatter.string(from: date))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppColors.controlOrange.opacity(0.32), in: .capsule)
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
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
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

    var body: some View {
        NavigationStack {
            DayPostHTMLPreview(html: draft.previewHTML)
                .navigationTitle("Email Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
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
