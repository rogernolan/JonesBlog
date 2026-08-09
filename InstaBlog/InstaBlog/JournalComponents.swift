import SwiftUI
import UIKit
import ImageIO

struct SyncStatusIndicator: View {
    let status: BlogItemSyncStatus

    var body: some View {
        switch status {
        case .storedLocally:
            Label("Stored locally", systemImage: "dot.circle.fill").foregroundStyle(.red)
        case .synced:
            Label("Uploaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .pending:
            Label("Uploading", systemImage: "arrow.up.circle.fill").foregroundStyle(.orange)
        case .failed:
            Label("Upload failed", systemImage: "exclamationmark.icloud.fill").foregroundStyle(.red)
        }
    }
}

struct PhotoAvailabilityIndicator: View {
    let item: BlogItemDisplay

    var body: some View {
        if item.photos.contains(where: { $0.availability == .unavailable }) {
            Label("Photo unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if item.photos.contains(where: { $0.availability == .downloading }) {
            Label("Downloading photo", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
        } else {
            SyncStatusIndicator(status: item.syncStatus)
        }
    }
}

private struct PhotoSyncStatusIndicator: View {
    let photo: PhotoItemDisplay
    let syncStatus: BlogItemSyncStatus

    var body: some View {
        if photo.availability == .unavailable {
            Label("Photo unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if photo.availability == .downloading {
            Label("Downloading photo", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
        } else {
            SyncStatusIndicator(status: syncStatus)
        }
    }
}

struct JournalPhotoPlaceholder: View {
    let palette: JournalPalette

    var body: some View {
        ZStack {
            palette.gradient
            Image(systemName: palette.symbol)
                .font(.system(.largeTitle, design: .rounded, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityHidden(true)
        }
        .accessibilityLabel(palette.accessibilityLabel)
    }
}

struct MissingPhotoPlaceholder: View {
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "photo.badge.arrow.down")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Photo downloading")
    }
}

struct BrokenPhotoPlaceholder: View {
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(.red)
        }
        .accessibilityLabel("Photo unavailable")
    }
}

struct JournalPhotoSurface: View {
    nonisolated enum Scaling: Equatable {
        case fill
        case fit
    }

    let photo: PhotoItemDisplay
    let scaling: Scaling
    let maxPixelSize: Int
    @State private var image: UIImage?

    init(photo: PhotoItemDisplay, scaling: Scaling = .fit, maxPixelSize: Int = 1_600) {
        self.photo = photo
        self.scaling = scaling
        self.maxPixelSize = maxPixelSize
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .modifier(PhotoScalingModifier(scaling: scaling))
                    .accessibilityLabel(photo.caption.isEmpty ? "Photo attached to post" : photo.caption)
            } else if photo.availability == .downloading {
                MissingPhotoPlaceholder()
            } else if photo.availability == .unavailable {
                BrokenPhotoPlaceholder()
            } else if let palette = photo.palette {
                JournalPhotoPlaceholder(palette: palette)
            } else {
                MissingPhotoPlaceholder()
            }
        }
        .task(id: "\(photo.id.uuidString)#\(photo.localImagePath ?? String())#\(maxPixelSize)") {
            image = await JournalPhotoImageLoader.load(
                path: photo.localImagePath,
                cacheKey: photo.id.uuidString,
                maxPixelSize: maxPixelSize
            )
        }
    }
}

private struct PhotoScalingModifier: ViewModifier {
    let scaling: JournalPhotoSurface.Scaling

    func body(content: Content) -> some View {
        switch scaling {
        case .fill:
            content.scaledToFill().frame(maxWidth: .infinity)
        case .fit:
            content.scaledToFit().frame(maxWidth: .infinity)
        }
    }
}

private struct BlogItemPhotoStrip: View {
    private let photoSpacing: CGFloat = 10
    private let photoPeekWidth: CGFloat = 40
    /// Roughly twice the single-photo scale so the filmstrip reads as a full-size
    /// preview on iPad, where the strip height is cap-limited. On iPhone the strip
    /// stays width-limited, so this cap is not reached and the strip is unchanged.
    private let maximumPhotoStripHeight: CGFloat = 520

