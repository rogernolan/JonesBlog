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
}
