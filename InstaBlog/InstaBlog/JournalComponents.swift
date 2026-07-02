import SwiftUI
import UIKit

struct SyncStatusIndicator: View {
    let status: BlogItemSyncStatus

    var body: some View {
        switch status {
        case .synced:
            EmptyView()
        case .pending:
            Label("Uploading", systemImage: "arrow.up.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Upload pending")
        case .failed:
            Label("Upload failed", systemImage: "exclamationmark.icloud.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Upload failed")
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

struct BlogItemCard: View {
    let item: BlogItemDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.localImagePath != nil || item.palette != nil {
                JournalPhotoSurface(item: item)
                    .frame(minHeight: 220)
                    .clipShape(.rect(cornerRadius: 22))
                    .overlay(alignment: .bottomLeading) {
                        metadataOverlay
                            .padding(10)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if item.syncStatus != .synced {
                            SyncStatusIndicator(status: item.syncStatus)
                                .font(.caption2.weight(.semibold))
                                .labelStyle(.iconOnly)
                                .padding(8)
                                .background(.regularMaterial, in: .circle)
                                .padding(10)
                        }
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
                    .foregroundStyle(.secondary)
            }

            if item.palette == nil {
                SyncStatusIndicator(status: item.syncStatus)
                    .font(.caption)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
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
                Text("\(temperature)°")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
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
                Text("\(temperature)°")
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
}

struct GalleryFilmstrip: View {
    let gallery: GalleryDisplay

    var body: some View {
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
                let width = max(112, proxy.size.width * 0.38)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(gallery.items) { item in
                            NavigationLink(value: JournalDestination.gallery(gallery)) {
                                filmstripItem(item, width: width)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            }
            .frame(height: 156)

            Text(gallery.items.first?.caption ?? "")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gallery, \(gallery.title), \(gallery.items.count) moments")
    }

    private func filmstripItem(_ item: BlogItemDisplay, width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            JournalPhotoSurface(item: item)

            Text("\(item.author) · \(item.localTimeText())")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
                .padding(8)
        }
        .frame(width: width, height: 156)
        .clipShape(.rect(cornerRadius: 18))
        .overlay(alignment: .topTrailing) {
            if item.syncStatus != .synced {
                SyncStatusIndicator(status: item.syncStatus)
                    .font(.caption2)
                    .labelStyle(.iconOnly)
                    .padding(8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.author), \(item.localTimeText()), \(item.caption)")
        .accessibilityHint("Opens Gallery")
    }
}

struct JournalPhotoSurface: View {
    let item: BlogItemDisplay

    var body: some View {
        if let localImagePath = item.localImagePath,
           let image = UIImage(contentsOfFile: localImagePath) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel(photoAccessibilityLabel)
        } else if let palette = item.palette {
            JournalPhotoPlaceholder(palette: palette)
        } else {
            Color.secondary.opacity(0.15)
                .accessibilityLabel(photoAccessibilityLabel)
        }
    }

    private var photoAccessibilityLabel: String {
        if item.localImagePath != nil {
            return "Photo attached to BlogItem"
        }
        return "Placeholder image for BlogItem"
    }
}

struct DayPostSection: View {
    let dayPost: DayPostDisplay
    let dayNumber: Int
    let totalDays: Int

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            dayHeader

            ForEach(Array(dayPost.entries.enumerated().reversed()), id: \.element.id) { _, entry in
                switch entry {
                case .blogItem(let item):
                    NavigationLink(value: JournalDestination.blogItem(item)) {
                        BlogItemCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("Journal blog item card")
                case .gallery(let gallery):
                    GalleryFilmstrip(gallery: gallery)
                }
            }
        }
    }

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("DAY \(dayNumber) OF \(totalDays)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(dayPost.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.title2.weight(.bold))
            Text(dayPost.routeBreadcrumb)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
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
