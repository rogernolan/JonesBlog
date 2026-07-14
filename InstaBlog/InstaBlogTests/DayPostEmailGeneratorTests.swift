import Foundation
import Testing
@testable import InstaBlog

@Suite("Day post email generation")
struct DayPostEmailGeneratorTests {
    @Test("Generates days oldest to newest and entries oldest to newest")
    func generatesChronologicalDaysAndEntries() {
        let newerDay = day(
            localDay: "2026-07-10",
            entries: [
                .blogItem(item(caption: "Second entry", date: date("2026-07-10T12:00:00Z"))),
                .blogItem(item(caption: "First entry", date: date("2026-07-10T09:00:00Z")))
            ]
        )
        let olderDay = day(
            localDay: "2026-07-09",
            entries: [
                .blogItem(item(caption: "Previous day", date: date("2026-07-09T15:00:00Z")))
            ]
        )

        let draft = DayPostEmailGenerator().generate(days: [newerDay, olderDay])

        #expect(draft.html.range(of: "Previous day")!.lowerBound < draft.html.range(of: "First entry")!.lowerBound)
        #expect(draft.html.range(of: "First entry")!.lowerBound < draft.html.range(of: "Second entry")!.lowerBound)
    }

    @Test("Includes text-only entries with escaped captions")
    func includesTextOnlyEntries() {
        let textOnlyItem = item(
            caption: "Tea & <cake>",
            hasPhoto: false,
            localImagePath: nil
        )

        let draft = DayPostEmailGenerator().generate(
            days: [day(entries: [.blogItem(textOnlyItem)])]
        )

        #expect(draft.html.contains("Tea &amp; &lt;cake&gt;"))
        #expect(draft.imageAttachments.isEmpty)
    }

    @Test("Keeps galleries grouped and records image attachments")
    func keepsGalleriesGrouped() {
        let imagePath = temporaryImagePath()
        let galleryItem = item(
            id: UUID(uuidString: "A1407B0A-4574-47A4-9B40-B91F6EAD084C")!,
            caption: "Gallery photo",
            hasPhoto: true,
            localImagePath: imagePath
        )
        let gallery = GalleryDisplay(
            title: "Related photos",
            description: "Things that belong together",
            location: "Orlestone",
            items: [galleryItem]
        )

        let draft = DayPostEmailGenerator().generate(
            days: [day(route: [], entries: [.gallery(gallery)])]
        )

        #expect(draft.html.contains("Related photos"))
        #expect(draft.html.contains("Things that belong together"))
        #expect(draft.html.contains("cid:blogitem-a1407b0a-4574-47a4-9b40-b91f6ead084c@instablog"))
        #expect(draft.html.contains("height:160px;object-fit:cover"))
        #expect(draft.html.contains("height:160px;object-fit:cover;border-radius:12px"))
        #expect(draft.html.range(of: "Gallery photo")!.lowerBound < draft.html.range(of: "Things that belong together")!.lowerBound)
        #expect(draft.html.range(of: "Things that belong together")!.lowerBound < draft.html.range(of: "Orlestone")!.lowerBound)
        #expect(draft.previewHTML.contains("data:image/jpeg;base64,"))
        #expect(draft.imageAttachments.count == 1)
        #expect(draft.imageAttachments[0].id == galleryItem.id)
        #expect(draft.imageAttachments[0].contentID == "blogitem-a1407b0a-4574-47a4-9b40-b91f6ead084c@instablog")
        #expect(draft.imageAttachments[0].sourcePath == imagePath)
        #expect(draft.imageAttachments[0].suggestedFilename == "a1407b0a-4574-47a4-9b40-b91f6ead084c.jpg")
        #expect(draft.imageAttachments[0].mimeType == "image/jpeg")
        #expect(draft.imageAttachments[0].data.starts(with: [0xFF, 0xD8]))
    }

