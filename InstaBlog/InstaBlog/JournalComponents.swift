import SwiftUI
import UIKit

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
    enum Scaling: Equatable {
        case fill
        case fit
    }

    let photo: PhotoItemDisplay
    let scaling: Scaling

    init(photo: PhotoItemDisplay, scaling: Scaling = .fit) {
        self.photo = photo
        self.scaling = scaling
    }

    var body: some View {
        Group {
            if let path = photo.localImagePath,
               let image = UIImage(contentsOfFile: path) {
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
    private let maximumPhotoStripHeight: CGFloat = 260

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
                JournalPhotoSurface(photo: photo, scaling: layout.scaling)
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
        JournalPhotoSurface(photo: photo, scaling: .fill)
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
        guard let path = photo.localImagePath,
              let image = UIImage(contentsOfFile: path) else {
            sourceAspectRatio = Self.landscapeAspectRatio
            return
        }
        sourceAspectRatio = Self.displayAspectRatio(for: image)
    }

    init(sourceAspectRatio: CGFloat) {
        self.sourceAspectRatio = sourceAspectRatio
    }

    var clampedAspectRatio: CGFloat {
        min(max(sourceAspectRatio, Self.portraitAspectRatio), Self.landscapeAspectRatio)
    }

    var scaling: JournalPhotoSurface.Scaling {
        sourceAspectRatio == clampedAspectRatio ? .fit : .fill
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

    private static func displayAspectRatio(for image: UIImage) -> CGFloat {
        let size = image.size
        let isSideways = switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
        let width = isSideways ? size.height : size.width
        let height = isSideways ? size.width : size.height
        guard width > 0, height > 0 else { return landscapeAspectRatio }
        return width / height
    }
}

struct BlogItemCard: View {
    let item: BlogItemDisplay
    var destination: (() -> AnyView)? = nil
    var onAdd: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let destination {
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
            HStack(spacing: 8) {
                if !item.location.isEmpty {
                    Label(item.location, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(AppColors.locationGreen)
                        .accessibilityIdentifier("Journal blog item location")
                }
                Spacer(minLength: 0)
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
                    .accessibilityLabel("Add blog item")
                }
            }
            if item.syncStatus == .failed {
                SyncStatusIndicator(status: item.syncStatus).font(.caption)
            }
        }
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
            if !item.blogText.isEmpty {
                Text(PostTextLinkifier.attributedString(item.blogText))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Journal blog item text")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var metadataPill: some View {
        metadataPillContent
            .background(.regularMaterial.opacity(0.75), in: .rect(cornerRadius: 12))
            .modifier(MetadataPillAccessibility(label: metadataAccessibilityLabel))
    }

    private var photoMetadataPill: some View {
        metadataPillContent
            .background(Color.gray.opacity(0.28), in: .rect(cornerRadius: 12))
            .modifier(MetadataPillAccessibility(label: metadataAccessibilityLabel))
    }

    private var metadataPillContent: some View {
        HStack(spacing: 6) {
            Text(item.author)
            Text("·")
            Text(item.metadataDateTimeText())
            if let temperature = item.weather.temperatureCelsius,
               let symbol = item.weather.systemImage {
                Text("·")
                Image(systemName: symbol)
                Text("\(temperature.formatted(.number))°")
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
        return components.joined(separator: ", ")
    }

    private var accessibilitySummary: String {
        let weatherSummary: String
        if let temperature = item.weather.temperatureCelsius,
           let condition = item.weather.condition {
            weatherSummary = ", \(temperature) degrees, \(condition)"
        } else {
            weatherSummary = ""
        }
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

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            dayHeader
            ForEach(displayedItems) { item in
                if let blogItemDestination {
                    BlogItemCard(
                        item: item,
                        destination: { blogItemDestination(item) },
                        onAdd: onAddBlogItem.map { add in { add(item) } }
                    )
                } else {
                    BlogItemCard(
                        item: item,
                        onAdd: onAddBlogItem.map { add in { add(item) } }
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
                .font(.title2.weight(.bold))
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
