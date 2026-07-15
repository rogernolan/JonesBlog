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
        let days = normalizedDays(days)
        var attachments: [DayPostEmailImageAttachment] = []
        let emailBody = days
            .map { renderDay($0, mode: .email, attachments: &attachments) }
            .joined(separator: "\n")
        var previewAttachments: [DayPostEmailImageAttachment] = []
        let previewBody = days
            .map { renderDay($0, mode: .preview, attachments: &previewAttachments) }
            .joined(separator: "\n")
        return DayPostEmailDraft(
            html: document(wrapping: emailBody.isEmpty ? emptyState : emailBody),
            previewHTML: document(wrapping: previewBody.isEmpty ? emptyState : previewBody),
            imageAttachments: attachments
        )
    }

    private enum ImageMode {
        case email
        case preview
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
        mode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        let posts = day.blogItems
            .sorted { $0.date < $1.date }
            .map { renderBlogItem($0, mode: mode, attachments: &attachments) }
            .joined(separator: "\n")
        let route = day.routeBreadcrumb.isEmpty ? "" : """
        <p style="margin:4px 0 20px;color:#138808;font-size:15px;">\(escape(day.routeBreadcrumb))</p>
        """
        return """
        <section style="margin:0 0 36px;">
        <h1 style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;color:#111;font-size:28px;">
        \(escape(Self.dayTitle(for: day.date)))
        </h1>
        \(route)
        \(posts)
        </section>
        """
    }

    private func renderBlogItem(
        _ item: BlogItemDisplay,
        mode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        let photos = item.photos
            .map { renderPhoto($0, mode: mode, attachments: &attachments) }
            .joined(separator: "\n")
        let text = item.blogText.isEmpty ? "" : """
        <p style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:12px 0 0;font-size:18px;color:#111;line-height:1.35;">
        \(PostTextLinkifier.html(item.blogText))
        </p>
        """
        return """
        <article style="margin:0 0 24px;padding:0 0 22px;border-bottom:1px solid #e7e2dc;">
        \(metadata(for: item))
        <div style="display:flex;overflow-x:auto;gap:10px;">\(photos)</div>
        \(text)
        </article>
        """
    }

    private func renderPhoto(
        _ photo: PhotoItemDisplay,
        mode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String {
        let image = imageSource(for: photo, mode: mode, attachments: &attachments).map { source in
            "<img src=\"\(escape(source))\" alt=\"\(escape(photo.caption))\" style=\"display:block;width:100%;height:auto;border-radius:12px;\">"
        } ?? """
        <div style="height:180px;background:#e8e5e1;border-radius:12px;display:flex;align-items:center;justify-content:center;color:#777;">Photo unavailable</div>
        """
        let caption = photo.caption.isEmpty ? "" : """
        <p style="display:inline-block;margin:8px 0 0;padding:5px 10px;background:#efede9;border-radius:999px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;color:#222;">\(escape(photo.caption))</p>
        """
        return "<div style=\"flex:0 0 100%;min-width:0;\">\(image)\(caption)</div>"
    }

    private func imageSource(
        for photo: PhotoItemDisplay,
        mode: ImageMode,
        attachments: inout [DayPostEmailImageAttachment]
    ) -> String? {
        guard let path = photo.localImagePath,
              let sourceData = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        let fileURL = URL(fileURLWithPath: path)
        let jpegData = resizedOpaqueJPEGData(from: sourceData)
        switch mode {
        case .preview:
            if let jpegData {
                return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
            }
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "image/jpeg"
            return "data:\(mimeType);base64,\(sourceData.base64EncodedString())"
        case .email:
            let contentID = "instablog-\(photo.id.uuidString.lowercased())@local"
            let attachmentData = jpegData ?? sourceData
            let usesJPEG = jpegData != nil
            attachments.append(
                DayPostEmailImageAttachment(
                    id: photo.id,
                    contentID: contentID,
                    sourcePath: path,
                    suggestedFilename: usesJPEG
                        ? "\(photo.id.uuidString.lowercased()).jpg"
                        : fileURL.lastPathComponent,
                    mimeType: usesJPEG
                        ? "image/jpeg"
                        : UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "image/jpeg",
                    data: attachmentData
                )
            )
            return "cid:\(contentID)"
        }
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
}

nonisolated enum DayPostShareDayCollector {
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
