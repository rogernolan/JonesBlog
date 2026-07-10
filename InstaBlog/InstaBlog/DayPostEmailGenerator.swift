import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct DayPostEmailImageAttachment: Equatable, Sendable {
    let id: UUID
    let contentID: String
    let sourcePath: String
    let suggestedFilename: String
    let mimeType: String
    let data: Data
}

nonisolated struct DayPostEmailDraft: Equatable, Sendable {
    let html: String
    let previewHTML: String
    let imageAttachments: [DayPostEmailImageAttachment]
}

nonisolated struct DayPostEmailGenerator: Sendable {
    func generate(days: [DayPostDisplay]) -> DayPostEmailDraft {
        var attachments: [DayPostEmailImageAttachment] = []
        let sortedDays = days.sorted { $0.localDay < $1.localDay }

        let emailBody = sortedDays
            .map { renderDay($0, imageMode: .email, attachments: &attachments) }
            .joined(separator: "\n")
        var previewAttachments: [DayPostEmailImageAttachment] = []
        let previewBody = sortedDays
            .map { renderDay($0, imageMode: .preview, attachments: &previewAttachments) }
            .joined(separator: "\n")

        let html = document(wrapping: emailBody.isEmpty ? emptyState : emailBody)
        let previewHTML = document(wrapping: previewBody.isEmpty ? emptyState : previewBody)

        return DayPostEmailDraft(
            html: html,
            previewHTML: previewHTML,
            imageAttachments: attachments
        )
    }

    private var emptyState: String {
        """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#555;">
        No journal entries were found for this date range.
        </p>
        """
    }

    private func document(wrapping body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>InstaBlog Journal Post</title>
        </head>
        <body style="margin:0;padding:24px;background:#f5f2ee;">
        <div style="max-width:720px;margin:0 auto;background:#ffffff;padding:24px;border-radius:16px;">
        \(body)
        </div>
        </body>
        </html>
        """
    }

    private enum ImageMode {
        case email
        case preview
    }

    private func renderDay(
        _ day: DayPostDisplay,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        let entries = normalizedEntries(day.entries)
            .sorted { entrySortDate($0) < entrySortDate($1) }
        let renderedEntries = entries
            .map { renderEntry($0, imageMode: imageMode, attachments: &attachments) }
            .joined(separator: "\n")

        let route = day.routeBreadcrumb.isEmpty ? "" : """
        <p style="margin:4px 0 20px 0;color:#138808;font-size:15px;">\(escape(day.routeBreadcrumb))</p>
        """

        return """
        <section style="margin:0 0 36px 0;">
        <h1 style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;color:#111;font-size:28px;">
        \(escape(Self.dayTitle(for: day.date)))
        </h1>
        \(route)
        \(renderedEntries)
        </section>
        """
    }

    private func renderEntry(
        _ entry: DayPostEntry,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        switch entry {
        case .blogItem(let item):
            return renderBlogItem(item, imageMode: imageMode, attachments: &attachments)
        case .gallery(let gallery):
            return renderGallery(gallery, imageMode: imageMode, attachments: &attachments)
        }
    }

    private func renderBlogItem(
        _ item: BlogItemDisplay,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        let image = renderImage(for: item, imageMode: imageMode, attachments: &attachments)
        let caption = item.caption.isEmpty ? "" : """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:10px 0 0 0;font-size:18px;color:#111;line-height:1.35;">
        \(escape(item.caption))
        </p>
        """

        return """
        <article style="margin:0 0 24px 0;padding:0 0 22px 0;border-bottom:1px solid #e7e2dc;">
        \(metadata(for: item))
        \(image)
        \(caption)
        </article>
        """
    }

    private func renderGallery(
        _ gallery: GalleryDisplay,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        let description = gallery.description.isEmpty ? "" : """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:14px 0 0 0;color:#555;line-height:1.35;text-align:center;">
        \(escape(gallery.description))
        </p>
        """
        let location = gallery.location.isEmpty ? "" : """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:8px 0 0 0;color:#138808;font-size:14px;text-align:center;">
        \(escape(gallery.location))
        </p>
        """
        let sortedItems = gallery.items.sorted { $0.date < $1.date }
        let rows = stride(from: 0, to: sortedItems.count, by: 2)
            .map { startIndex in
                let first = galleryCell(
                    for: sortedItems[startIndex],
                    imageMode: imageMode,
                    attachments: &attachments
                )
                let second = startIndex + 1 < sortedItems.count
                    ? galleryCell(
                        for: sortedItems[startIndex + 1],
                        imageMode: imageMode,
                        attachments: &attachments
                    )
                    : "<td style=\"width:50%;padding:6px;vertical-align:top;\"></td>"
                return "<tr>\(first)\(second)</tr>"
            }
            .joined(separator: "\n")
        let title = galleryTitleText(for: gallery).map {
        """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:14px 0 0 0;color:#111;font-size:18px;line-height:1.35;text-align:center;">
        \(escape($0))
        </p>
        """
        } ?? ""

        return """
        <section style="margin:0 0 28px 0;padding:0 0 22px 0;border-bottom:1px solid #e7e2dc;">
        <table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;">
        \(rows)
        </table>
        \(title)
        \(description)
        \(location)
        </section>
        """
    }

    private func galleryCell(
        for item: BlogItemDisplay,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        let image = renderGalleryImage(for: item, imageMode: imageMode, attachments: &attachments)
        let caption = item.caption.isEmpty ? "" : """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:8px 0 0 0;font-size:13px;color:#333;line-height:1.3;text-align:center;">
        \(escape(item.caption))
        </p>
        """

        return """
        <td style="width:50%;padding:8px;vertical-align:top;text-align:center;">
        \(image)
        \(caption)
        </td>
        """
    }

    private func galleryTitleText(for gallery: GalleryDisplay) -> String? {
        let trimmedTitle = gallery.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != "Gallery" else { return nil }
        return trimmedTitle
    }

    private func renderGalleryImage(
        for item: BlogItemDisplay,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        guard item.hasPhoto, let localImagePath = item.localImagePath else {
            return ""
        }

        let imageSource = sourceForImage(
            itemID: item.id,
            localImagePath: localImagePath,
            imageMode: imageMode,
            attachments: &attachments
        )
        return """
        <img src="\(imageSource.source)" data-content-id="\(imageSource.contentID)" alt="" style="display:block;width:100%;height:160px;object-fit:cover;border-radius:2px;">
        """
    }

    private func renderImage(
        for item: BlogItemDisplay,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        guard item.hasPhoto, let localImagePath = item.localImagePath else {
            return ""
        }

        let imageSource = sourceForImage(
            itemID: item.id,
            localImagePath: localImagePath,
            imageMode: imageMode,
            attachments: &attachments
        )
        return """
        <img src="\(imageSource.source)" data-content-id="\(imageSource.contentID)" alt="" style="display:block;width:100%;max-width:100%;height:auto;border-radius:12px;margin-top:8px;">
        """
    }

    private func sourceForImage(
        itemID: UUID,
        localImagePath: String,
        imageMode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> (source: String, contentID: String) {
        let contentID = "blogitem-\(itemID.uuidString.lowercased())@instablog"
        let jpegData = emailJPEGData(for: localImagePath)
        if imageMode == .email, let jpegData {
            let attachment = DayPostEmailImageAttachment(
                id: itemID,
                contentID: contentID,
                sourcePath: localImagePath,
                suggestedFilename: "\(itemID.uuidString.lowercased()).jpg",
                mimeType: "image/jpeg",
                data: jpegData
            )
            attachments.append(attachment)
        }

        let source = switch imageMode {
        case .email:
            "cid:\(contentID)"
        case .preview:
            if let jpegData {
                "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
            } else {
                fallbackPreviewImageSource(for: localImagePath)
            }
        }

        return (source, contentID)
    }

    private func fallbackPreviewImageSource(for localImagePath: String) -> String {
        let fileURL = URL(fileURLWithPath: localImagePath)
        guard let imageData = try? Data(contentsOf: fileURL) else {
            return fileURL.absoluteString
        }

        return "data:\(mimeType(for: fileURL));base64,\(imageData.base64EncodedString())"
    }

    private func emailJPEGData(for localImagePath: String) -> Data? {
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: localImagePath)) else {
            return nil
        }
        return resizedOpaqueJPEGData(from: imageData)
    }

    private func resizedOpaqueJPEGData(
        from imageData: Data,
        maxPixelSize: Int = 640,
        compressionQuality: Double = 0.68
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaqueImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, opaqueImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "heic":
            "image/heic"
        case "png":
            "image/png"
        case "webp":
            "image/webp"
        default:
            "image/jpeg"
        }
    }

    private func metadata(for item: BlogItemDisplay) -> String {
        var parts = [item.author, item.localTimeText()]
        if !item.location.isEmpty {
            parts.append(item.location)
        }
        if let temperature = item.weather.temperatureCelsius {
            parts.append("\(temperature)°C")
        }
        if let condition = item.weather.condition, !condition.isEmpty {
            parts.append(condition)
        }

        return """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0 0 8px 0;color:#666;font-size:13px;">
        \(parts.map { escape($0) }.joined(separator: " &middot; "))
        </p>
        """
    }

    private func entrySortDate(_ entry: DayPostEntry) -> Date {
        switch entry {
        case .blogItem(let item):
            return item.date
        case .gallery(let gallery):
            return gallery.placementDate ?? gallery.items.map(\.date).min() ?? .distantPast
        }
    }

    private struct GalleryMergeKey: Hashable {
        let title: String
        let description: String
        let location: String
        let localDay: String?
    }

    private func normalizedEntries(_ entries: [DayPostEntry]) -> [DayPostEntry] {
        var normalized: [DayPostEntry] = []
        var galleryIndexByKey: [GalleryMergeKey: Int] = [:]

        for entry in entries {
            guard case .gallery(let gallery) = entry else {
                normalized.append(entry)
                continue
            }

            let key = GalleryMergeKey(
                title: gallery.title,
                description: gallery.description,
                location: gallery.location,
                localDay: gallery.localDay
            )

            if let existingIndex = galleryIndexByKey[key],
               case .gallery(var existingGallery) = normalized[existingIndex] {
                existingGallery.items.append(contentsOf: gallery.items)
                existingGallery.items.sort { $0.date < $1.date }
                if let placementDate = gallery.placementDate {
                    existingGallery.placementDate = existingGallery.placementDate.map {
                        min($0, placementDate)
                    } ?? placementDate
                }
                normalized[existingIndex] = .gallery(existingGallery)
            } else {
                galleryIndexByKey[key] = normalized.count
                normalized.append(entry)
            }
        }

        return normalized
    }

    private static func dayTitle(for date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

nonisolated enum DayPostShareDayCollector {
    static func days(
        from trips: [TripDisplay],
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) -> [DayPostDisplay] {
        let startLocalDay = JournalDayProgress.localDay(
            from: calendar.startOfDay(for: startDate),
            calendar: calendar
        )
        let endLocalDay = JournalDayProgress.localDay(
            from: calendar.startOfDay(for: endDate),
            calendar: calendar
        )
        var groupedDays: [String: DayPostDisplay] = [:]

        for day in trips.flatMap(\.days) where day.localDay >= startLocalDay && day.localDay <= endLocalDay {
            if var existingDay = groupedDays[day.localDay] {
                existingDay.route = mergedRoute(existingDay.route, with: day.route)
                existingDay.entries.append(contentsOf: day.entries)
                if day.date < existingDay.date {
                    existingDay.date = day.date
                }
                groupedDays[day.localDay] = existingDay
            } else {
                groupedDays[day.localDay] = day
            }
        }

        return groupedDays.values.sorted { $0.localDay < $1.localDay }
    }

    private static func mergedRoute(_ lhs: [String], with rhs: [String]) -> [String] {
        var route = lhs
        for place in rhs where !route.contains(place) {
            route.append(place)
        }
        return route
    }
}
