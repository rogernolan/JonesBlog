import Foundation
import Testing
@testable import InstaBlog

@Suite("Day post email generation")
struct DayPostEmailGeneratorTests {
    @Test func generatesDaysAndPostsOldestFirst() {
        let newer = day(
            localDay: "2026-07-10",
            items: [item(text: "Second", date: date("2026-07-10T12:00:00Z")),
                    item(text: "First", date: date("2026-07-10T09:00:00Z"))]
        )
        let older = day(
            localDay: "2026-07-09",
            items: [item(text: "Previous day", date: date("2026-07-09T15:00:00Z"))]
        )

        let html = DayPostEmailGenerator().generate(days: [newer, older]).html

        #expect(html.range(of: "Previous day")!.lowerBound < html.range(of: "First")!.lowerBound)
        #expect(html.range(of: "First")!.lowerBound < html.range(of: "Second")!.lowerBound)
    }

    @Test func rendersTextOnlyPostsAndClickableEscapedURLs() {
        let post = item(text: "Read https://example.com/story?tea=1&cake=2 <today>")
        let draft = DayPostEmailGenerator().generate(days: [day(items: [post])])

        #expect(draft.html.contains("<a href=\"https://example.com/story?tea=1&amp;cake=2\">"))
        #expect(draft.previewHTML.contains("&lt;today&gt;"))
        #expect(!draft.html.contains("<today>"))
        #expect(draft.imageAttachments.isEmpty)
    }

    @Test func rendersEveryPhotoAndItsCaption() {
        let firstPath = temporaryImagePath(bytes: [0x01, 0x02])
        let secondPath = temporaryImagePath(bytes: [0x03, 0x04])
        defer {
            try? FileManager.default.removeItem(atPath: firstPath)
            try? FileManager.default.removeItem(atPath: secondPath)
        }
        let post = item(
            text: "Two photographs",
            photos: [
                photo(caption: "Harbour", path: firstPath, date: date("2026-07-10T09:00:00Z")),
                photo(caption: "Cliffs", path: secondPath, date: date("2026-07-10T10:00:00Z")),
            ]
        )

        let draft = DayPostEmailGenerator().generate(days: [day(items: [post])])

        #expect(draft.imageAttachments.count == 2)
        #expect(draft.html.contains("Harbour"))
        #expect(draft.html.contains("Cliffs"))
        #expect(draft.html.contains("cid:instablog-"))
        #expect(draft.previewHTML.contains("data:image/jpeg;base64,"))
    }

    @Test func collectorMergesDuplicateDaysAcrossTrips() {
        let calendar = Calendar(identifier: .gregorian)
        let first = item(text: "First")
        let second = item(text: "Second")
        let firstTrip = trip(days: [day(localDay: "2026-07-10", items: [first])])
        let secondTrip = trip(days: [day(localDay: "2026-07-10", items: [second])])

        let days = DayPostShareDayCollector.days(
            from: [firstTrip, secondTrip],
            startDate: date("2026-07-10T00:00:00Z"),
            endDate: date("2026-07-10T23:00:00Z"),
            calendar: calendar
        )

        #expect(days.count == 1)
        #expect(Set(days[0].blogItems.map(\.id)) == Set([first.id, second.id]))
    }

    private func day(
        localDay: String = "2026-07-10",
        items: [BlogItemDisplay]
    ) -> DayPostDisplay {
        DayPostDisplay(
            date: date("\(localDay)T12:00:00Z"),
            localDay: localDay,
            route: ["Whitby"],
            blogItems: items
        )
    }

    private func item(
        text: String,
        date: Date? = nil,
        photos: [PhotoItemDisplay] = []
    ) -> BlogItemDisplay {
        BlogItemDisplay(
            author: "Jane",
            date: date ?? self.date("2026-07-10T10:00:00Z"),
            timeZoneIdentifier: "UTC",
            blogText: text,
            location: "Whitby",
            weather: WeatherDisplay(temperatureCelsius: 18, conditionCode: "Clear"),
            photos: photos
        )
    }

    private func photo(caption: String, path: String, date: Date) -> PhotoItemDisplay {
        PhotoItemDisplay(
            date: date,
            caption: caption,
            availability: .available,
            localImagePath: path
        )
    }

    private func trip(days: [DayPostDisplay]) -> TripDisplay {
        TripDisplay(
            kind: .trip,
            title: "Trip",
            description: "",
            startLocalDay: "2026-07-10",
            endLocalDay: "2026-07-10",
            closedAt: Date(),
            days: days
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func temporaryImagePath(bytes: [UInt8]) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPostEmail-\(UUID().uuidString).jpg")
        try! Data(bytes).write(to: url)
        return url.path
    }
}
