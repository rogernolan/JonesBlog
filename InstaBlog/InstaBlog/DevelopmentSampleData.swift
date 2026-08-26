import Foundation

nonisolated enum DevelopmentSampleData {
    static let firstRunSeed = FirstRunSeed(
        primaryBloggerDisplayName: "Rog",
        additionalBloggerDisplayNames: ["Jane"],
        tripTitle: "Provence by Train",
        tripDescription: "A sample journal used to exercise the SQLiteData-backed UI.",
        startLocalDay: "2026-06-19",
        endLocalDay: nil,
        items: [
            seedItem(
                author: "Rog",
                day: 19,
                hour: 9,
                minute: 12,
                blogText: "The first train south slipped past fields already bright with heat.",
                location: "Avignon Centre",
                temperature: 21,
                condition: "Clear",
                palette: .train
            ),
            seedItem(
                author: "Jane",
                day: 20,
                hour: 10,
                minute: 24,
                blogText: "The road opened into salt marshes, pale and bright under the morning sun.",
                location: "Camargue",
                temperature: 22,
                condition: "Sunny",
                palette: .saltMarsh
            ),
            seedItem(
                author: "Jane",
                day: 20,
                hour: 12,
                minute: 40,
                blogText: "We found a table beside the fishing boats.",
                location: "The Old Harbour",
                temperature: 23,
                condition: "Sunny",
                palette: .harbour
            ),
            seedItem(
                author: "Rog",
                day: 20,
                hour: 12,
                minute: 45,
                blogText: "The bouillabaisse arrived looking heroic.",
                location: "The Old Harbour",
                temperature: 23,
                condition: "Sunny",
                palette: .lunch
            ),
            seedItem(
                author: "Jane",
                day: 20,
                hour: 12,
                minute: 49,
                blogText: "Boats knocking softly against the quay.",
                location: "The Old Harbour",
                temperature: 23,
                condition: "Sunny",
                palette: .harbour
            ),
            seedItem(
                author: "Rog",
                day: 20,
                hour: 12,
                minute: 52,
                blogText: "One last coffee before the road west.",
                location: "The Old Harbour",
                temperature: 24,
                condition: "Sunny",
                palette: .lunch
            ),
            seedItem(
                author: "Rog",
                day: 20,
                hour: 16,
                minute: 5,
                blogText: "Flamingos gathering in the late light.",
                location: "Pont de Gau",
                temperature: 24,
                condition: "Mostly Sunny",
                palette: .flamingos
            ),
        ]
    )

    static let elevationUITestSeed: FirstRunSeed = {
        guard let firstItem = firstRunSeed.items.first else { return firstRunSeed }
        let elevationItem = FirstRunBlogItemSeed(
            authorDisplayName: firstItem.authorDisplayName,
            date: firstItem.date,
            timeZoneIdentifier: firstItem.timeZoneIdentifier,
            localDay: firstItem.localDay,
            blogText: firstItem.blogText,
            locationName: firstItem.locationName,
            countryCode: firstItem.countryCode,
            weatherTemperatureCelsius: firstItem.weatherTemperatureCelsius,
            weatherConditionCode: firstItem.weatherConditionCode,
            photoFilenames: firstItem.photoFilenames,
            altitude: 650,
            showElevation: false
        )
        return FirstRunSeed(
            primaryBloggerDisplayName: firstRunSeed.primaryBloggerDisplayName,
            additionalBloggerDisplayNames: firstRunSeed.additionalBloggerDisplayNames,
            tripTitle: firstRunSeed.tripTitle,
            tripDescription: firstRunSeed.tripDescription,
            startLocalDay: firstRunSeed.startLocalDay,
            endLocalDay: firstRunSeed.endLocalDay,
            items: [elevationItem]
        )
    }()

    static let emptyCurrentTripUITestSeed = FirstRunSeed(
        primaryBloggerDisplayName: firstRunSeed.primaryBloggerDisplayName,
        additionalBloggerDisplayNames: firstRunSeed.additionalBloggerDisplayNames,
        tripTitle: firstRunSeed.tripTitle,
        tripDescription: firstRunSeed.tripDescription,
        startLocalDay: firstRunSeed.startLocalDay,
        endLocalDay: firstRunSeed.endLocalDay,
        items: []
    )

    static let historicalTripUITestSeed = FirstRunSeed(
        primaryBloggerDisplayName: firstRunSeed.primaryBloggerDisplayName,
        additionalBloggerDisplayNames: firstRunSeed.additionalBloggerDisplayNames,
        tripTitle: firstRunSeed.tripTitle,
        tripDescription: firstRunSeed.tripDescription,
        startLocalDay: firstRunSeed.startLocalDay,
        endLocalDay: "2026-06-20",
        items: firstRunSeed.items
    )

    static let galleryUITestSeed: FirstRunSeed = {
        var items = firstRunSeed.items
        guard let lastItem = items.popLast() else { return firstRunSeed }
        items.append(
            FirstRunBlogItemSeed(
                authorDisplayName: lastItem.authorDisplayName,
                date: lastItem.date,
                timeZoneIdentifier: lastItem.timeZoneIdentifier,
                localDay: lastItem.localDay,
                blogText: lastItem.blogText,
                locationName: lastItem.locationName,
                countryCode: lastItem.countryCode,
                weatherTemperatureCelsius: lastItem.weatherTemperatureCelsius,
                weatherConditionCode: lastItem.weatherConditionCode,
                photoFilenames: ["flamingos.jpg", "harbour.jpg"]
            )
        )
        return FirstRunSeed(
            primaryBloggerDisplayName: firstRunSeed.primaryBloggerDisplayName,
            additionalBloggerDisplayNames: firstRunSeed.additionalBloggerDisplayNames,
            tripTitle: firstRunSeed.tripTitle,
            tripDescription: firstRunSeed.tripDescription,
            startLocalDay: firstRunSeed.startLocalDay,
            endLocalDay: firstRunSeed.endLocalDay,
            items: items
        )
    }()

    static let linkedPostsUITestSeed = FirstRunSeed(
        primaryBloggerDisplayName: firstRunSeed.primaryBloggerDisplayName,
        additionalBloggerDisplayNames: firstRunSeed.additionalBloggerDisplayNames,
        tripTitle: firstRunSeed.tripTitle,
        tripDescription: firstRunSeed.tripDescription,
        startLocalDay: firstRunSeed.startLocalDay,
        endLocalDay: firstRunSeed.endLocalDay,
        items: [
            seedItem(
                author: "Rog",
                day: 20,
                hour: 16,
                minute: 5,
                blogText: "Journal link test: https://example.com/journal",
                location: "Pont de Gau",
                temperature: 24,
                condition: "Mostly Sunny",
                palette: .flamingos
            )
        ]
    )

    static let inlineEditingUITestSeed = FirstRunSeed(
        primaryBloggerDisplayName: firstRunSeed.primaryBloggerDisplayName,
        additionalBloggerDisplayNames: firstRunSeed.additionalBloggerDisplayNames,
        tripTitle: firstRunSeed.tripTitle,
        tripDescription: firstRunSeed.tripDescription,
        startLocalDay: firstRunSeed.startLocalDay,
        endLocalDay: firstRunSeed.endLocalDay,
        items: [
            seedItem(
                author: "Jane",
                day: 20,
                hour: 15,
                minute: 30,
                blogText: "Salt flats stretching to the horizon.",
                location: "Camargue",
                temperature: 23,
                condition: "Sunny",
                palette: .saltMarsh
            ),
            seedTextOnlyItem(
                author: "Rog",
                day: 20,
                hour: 16,
                minute: 5,
                blogText: "Flamingos gathering in the late light.",
                location: "Pont de Gau",
                temperature: 24,
                condition: "Mostly Sunny"
            )
        ]
    )

    // Seeds one entry for the current local day so the Share screen's default
    // "Today" range has content for the share-email UI test.
    static let shareEmailUITestSeed: FirstRunSeed = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: DevelopmentSampleData.uiTestingReferenceDate ?? Date())
        let itemDate = calendar.date(byAdding: .hour, value: 12, to: today) ?? today
        let localDay = JournalDayProgress.localDay(from: itemDate)
        let item = FirstRunBlogItemSeed(
            authorDisplayName: firstRunSeed.primaryBloggerDisplayName,
            date: itemDate,
            timeZoneIdentifier: TimeZone.current.identifier,
            localDay: localDay,
            blogText: "A quiet morning in the harbour before the day's notes.",
            locationName: "Avignon Centre",
            countryCode: "FR",
            weatherTemperatureCelsius: 21,
            weatherConditionCode: "Clear",
            photoFilenames: ["train.jpg"]
        )
        return FirstRunSeed(
            primaryBloggerDisplayName: firstRunSeed.primaryBloggerDisplayName,
            additionalBloggerDisplayNames: firstRunSeed.additionalBloggerDisplayNames,
            tripTitle: firstRunSeed.tripTitle,
            tripDescription: firstRunSeed.tripDescription,
            startLocalDay: localDay,
            endLocalDay: localDay,
            items: [item]
        )
    }()

    // Preview-only values mirror the first-run SQLiteData seed.
    static let currentTrip = TripDisplay(
        title: "Provence by Train",
        days: [previousDay, currentDay]
    )

    private static let previousDay = DayPostDisplay(
        date: date(year: 2026, month: 6, day: 19, hour: 9),
        route: ["Avignon", "Arles"],
        blogItems: [
            sampleDisplayItem(
                author: "Rog",
                date: date(year: 2026, month: 6, day: 19, hour: 9, minute: 12),
                blogText: "The first train south slipped past fields already bright with heat.",
                location: "Avignon Centre",
                temperature: 21,
                condition: "Clear",
                systemImage: "sun.max.fill",
                palette: .train
            )
        ]
    )

    private static let currentDay: DayPostDisplay = {
        let marsh = sampleDisplayItem(
            author: "Jane",
            date: date(year: 2026, month: 6, day: 20, hour: 10, minute: 24),
            blogText: "The road opened into salt marshes, pale and bright under the morning sun.",
            location: "Camargue",
            temperature: 22,
            condition: "Sunny",
            systemImage: "sun.max.fill",
            palette: .saltMarsh
        )

        let harbourItems = [
            sampleDisplayItem(
                author: "Jane",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 40),
                blogText: "We found a table beside the fishing boats.",
                location: "The Old Harbour",
                temperature: 23,
                condition: "Sunny",
                systemImage: "sun.max.fill",
                palette: .harbour
            ),
            sampleDisplayItem(
                author: "Rog",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 45),
                blogText: "The bouillabaisse arrived looking heroic.",
                location: "The Old Harbour",
                temperature: 23,
                condition: "Sunny",
                systemImage: "sun.max.fill",
                palette: .lunch,
                syncStatus: .pending
            ),
            sampleDisplayItem(
                author: "Jane",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 49),
                blogText: "Boats knocking softly against the quay.",
                location: "The Old Harbour",
                temperature: 23,
                condition: "Sunny",
                systemImage: "sun.max.fill",
                palette: .harbour
            ),
            sampleDisplayItem(
                author: "Rog",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 52),
                blogText: "One last coffee before the road west.",
                location: "The Old Harbour",
                temperature: 24,
                condition: "Sunny",
                systemImage: "sun.max.fill",
                palette: .lunch
            )
        ]

        let flamingos = sampleDisplayItem(
            author: "Rog",
            date: date(year: 2026, month: 6, day: 20, hour: 16, minute: 5),
            blogText: "Flamingos gathering in the late light.",
            location: "Pont de Gau",
            temperature: 24,
            condition: "Mostly Sunny",
            systemImage: "sun.haze.fill",
            palette: .flamingos,
            syncStatus: .failed
        )

        return DayPostDisplay(
            date: date(year: 2026, month: 6, day: 20, hour: 8),
            route: ["Arles", "Saintes-Maries-de-la-Mer"],
            blogItems: [marsh] + harbourItems + [flamingos]
        )
    }()

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Europe/Paris")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date ?? .distantPast
    }

    private static func seedItem(
        author: String,
        day: Int,
        hour: Int,
        minute: Int,
        blogText: String,
        location: String,
        temperature: Double,
        condition: String,
        palette: JournalPalette
    ) -> FirstRunBlogItemSeed {
        FirstRunBlogItemSeed(
            authorDisplayName: author,
            date: date(year: 2026, month: 6, day: day, hour: hour, minute: minute),
            timeZoneIdentifier: "Europe/Paris",
            localDay: String(format: "2026-06-%02d", day),
            blogText: blogText,
            locationName: location,
            countryCode: "FR",
            weatherTemperatureCelsius: temperature,
            weatherConditionCode: condition,
            photoFilenames: ["\(palette.rawValue).jpg"]
        )
    }

    private static func seedTextOnlyItem(
        author: String,
        day: Int,
        hour: Int,
        minute: Int,
        blogText: String,
        location: String,
        temperature: Double,
        condition: String
    ) -> FirstRunBlogItemSeed {
        FirstRunBlogItemSeed(
            authorDisplayName: author,
            date: date(year: 2026, month: 6, day: day, hour: hour, minute: minute),
            timeZoneIdentifier: "Europe/Paris",
            localDay: String(format: "2026-06-%02d", day),
            blogText: blogText,
            locationName: location,
            countryCode: "FR",
            weatherTemperatureCelsius: temperature,
            weatherConditionCode: condition,
            photoFilenames: []
        )
    }

    private static func sampleDisplayItem(
        author: String,
        date: Date,
        blogText: String,
        location: String,
        temperature: Double,
        condition: String,
        systemImage: String,
        palette: JournalPalette,
        syncStatus: BlogItemSyncStatus = .synced
    ) -> BlogItemDisplay {
        BlogItemDisplay(
            author: author,
            date: date,
            timeZoneIdentifier: "Europe/Paris",
            blogText: blogText,
            location: location,
            weather: WeatherDisplay(
                temperatureCelsius: temperature,
                condition: condition,
                systemImage: systemImage
            ),
            photos: [PhotoItemDisplay(date: date, palette: palette)],
            syncStatus: syncStatus
        )
    }

    static var uiTestingReferenceDate: Date? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-ui-testing-reference-date"),
              args.indices.contains(idx + 1) else { return nil }
        return ISO8601DateFormatter().date(from: args[idx + 1])
    }
}
