import SwiftUI
import UIKit

struct SyncStatusIndicator: View {
    let status: BlogItemSyncStatus

    var body: some View {
        switch status {
        case .storedLocally:
            Label("Stored locally", systemImage: "dot.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Stored locally")
        case .synced:
            Label("Uploaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Uploaded")
        case .pending:
            Label("Uploading", systemImage: "arrow.up.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Uploading")
        case .failed:
            Label("Upload failed", systemImage: "exclamationmark.icloud.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Upload failed")
        }
    }
}

struct PhotoAvailabilityIndicator: View {
    let item: BlogItemDisplay

    var body: some View {
        if item.photoAvailability == .downloading {
            Label("Downloading photo", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Downloading photo")
        } else if item.photoAvailability == .unavailable {
            Label("Photo unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Photo unavailable")
        } else {
            SyncStatusIndicator(status: item.syncStatus)
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
                .symbolRenderingMode(.palette)
                .foregroundStyle(.secondary, .orange)
                .accessibilityHidden(true)
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
                .symbolRenderingMode(.palette)
                .foregroundStyle(.secondary, .red)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Photo unavailable")
    }
}

struct BlogItemCard: View {
    let item: BlogItemDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.hasPhoto || item.palette != nil {
                JournalPhotoSurface(item: item)
                    .frame(maxWidth: .infinity, minHeight: item.localImagePath == nil ? 220 : 0)
                    .clipShape(.rect(cornerRadius: 22))
                    .overlay(alignment: .bottomLeading) {
                        metadataOverlay
                            .padding(10)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        PhotoAvailabilityIndicator(item: item)
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.iconOnly)
                            .padding(8)
                            .background(.regularMaterial, in: .circle)
                            .padding(10)
                    }
            } else {
                textOnlyMetadata
            }

            if !item.caption.isEmpty {
                Text(item.caption)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !item.location.isEmpty {
                Label(item.location, systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(AppColors.locationGreen)
            }

            if item.syncStatus == .failed {
                SyncStatusIndicator(status: item.syncStatus)
                    .font(.caption)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(photoSyncAccessibilityValue)
        .accessibilityHint("Opens BlogItem details")
    }

    private var metadataOverlay: some View {
        HStack(spacing: 6) {
            Text(item.author)
            Text("·")
            Text(item.metadataDateTimeText())
            if let temperature = item.weather.temperatureCelsius,
               let systemImage = item.weather.systemImage {
                Text("·")
                Image(systemName: systemImage)
                Text("\(temperature.formatted(.number))°")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial.opacity(0.75), in: .rect(cornerRadius: 12))
    }

    private var textOnlyMetadata: some View {
        HStack(spacing: 6) {
            Text(item.author)
            Text("·")
            Text(item.metadataDateTimeText())
            if let temperature = item.weather.temperatureCelsius,
               let systemImage = item.weather.systemImage {
                Text("·")
                Image(systemName: systemImage)
                Text("\(temperature.formatted(.number))°")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var accessibilitySummary: String {
        let weatherSummary: String
        if let temperature = item.weather.temperatureCelsius,
           let condition = item.weather.condition {
            weatherSummary = ", \(temperature) degrees, \(condition)"
        } else {
            weatherSummary = ""
        }
        return "BlogItem by \(item.author), \(item.metadataDateTimeText()), \(item.caption), \(item.location)\(weatherSummary)"
    }

    private var photoSyncAccessibilityValue: String {
        item.photoSyncAccessibilityValue
    }
}

struct GalleryFilmstrip: View {
    let gallery: GalleryDisplay
    var destination: ((GalleryDisplay) -> AnyView)? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    var body: some View {
        if let destination {
            NavigationLink {
                destination(gallery)
            } label: {
                galleryContent
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: JournalDestination.gallery(gallery)) {
                galleryContent
            }
            .buttonStyle(.plain)
        }
    }

    private var galleryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gallery.title.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(gallery.location)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(gallery.items.count) moments")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let tileSize = horizontalSizeClass == .regular ? 312.0 : 156.0
                let width = horizontalSizeClass == .regular
                    ? tileSize
                    : max(112, proxy.size.width * 0.38)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(gallery.items) { item in
                            filmstripItem(item, width: width, height: tileSize)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            }
            .frame(height: horizontalSizeClass == .regular ? 312 : 156)

            if !gallery.description.isEmpty {
                Text(gallery.description)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gallery, \(gallery.title), \(gallery.items.count) moments")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filmstripItem(_ item: BlogItemDisplay, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            JournalPhotoSurface(item: item, scaling: .fill)
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: 18))
        .overlay(alignment: .bottomLeading) {
            if !item.caption.isEmpty {
                Text(item.caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: width - 16, alignment: .leading)
                    .background(.regularMaterial.opacity(0.75), in: .rect(cornerRadius: 10))
                    .padding(8)
            }
        }
        .contentShape(.rect)
        .overlay(alignment: .topTrailing) {
            PhotoAvailabilityIndicator(item: item)
                .font(.caption2)
                .labelStyle(.iconOnly)
                .padding(8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.author), \(item.localTimeText()), \(item.caption)")
        .accessibilityValue(item.photoSyncAccessibilityValue)
        .accessibilityHint("Opens Gallery")
        .accessibilityIdentifier("Gallery blog item card")
    }
}

struct JournalPhotoSurface: View {
    enum Scaling {
        case fill
        case fit
    }

    let item: BlogItemDisplay
    let scaling: Scaling

    init(
        item: BlogItemDisplay,
        scaling: Scaling = .fit
    ) {
        self.item = item
        self.scaling = scaling
    }

    var body: some View {
        if let localImagePath = item.localImagePath,
           let image = UIImage(contentsOfFile: localImagePath) {
            Image(uiImage: image)
                .resizable()
                .modifier(PhotoScalingModifier(scaling: scaling))
                .accessibilityLabel(photoAccessibilityLabel)
        } else if item.photoAvailability == .downloading {
            MissingPhotoPlaceholder()
        } else if item.photoAvailability == .unavailable {
            BrokenPhotoPlaceholder()
        } else if let palette = item.palette {
            JournalPhotoPlaceholder(palette: palette)
        } else {
            MissingPhotoPlaceholder()
        }
    }

    private var photoAccessibilityLabel: String {
        if item.localImagePath != nil {
            return "Photo attached to BlogItem"
        }
        return "Placeholder image for BlogItem"
    }
}

private extension BlogItemDisplay {
    var photoSyncAccessibilityValue: String {
        guard hasPhoto || palette != nil else { return "" }
        if photoAvailability == .downloading {
            return "Photo sync status: Downloading"
        }
        if photoAvailability == .unavailable {
            return "Photo sync status: Unavailable"
        }
        return "Photo sync status: \(syncStatus.accessibilityDescription)"
    }
}

private struct PhotoScalingModifier: ViewModifier {
    let scaling: JournalPhotoSurface.Scaling

    func body(content: Content) -> some View {
        switch scaling {
        case .fill:
            content
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fit:
            content
                .scaledToFit()
                .frame(maxWidth: .infinity)
        }
    }
}

struct DayPostSection: View {
    let dayPost: DayPostDisplay
    let dayNumber: Int
    let totalDays: Int
    var showsNewestFirst: Bool = true
    var showsActions: Bool = true
    var blogItemDestination: ((BlogItemDisplay) -> AnyView)? = nil
    var galleryDestination: ((GalleryDisplay) -> AnyView)? = nil
    var onAddGallery: () -> Void = {}

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            dayHeader

            ForEach(displayedEntries, id: \.element.id) { _, entry in
                switch entry {
                case .blogItem(let item):
                    if let blogItemDestination {
                        NavigationLink {
                            blogItemDestination(item)
                        } label: {
                            BlogItemCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("Journal blog item card")
                    } else {
                        NavigationLink(value: JournalDestination.blogItem(item)) {
                            BlogItemCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("Journal blog item card")
                    }
                case .gallery(let gallery):
                    GalleryFilmstrip(gallery: gallery, destination: galleryDestination)
                }
            }
        }
    }

    private var displayedEntries: [(offset: Int, element: DayPostEntry)] {
        let enumeratedEntries = Array(dayPost.entries.enumerated())
        return showsNewestFirst ? Array(enumeratedEntries.reversed()) : enumeratedEntries
    }

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(dayPost.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title2.weight(.bold))
                    Text("DAY \(dayNumber) OF \(totalDays)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
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
