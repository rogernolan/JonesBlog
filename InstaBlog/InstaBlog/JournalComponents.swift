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
    enum Scaling {
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
    private let photoStripHeight: CGFloat = 260

    let photos: [PhotoItemDisplay]
    let syncStatus: BlogItemSyncStatus

    var body: some View {
        if photos.count == 1, let photo = photos.first {
            photoView(photo)
                .frame(maxWidth: .infinity, minHeight: photo.localImagePath == nil ? 220 : 0)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: photoSpacing) {
                    ForEach(photos) { photo in
                        photoView(photo)
                            .frame(height: photoStripHeight)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                length - photoPeekWidth - photoSpacing
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .frame(height: photoStripHeight)
        }
    }

    private func photoView(_ photo: PhotoItemDisplay) -> some View {
        JournalPhotoSurface(photo: photo)
            .clipShape(.rect(cornerRadius: 22))
            .overlay(alignment: .bottomLeading) {
                if !photo.caption.isEmpty {
                    Text(photo.caption)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: .capsule)
                        .padding(10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                PhotoSyncStatusIndicator(photo: photo, syncStatus: syncStatus)
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.iconOnly)
                    .padding(8)
                    .background(.regularMaterial, in: .circle)
                    .padding(10)
            }
    }
}

struct BlogItemCard: View {
    private let multiPhotoMetadataOverlap: CGFloat = 18

    let item: BlogItemDisplay
    var destination: (() -> AnyView)? = nil
    var onAdd: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let destination {
                NavigationLink { destination() } label: { content }
                    .buttonStyle(.plain)
            } else {
                NavigationLink(value: JournalDestination.blogItem(item)) { content }
                    .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                if !item.location.isEmpty {
                    Label(item.location, systemImage: "mappin.and.ellipse")
                        .font(.footnote)
                        .foregroundStyle(AppColors.locationGreen)
                }
                Spacer(minLength: 0)
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .frame(width: 44, height: 44)
                            .background(Color.secondary.opacity(0.16), in: .circle)
                    }
                    .accessibilityLabel("Add blog item")
                }
            }
            if item.syncStatus == .failed {
                SyncStatusIndicator(status: item.syncStatus).font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Journal blog item card")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.photos.isEmpty {
                if item.photos.count > 1 {
                    VStack(alignment: .leading, spacing: -multiPhotoMetadataOverlap) {
                        BlogItemPhotoStrip(photos: item.photos, syncStatus: item.syncStatus)
                        multiPhotoMetadataPill
                    }
                } else {
                    BlogItemPhotoStrip(photos: item.photos, syncStatus: item.syncStatus)
                        .overlay(alignment: .bottomLeading) {
                            metadataPill.padding(10)
                        }
                }
            } else {
                metadataPill.foregroundStyle(.secondary)
            }
            if !item.blogText.isEmpty {
                Text(PostTextLinkifier.attributedString(item.blogText))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var metadataPill: some View {
        metadataPillContent
            .background(.regularMaterial.opacity(0.75), in: .rect(cornerRadius: 12))
    }

    private var multiPhotoMetadataPill: some View {
        metadataPillContent
            .background(Color.gray.opacity(0.28), in: .rect(cornerRadius: 12))
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