    let photos: [PhotoItemDisplay]
    let syncStatus: BlogItemSyncStatus

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        if photos.count == 1, let photo = photos.first {
            let layout = FilmstripPhotoLayout(photo: photo)
            singlePhotoView(photo, layout: layout)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: photoSpacing) {
                    ForEach(photos) { photo in
                        let layout = FilmstripPhotoLayout(photo: photo)
                        photoView(photo, layout: layout)
                            .frame(width: layout.clampedAspectRatio * photoStripHeight)
                            .frame(height: photoStripHeight)
                            .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
            .scrollIndicators(.hidden)
            .frame(height: photoStripHeight)
            .overlay {
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Photo filmstrip")
                    .accessibilityIdentifier("Journal blog item photo strip")
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { newWidth in
                availableWidth = newWidth
            }
        }
    }

    private var photoStripHeight: CGFloat {
        FilmstripPhotoLayout.stripHeight(
            availableWidth: availableWidth,
            maximumHeight: maximumPhotoStripHeight,
            trailingPeekWidth: photoPeekWidth + photoSpacing
        )
    }

    private func photoView(_ photo: PhotoItemDisplay, layout: FilmstripPhotoLayout) -> some View {
        Color.clear
            .overlay {
                JournalPhotoSurface(photo: photo, scaling: .fill, maxPixelSize: 1_600)
            }
            .clipShape(.rect(cornerRadius: 22))
            .accessibilityIdentifier("Journal blog item photo")
            .overlay(alignment: .bottom) {
                photoOverlay(for: photo)
            }
    }

    private func singlePhotoView(
        _ photo: PhotoItemDisplay,
        layout: FilmstripPhotoLayout
    ) -> some View {
        JournalPhotoSurface(photo: photo, scaling: .fill, maxPixelSize: 1_600)
            .aspectRatio(layout.sourceAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 22))
            .accessibilityIdentifier("Journal blog item photo")
            .overlay(alignment: .bottom) {
                photoOverlay(for: photo)
            }
    }

    private func photoOverlay(for photo: PhotoItemDisplay) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            captionPill(for: photo)
            Spacer(minLength: 0)
            photoStatusPill(for: photo)
        }
        .padding(10)
    }

    @ViewBuilder
    private func captionPill(for photo: PhotoItemDisplay) -> some View {
        if !photo.caption.isEmpty {
            Text(photo.caption)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: .capsule)
        }
    }

    private func photoStatusPill(for photo: PhotoItemDisplay) -> some View {
        PhotoSyncStatusIndicator(photo: photo, syncStatus: syncStatus)
            .font(.caption2.weight(.semibold))
            .labelStyle(.iconOnly)
            .padding(8)
            .background(.regularMaterial, in: .circle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(photoStatusAccessibilityLabel(for: photo))
            .accessibilityIdentifier("Journal blog item upload status pill")
    }

    private func photoStatusAccessibilityLabel(for photo: PhotoItemDisplay) -> String {
        switch photo.availability {
        case .unavailable:
            "Photo unavailable"
        case .downloading:
            "Downloading photo"
        case .none, .available:
            syncStatus.accessibilityDescription
        }
    }
}

struct FilmstripPhotoLayout {
    static let portraitAspectRatio: CGFloat = 3 / 4
    static let landscapeAspectRatio: CGFloat = 4 / 3

    let sourceAspectRatio: CGFloat

    init(photo: PhotoItemDisplay) {
        guard let width = photo.pixelWidth,
              let height = photo.pixelHeight,
              width > 0,
              height > 0 else {
            sourceAspectRatio = Self.landscapeAspectRatio
            return
        }
        sourceAspectRatio = CGFloat(width) / CGFloat(height)
    }

