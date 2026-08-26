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
    let subject: String
    let html: String
    let previewHTML: String
    let imageAttachments: [DayPostEmailImageAttachment]
}

nonisolated struct DayPostEmailGenerator: Sendable {
    func generate(days: [DayPostDisplay], trips: [TripDisplay] = []) -> DayPostEmailDraft {
        let days = normalizedDays(days)
        var attachments: [DayPostEmailImageAttachment] = []
        let renderedDays = days.map { renderDay($0, attachments: &attachments) }
        let emailBody = renderedDays.map { $0.email }.joined(separator: "\n")
        let previewBody = renderedDays.map { $0.preview }.joined(separator: "\n")
        return DayPostEmailDraft(
            subject: subject(for: trips, days: days),
            html: document(wrapping: emailBody.isEmpty ? emptyState : emailBody),
            previewHTML: document(wrapping: previewBody.isEmpty ? emptyState : previewBody),
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
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>InstaBlog Journal Post</title></head>
        <body style="margin:0;padding:24px;background:#f5f2ee;">
        <div style="max-width:720px;margin:0 auto;background:#fff;padding:24px;border-radius:16px;">
        \(body)
        </div></body></html>
        """
    }

    private func renderDay(
        _ day: DayPostDisplay,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> (email: String, preview: String) {
        let renderedPosts = day.blogItems
            .sorted { $0.date < $1.date }
            .map { renderBlogItem($0, attachments: &attachments) }
        let title = escape(Self.dayTitle(for: day.date))
        let route = day.routeBreadcrumb.isEmpty ? "" : """
        <p style="margin:4px 0 20px;color:#138808;font-size:15px;">\(escape(day.routeBreadcrumb))</p>
        """
        return (
            email: daySection(title: title, route: route, body: renderedPosts.map { $0.email }.joined(separator: "\n")),
            preview: daySection(title: title, route: route, body: renderedPosts.map { $0.preview }.joined(separator: "\n"))
        )
    }

    private func daySection(title: String, route: String, body: String) -> String {
        """
        <section style="margin:0 0 36px;">
        <h1 style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;color:#111;font-size:28px;">
        \(title)
        </h1>
        \(route)
        \(body)
        </section>
        """
    }

    private func renderBlogItem(
        _ item: BlogItemDisplay,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> (email: String, preview: String) {
        let renderedPhotos = item.photos.map { renderPhoto($0, attachments: &attachments) }
        let text = item.blogText.isEmpty ? "" : """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:12px 0 0;font-size:18px;color:#111;line-height:1.35;white-space:pre-wrap;">\
        \(PostTextLinkifier.html(item.blogText))\
        </p>
        """
        let metadata = metadata(for: item)
        return (
            email: blogItemArticle(
                metadata: metadata,
                body: renderedPhotos.map { $0.email }.joined(separator: "\n"),
                text: text
            ),
            preview: blogItemArticle(
                metadata: metadata,
                body: renderedPhotos.map { $0.preview }.joined(separator: "\n"),
                text: text
            )
        )
    }

    private func blogItemArticle(metadata: String, body: String, text: String) -> String {
        """
        <article style="margin:0 0 24px;padding:0 0 22px;border-bottom:1px solid #e7e2dc;">
        \(metadata)
        <div style="display:flex;overflow-x:auto;gap:10px;">\(body)</div>
        \(text)
        </article>
        """
    }

    private func renderPhoto(
        _ photo: PhotoItemDisplay,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> (email: String, preview: String) {
        let image: (email: String, preview: String)
        if let source = imageSource(for: photo, attachments: &attachments) {
            image = (
                email: photoImageHTML(src: "cid:\(source.contentID)", caption: photo.caption),
                preview: photoImageHTML(
                    src: "data:\(source.mimeType);base64,\(source.base64)",
                    caption: photo.caption
                )
            )
        } else {
            let placeholder = """
            <div style="height:180px;background:#e8e5e1;border-radius:12px;display:flex;align-items:center;justify-content:center;color:#777;">Photo unavailable</div>
            """
            image = (email: placeholder, preview: placeholder)
        }
        let caption = photo.caption.isEmpty ? "" : """
        <p style="display:inline-block;margin:8px 0 0;padding:5px 10px;background:#efede9;border-radius:999px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;color:#222;">\(escape(photo.caption))</p>
        """
        return (
            email: photoColumn(body: image.email, caption: caption),
            preview: photoColumn(body: image.preview, caption: caption)
        )
    }

    private func photoImageHTML(src: String, caption: String) -> String {
        "<div style=\"overflow:hidden;border-radius:12px;\"><img src=\"\(escape(src))\" alt=\"\(escape(caption))\" style=\"display:block;width:100%;height:auto;border-radius:12px;\"></div>"
    }

    private func photoColumn(body: String, caption: String) -> String {
        "<div style=\"flex:0 0 90%;min-width:0;\">\(body)\(caption)</div>"
    }

    private struct PhotoRenderSource {
        let contentID: String
        let mimeType: String
        let base64: String
    }

    private func imageSource(
        for photo: PhotoItemDisplay,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> PhotoRenderSource? {
        guard let path = photo.localImagePath else { return nil }
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            AppTelemetry.log(
                "Unable to load photo while generating email",
                category: "sharing.email",
                level: .warning,
                error: error,
                data: ["photo_id": photo.id.uuidString]
            )
            return nil
        }
        guard let jpegData = resizedOpaqueJPEGData(from: sourceData) else {
            // Never embed the full-size original: a photo that cannot be
            // downsampled is not usable in an email, and embedding tens of MB
            // of raw data spikes memory. Render the placeholder instead.
            AppTelemetry.log(
                "Photo could not be resized for email; rendering placeholder",
                category: "sharing.email",
                level: .warning,
                data: ["photo_id": photo.id.uuidString]
            )
            return nil
        }
        let contentID = "instablog-\(photo.id.uuidString.lowercased())@local"
        attachments.append(
            DayPostEmailImageAttachment(
                id: photo.id,
                contentID: contentID,
                sourcePath: path,
                suggestedFilename: "\(photo.id.uuidString.lowercased()).jpg",
                mimeType: "image/jpeg",
                data: jpegData
            )
        )
        return PhotoRenderSource(
            contentID: contentID,
            mimeType: "image/jpeg",
            base64: jpegData.base64EncodedString()
        )
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
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

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
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            opaqueImage,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func metadata(for item: BlogItemDisplay) -> String {
        var pieces = [escape(item.author), escape(item.metadataDateTimeText())]
        if !item.location.isEmpty { pieces.append(escape(item.location)) }
        if let temperature = item.weather.temperatureCelsius {
            pieces.append("\(temperature.formatted(.number))°C")
        }
        if let altitude = item.displayAltitude {
            pieces.append(altitude)
        }
        return """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0 0 10px;color:#555;font-size:14px;">
        \(pieces.joined(separator: " · "))
        </p>
        """
    }

    private func normalizedDays(_ days: [DayPostDisplay]) -> [DayPostDisplay] {
        var byLocalDay: [String: DayPostDisplay] = [:]
        for day in days {
            if var existing = byLocalDay[day.localDay] {
                existing.blogItems.append(contentsOf: day.blogItems)
                for location in day.route where !existing.route.contains(location) {
                    existing.route.append(location)
                }
                byLocalDay[day.localDay] = existing
            } else {
                byLocalDay[day.localDay] = day
            }
        }
        return byLocalDay.values.sorted { $0.localDay < $1.localDay }
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func dayTitle(for date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private static let fallbackSubject = "InstaBlog journal post"

    private func subject(for trips: [TripDisplay], days: [DayPostDisplay]) -> String {
        var grouped: [UUID: (title: String, startLocalDay: String, days: [DayPostDisplay])] = [:]
        for day in days {
            guard let trip = containingTrip(for: day, in: trips) else { continue }
            var bucket = grouped[trip.id] ?? (trip.title, trip.startLocalDay, [])
            bucket.days.append(day)
            grouped[trip.id] = bucket
        }
        let parts = grouped.values
            .sorted { $0.startLocalDay < $1.startLocalDay }
            .compactMap { subjectPart(tripTitle: $0.title, startLocalDay: $0.startLocalDay, days: $0.days) }
        return parts.isEmpty ? Self.fallbackSubject : parts.joined(separator: ", ")
    }

    private func containingTrip(for day: DayPostDisplay, in trips: [TripDisplay]) -> TripDisplay? {
        TripDisplay.tripContaining(localDay: day.localDay, in: trips)
    }

    private func subjectPart(
        tripTitle: String,
        startLocalDay: String,
        days: [DayPostDisplay]
    ) -> String? {
        guard let first = days.first, let last = days.last,
              let progress = JournalDayProgress(
                  startLocalDay: startLocalDay,
                  dayLocalDay: first.localDay,
                  endLocalDay: last.localDay
              ) else {
            return nil
        }
        let dayText = progress.dayNumber == progress.totalDays
            ? "day \(progress.dayNumber)"
            : "days \(progress.dayNumber)-\(progress.totalDays)"

        let posts = days.flatMap(\.blogItems).sorted { $0.date < $1.date }
        guard let earliestPost = posts.first, let lastPost = posts.last else {
            return "\(tripTitle) \(dayText)"
        }
        var locations = [
            DayPostDisplay.routeLocationDisplay(for: earliestPost.location),
            DayPostDisplay.routeLocationDisplay(for: lastPost.location),
        ].compactMap { $0 }
        if locations.count == 2, locations[0] == locations[1] {
            locations.removeLast()
        }
        let locationText = locations.joined(separator: " - ")
        return locationText.isEmpty
            ? "\(tripTitle) \(dayText)"
            : "\(tripTitle) \(dayText): \(locationText)"
    }
}

nonisolated enum DayPostShareDayCollector {
    static func entryCount(
        from trips: [TripDisplay],
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) -> Int {
        days(from: trips, startDate: startDate, endDate: endDate, calendar: calendar)
            .reduce(0) { $0 + $1.blogItems.count }
    }

    static func days(
        from trips: [TripDisplay],
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) -> [DayPostDisplay] {
        let rangeStart = calendar.startOfDay(for: startDate)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))
            ?? endDate
        var byLocalDay: [String: DayPostDisplay] = [:]
        for day in trips.flatMap(\.days) {
            guard day.date >= rangeStart && day.date < rangeEnd else { continue }
            if var existing = byLocalDay[day.localDay] {
                existing.blogItems.append(contentsOf: day.blogItems)
                for location in day.route where !existing.route.contains(location) {
                    existing.route.append(location)
                }
                byLocalDay[day.localDay] = existing
            } else {
                byLocalDay[day.localDay] = day
            }
        }
        return byLocalDay.values.sorted { $0.localDay < $1.localDay }
    }
}