    @Test("Merges matching gallery entries into one tiled block")
    func mergesMatchingGalleryEntriesIntoOneBlock() {
        let firstImagePath = temporaryImagePath()
        let secondImagePath = temporaryImagePath()
        let firstGallery = GalleryDisplay(
            id: UUID(),
            title: "Whitby, North Yorkshire",
            description: "Together by the harbour",
            location: "Whitby, North Yorkshire",
            placementDate: date("2026-06-12T09:00:00Z"),
            localDay: "2026-06-12",
            items: [
                item(
                    caption: "Kippers being smoked",
                    date: date("2026-06-12T09:00:00Z"),
                    hasPhoto: true,
                    localImagePath: firstImagePath
                )
            ]
        )
        let secondGallery = GalleryDisplay(
            id: UUID(),
            title: "Whitby, North Yorkshire",
            description: "Together by the harbour",
            location: "Whitby, North Yorkshire",
            placementDate: date("2026-06-12T10:00:00Z"),
            localDay: "2026-06-12",
            items: [
                item(
                    caption: "We visited Whitby",
                    date: date("2026-06-12T10:00:00Z"),
                    hasPhoto: true,
                    localImagePath: secondImagePath
                )
            ]
        )

        let draft = DayPostEmailGenerator().generate(
            days: [
                day(
                    localDay: "2026-06-12",
                    route: [],
                    entries: [.gallery(firstGallery), .gallery(secondGallery)]
                )
            ]
        )

        #expect(draft.html.contains("Kippers being smoked"))
        #expect(draft.html.contains("We visited Whitby"))
        #expect(occurrences(of: "Together by the harbour", in: draft.html) == 1)
        #expect(occurrences(of: "Whitby, North Yorkshire", in: draft.html) == 2)
        #expect(draft.imageAttachments.count == 2)
        #expect(draft.imageAttachments.allSatisfy { $0.mimeType == "image/jpeg" && $0.data.starts(with: [0xFF, 0xD8]) })
    }

    @Test("Does not render generic gallery title")
    func doesNotRenderGenericGalleryTitle() {
        let gallery = GalleryDisplay(
            title: "Gallery",
            description: "",
            location: "",
            items: [
                item(
                    caption: "Only caption",
                    hasPhoto: true,
                    localImagePath: temporaryImagePath()
                )
            ]
        )

        let draft = DayPostEmailGenerator().generate(
            days: [day(route: [], entries: [.gallery(gallery)])]
        )

        #expect(draft.html.contains("Only caption"))
        #expect(!draft.html.contains(">Gallery<"))
    }

    @Test("Collects and merges days inside the selected date range")
    func collectsDaysInsideDateRange() {
        let firstTrip = TripDisplay(
            title: "First trip",
            startLocalDay: "2026-07-08",
            days: [
                day(localDay: "2026-07-08", route: ["Ashford"], entries: []),
                day(localDay: "2026-07-09", route: ["Orlestone"], entries: [
                    .blogItem(item(caption: "Trip entry"))
                ])
            ]
        )
        let secondTrip = TripDisplay(
            title: "Second trip",
            startLocalDay: "2026-07-09",
            days: [
                day(localDay: "2026-07-09", route: ["Hamstreet"], entries: [
                    .blogItem(item(caption: "Merged entry"))
                ]),
                day(localDay: "2026-07-10", route: ["Rye"], entries: [])
            ]
        )

        let days = DayPostShareDayCollector.days(
            from: [firstTrip, secondTrip],
            startDate: date("2026-07-09T00:00:00Z"),
            endDate: date("2026-07-09T23:59:59Z"),
            calendar: gregorianUTC
        )

        #expect(days.count == 1)
        #expect(days[0].localDay == "2026-07-09")
        #expect(days[0].route == ["Orlestone", "Hamstreet"])
        #expect(days[0].entries.count == 2)
    }

    private func day(
        localDay: String = "2026-07-10",
        route: [String] = ["Orlestone"],
        entries: [DayPostEntry]
    ) -> DayPostDisplay {
        DayPostDisplay(
            date: date("\(localDay)T00:00:00Z"),
            localDay: localDay,
            route: route,
            entries: entries
        )
    }

    private func item(
        id: UUID = UUID(),
        caption: String,
        date: Date = Date(timeIntervalSince1970: 1_783_675_800),
        hasPhoto: Bool = false,
        localImagePath: String? = nil
    ) -> BlogItemDisplay {
        BlogItemDisplay(
            id: id,
            author: "Jane",
            date: date,
            timeZoneIdentifier: "UTC",
            caption: caption,
            location: "Orlestone",
            weather: WeatherDisplay(temperatureCelsius: 21, condition: "Sunny"),
            hasPhoto: hasPhoto,
            photoAvailability: hasPhoto ? .available : .none,
            localImagePath: localImagePath,
            palette: nil
        )
    }

    private var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func temporaryImagePath() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try! onePixelPNG.write(to: url)
        return url.path
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