    init(sourceAspectRatio: CGFloat) {
        self.sourceAspectRatio = sourceAspectRatio
    }

    var clampedAspectRatio: CGFloat {
        min(max(sourceAspectRatio, Self.portraitAspectRatio), Self.landscapeAspectRatio)
    }

    static func stripHeight(
        availableWidth: CGFloat,
        maximumHeight: CGFloat,
        trailingPeekWidth: CGFloat
    ) -> CGFloat {
        guard availableWidth > trailingPeekWidth else { return maximumHeight }
        let currentLandscapeHeight = (availableWidth - trailingPeekWidth) / landscapeAspectRatio
        return min(maximumHeight, currentLandscapeHeight)
    }

}

@MainActor
enum JournalPhotoImageLoader {
    /// Building a downsampled thumbnail requires decoding the full source image,
    /// which is tens to hundreds of megabytes for modern phone photos. Decoding
    /// every photo a scroll passes over at once can pin many concurrent full-size
    /// decodes in memory, so decode work is throttled to a small number at a time.
    nonisolated private static let maximumConcurrentDecodes = 2
    nonisolated private static let decodeLimiter = DispatchSemaphore(value: maximumConcurrentDecodes)

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    /// In-flight decodes shared between concurrent requesters for the same key,
    /// so the same photo is never decoded twice at once.
    private static var inflight: [String: Task<UIImage?, Never>] = [:]

    static func load(path: String?, cacheKey: String, maxPixelSize: Int) async -> UIImage? {
        guard let path else { return nil }
        let key = "\(cacheKey)#\(path)#\(maxPixelSize)" as NSString
        let keyString = key as String
        if let cached = cache.object(forKey: key) { return cached }
        if let running = inflight[keyString] { return await running.value }

        let task = Task { () -> UIImage? in
            let image = await Self.decode(path: path, maxPixelSize: maxPixelSize)
            if let image {
                let cost = image.cgImage.map { $0.width * $0.height * 4 } ?? 0
                cache.setObject(image, forKey: key, cost: cost)
            }
            return image
        }
        inflight[keyString] = task
        defer { inflight[keyString] = nil }
        return await task.value
    }

    private static func decode(path: String, maxPixelSize: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            Self.decodeThumbnail(path: path, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated private static func decodeThumbnail(path: String, maxPixelSize: Int) -> UIImage? {
        decodeLimiter.wait()
        defer { decodeLimiter.signal() }
#if DEBUG
        JournalPhotoDecodeMetrics.shared.beginDecode()
        defer { JournalPhotoDecodeMetrics.shared.endDecode() }
#endif
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return Optional<UIImage>.none
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }

    /// Releases all decoded images. Called on memory pressure so scrolling leaves
    /// the app with only the images currently on screen.
    static func clearCache() {
        cache.removeAllObjects()
    }
}

#if DEBUG
/// Test-only counters that let unit tests verify the loader bounds decode
/// concurrency, deduplicates in-flight work, and releases cached images.
nonisolated final class JournalPhotoDecodeMetrics: @unchecked Sendable {
    static let shared = JournalPhotoDecodeMetrics()

    private let lock = NSLock()
    private var activeDecodes = 0
    private var peakConcurrency = 0
    private var totalDecodes = 0

    var snapshot: (peakConcurrency: Int, totalDecodes: Int) {
        lock.withLock { (peakConcurrency, totalDecodes) }
    }

    func reset() {
        lock.withLock {
            activeDecodes = 0
            peakConcurrency = 0
            totalDecodes = 0
        }
    }

    fileprivate func beginDecode() {
        lock.withLock {
            activeDecodes += 1
            peakConcurrency = max(peakConcurrency, activeDecodes)
            totalDecodes += 1
        }
    }

    fileprivate func endDecode() {
        lock.withLock { activeDecodes -= 1 }
    }
}
#endif

struct BlogItemCard: View {
    let item: BlogItemDisplay
    var destination: (() -> AnyView)? = nil
    var onAdd: (() -> Void)? = nil
    var inlineEditingEnabled: Bool = false
    var onUpdate: ((BlogItemUpdateRequest) -> Void)? = nil
    var onUpdateText: ((BlogItem.ID, String) -> Void)? = nil
    var onDelete: ((BlogItemDisplay) -> Void)? = nil

    @State private var editedText: String = ""
    @State private var isEditingText = false
    @State private var editorHeight: CGFloat = InlineTextEditorMetrics.minHeight
    @FocusState private var isTextFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardLink
                .overlay(
                    alignment: Alignment(
                        horizontal: .trailing,
                        vertical: .blogItemMetadataCenter
                    )
                ) {
                    addButton
                }
                .overlay(
                    alignment: Alignment(
                        horizontal: .trailing,
                        vertical: .blogItemTextCenter
                    )
                ) {
                    if showsDetailDisclosure {
                        detailDisclosureLink
                    }
                }
            if !item.location.isEmpty {
                Label(item.location, systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(AppColors.locationGreen)
                    .accessibilityIdentifier("Journal blog item location")
            }
            if item.syncStatus == .failed {
                SyncStatusIndicator(status: item.syncStatus).font(.caption)
            }
        }
        .onChange(of: isTextFocused) { _, focused in
            if !focused && isEditingText {
                commitInlineEditing()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background && isEditingText {
                commitInlineEditing()
            }
        }
        .onDisappear {
            commitInlineEditing()
        }
        .onKeyPress(.escape) {
            guard isEditingText else { return .ignored }
            isTextFocused = false
            return .handled
        }
    }

    @ViewBuilder
    private var cardLink: some View {
        if isEditingText, inlineEditingEnabled {
            content
        } else if let destination {
            NavigationLink { destination() } label: { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Journal blog item card")
                .accessibilityLabel(accessibilitySummary)
                .accessibilityValue(photoSyncAccessibilityValue)
                .accessibilityHint("Opens BlogItem details")
        } else {
            NavigationLink(value: JournalDestination.blogItem(item)) { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Journal blog item card")
                .accessibilityLabel(accessibilitySummary)
                .accessibilityValue(photoSyncAccessibilityValue)
                .accessibilityHint("Opens BlogItem details")
        }
    }

    @ViewBuilder
    private var addButton: some View {
        if let onAdd {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.16), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .offset(x: 11)
            .accessibilityLabel("Add blog item")
        }
    }

    private var showsDetailDisclosure: Bool {
        inlineEditingEnabled && item.photos.isEmpty && !isEditingText
    }

    @ViewBuilder
    private var detailDisclosureLink: some View {
        if let destination {
            NavigationLink { destination() } label: { detailDisclosureLabel }
        } else {
            NavigationLink(value: JournalDestination.blogItem(item)) { detailDisclosureLabel }
        }
    }

    private var detailDisclosureLabel: some View {
        Image(systemName: "chevron.right")
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColors.controlTint.opacity(0.7))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .accessibilityLabel("View entry details")
            .accessibilityIdentifier("Journal blog item detail disclosure")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.photos.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    BlogItemPhotoStrip(photos: item.photos, syncStatus: item.syncStatus)
                    photoMetadataPill
                }
            } else {
                metadataPill.foregroundStyle(.secondary)
            }
            if isEditingText, inlineEditingEnabled {
                inlineTextEditor
            } else if !item.blogText.isEmpty {
                Text(PostTextLinkifier.attributedString(item.blogText))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.blogItemTextCenter) { dimensions in
                        dimensions[VerticalAlignment.center]
                    }
                    .padding(.trailing, showsDetailDisclosure ? 36 : 0)
                    .accessibilityIdentifier("Journal blog item text")
                    .modifier(
                        InlineTextEditTapModifier(enabled: inlineEditingEnabled) {
                            beginInlineEditing()
                        }
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var inlineTextEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $editedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isTextFocused)
                .onAppear { isTextFocused = true }
                .accessibilityLabel("Edit blog item text")
                .accessibilityIdentifier("Journal blog item text editor")
                .frame(height: editorHeight)

            editorMeasureText
        }
        .onPreferenceChange(InlineTextEditorHeightPreference.self) { measured in
            editorHeight = min(
                max(
                    measured + InlineTextEditorMetrics.verticalTextInset,
                    InlineTextEditorMetrics.minHeight
                ),
                InlineTextEditorMetrics.maxHeight
            )
        }
        .background(alignment: .topLeading) {
            if editedText.isEmpty {
                Text("Write an entry…")
                    .font(.body)
                    .foregroundStyle(.placeholder)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .padding(6)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppColors.controlTint, lineWidth: 1)
        }
    }

    private var editorMeasureText: some View {
        Text(editedText.isEmpty ? " " : editedText)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, InlineTextEditorMetrics.horizontalTextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: InlineTextEditorHeightPreference.self,
                        value: proxy.size.height
                    )
                }
            }
    }

    private func beginInlineEditing() {
        guard inlineEditingEnabled else { return }
        editedText = item.blogText
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingText = true
        }
    }

    private func commitInlineEditing() {
        guard isEditingText else { return }
        switch InlineTextEditor.commitOutcome(
            originalText: item.blogText,
            editedText: editedText,
            hasPhotos: !item.photos.isEmpty
        ) {
        case .noChange:
            isTextFocused = false
            isEditingText = false
        case .updated:
            onUpdateText?(item.id, editedText)
            isTextFocused = false
            isEditingText = false
        case .delete:
            isEditingText = false
            editedText = item.blogText
            isTextFocused = false
            onDelete?(item)
        }
    }

    private var metadataPill: some View {
        metadataPillContent
            .background(.regularMaterial.opacity(0.75), in: .rect(cornerRadius: 12))
            .modifier(MetadataPillAccessibility(label: metadataAccessibilityLabel))
            .alignmentGuide(.blogItemMetadataCenter) { dimensions in
                dimensions[VerticalAlignment.center]
            }
    }

    private var photoMetadataPill: some View {
        metadataPillContent
            .background(Color.gray.opacity(0.28), in: .rect(cornerRadius: 12))
            .modifier(MetadataPillAccessibility(label: metadataAccessibilityLabel))
            .alignmentGuide(.blogItemMetadataCenter) { dimensions in
                dimensions[VerticalAlignment.center]
            }
    }

    private var metadataPillContent: some View {
        HStack(spacing: 6) {
            Text(item.author)
            Text("·")
            Text(item.metadataDateTimeText())
            if let temperature = item.weather.temperatureCelsius {
                Text("·")
                Text("\(temperature.formatted(.number))°")
            }
            if let symbol = item.weather.systemImage {
                Text("·")
                Image(systemName: symbol)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var metadataAccessibilityLabel: String {
        var components = [item.author, item.metadataDateTimeText()]
        if let temperature = item.weather.temperatureCelsius {
            components.append("\(temperature.formatted(.number)) degrees")
        }
        if let condition = item.weather.condition {
            components.append(condition)
        }
        return components.joined(separator: ", ")
    }

    private var accessibilitySummary: String {
        var weatherComponents: [String] = []
        if let temperature = item.weather.temperatureCelsius {
            weatherComponents.append("\(temperature) degrees")
        }
        if let condition = item.weather.condition {
            weatherComponents.append(condition)
        }
        let weatherSummary = weatherComponents.isEmpty
            ? ""
            : ", \(weatherComponents.joined(separator: ", "))"
        return "BlogItem by \(item.author), \(item.metadataDateTimeText()), \(item.blogText), \(item.location)\(weatherSummary)"
    }

    private var photoSyncAccessibilityValue: String {
        guard !item.photos.isEmpty else { return "" }
        if item.photos.contains(where: { $0.availability == .unavailable }) {
            return "Photo sync status: Unavailable"
        }
        if item.photos.contains(where: { $0.availability == .downloading }) {
            return "Photo sync status: Downloading"
        }
        return "Photo sync status: \(item.syncStatus.accessibilityDescription)"
    }

}

private struct InlineTextEditTapModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.highPriorityGesture(
                TapGesture().onEnded { action() }
            )
        } else {
            content
        }
    }
}

private enum InlineTextEditorMetrics {
    static let minHeight: CGFloat = 30
    static let maxHeight: CGFloat = 252
    static let horizontalTextInset: CGFloat = 5
    static let verticalTextInset: CGFloat = 10
}

private struct InlineTextEditorHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension VerticalAlignment {
    struct BlogItemMetadataCenter: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    static let blogItemMetadataCenter = VerticalAlignment(BlogItemMetadataCenter.self)

    struct BlogItemTextCenter: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    static let blogItemTextCenter = VerticalAlignment(BlogItemTextCenter.self)
}

private struct MetadataPillAccessibility: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("Journal blog item metadata pill")
    }
}

struct DayPostSection: View {
    let dayPost: DayPostDisplay
    let dayNumber: Int
    let totalDays: Int
    var showsNewestFirst: Bool = true
    var showsActions: Bool = true
    var blogItemDestination: ((BlogItemDisplay) -> AnyView)? = nil
    var onAddBlogItem: ((BlogItemDisplay) -> Void)? = nil
    var inlineEditingEnabled: Bool = false
    var onUpdate: ((BlogItemUpdateRequest) -> Void)? = nil
    var onUpdateText: ((BlogItem.ID, String) -> Void)? = nil
    var onDelete: ((BlogItemDisplay) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            dayHeader
            ForEach(displayedItems) { item in
                if let blogItemDestination {
                    BlogItemCard(
                        item: item,
                        destination: { blogItemDestination(item) },
                        onAdd: onAddBlogItem.map { add in { add(item) } },
                        inlineEditingEnabled: inlineEditingEnabled,
                        onUpdate: onUpdate,
                        onUpdateText: onUpdateText,
                        onDelete: onDelete
                    )
                } else {
                    BlogItemCard(
                        item: item,
                        onAdd: onAddBlogItem.map { add in { add(item) } },
                        inlineEditingEnabled: inlineEditingEnabled,
                        onUpdate: onUpdate,
                        onUpdateText: onUpdateText,
                        onDelete: onDelete
                    )
                }
            }
        }
    }

    private var displayedItems: [BlogItemDisplay] {
        showsNewestFirst ? Array(dayPost.blogItems.reversed()) : dayPost.blogItems
    }

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayPost.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(AppTypography.listTitle)
            Text("DAY \(dayNumber) OF \(totalDays)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(dayPost.routeBreadcrumb)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.locationGreen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private extension JournalPalette {
    var gradient: LinearGradient {
        switch self {
        case .saltMarsh:
            LinearGradient(colors: [.teal.opacity(0.75), .yellow.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .harbour:
            LinearGradient(colors: [.cyan.opacity(0.75), .orange.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .lunch:
            LinearGradient(colors: [.orange.opacity(0.72), .yellow.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .flamingos:
            LinearGradient(colors: [.pink.opacity(0.7), .indigo.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .train:
            LinearGradient(colors: [.indigo.opacity(0.7), .green.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var symbol: String {
        switch self {
        case .saltMarsh: "water.waves"
        case .harbour: "sailboat.fill"
        case .lunch: "fork.knife"
        case .flamingos: "bird.fill"
        case .train: "tram.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .saltMarsh: "Placeholder image of salt marshes"
        case .harbour: "Placeholder image of the harbour"
        case .lunch: "Placeholder image of lunch"
        case .flamingos: "Placeholder image of flamingos"
        case .train: "Placeholder image of the train journey"
        }
    }
}
