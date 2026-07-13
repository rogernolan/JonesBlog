import Foundation

enum DevelopmentSampleData {
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
                caption: "The first train south slipped past fields already bright with heat.",
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
                caption: "The road opened into salt marshes, pale and bright under the morning sun.",
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
                caption: "We found a table beside the fishing boats.",
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
                caption: "The bouillabaisse arrived looking heroic.",
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
                caption: "Boats knocking softly against the quay.",
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
                caption: "One last coffee before the road west.",
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
                caption: "Flamingos gathering in the late light.",
                location: "Pont de Gau",
                temperature: 24,
                condition: "Mostly Sunny",
                palette: .flamingos
            ),
        ]
    )

    // Preview-only values mirror the first-run SQLiteData seed.
    static let currentTrip = TripDisplay(
        title: "Provence by Train",
        days: [previousDay, currentDay]
    )

    private static let previousDay = DayPostDisplay(
        date: date(year: 2026, month: 6, day: 19, hour: 9),
        route: ["Avignon", "Arles"],
        entries: [
            .blogItem(
                BlogItemDisplay(
                    author: "Rog",
                    date: date(year: 2026, month: 6, day: 19, hour: 9, minute: 12),
                    timeZoneIdentifier: "Europe/Paris",
                    caption: "The first train south slipped past fields already bright with heat.",
                    location: "Avignon Centre",
                    weather: WeatherDisplay(
                        temperatureCelsius: 21,
                        condition: "Clear",
                        systemImage: "sun.max.fill"
                    ),
                    palette: .train
                )
            )
        ]
    )

    private static let currentDay: DayPostDisplay = {
        let marsh = BlogItemDisplay(
            author: "Jane",
            date: date(year: 2026, month: 6, day: 20, hour: 10, minute: 24),
            timeZoneIdentifier: "Europe/Paris",
            caption: "The road opened into salt marshes, pale and bright under the morning sun.",
            location: "Camargue",
            weather: WeatherDisplay(
                temperatureCelsius: 22,
                condition: "Sunny",
                systemImage: "sun.max.fill"
            ),
            palette: .saltMarsh
        )

        let galleryItems = [
            BlogItemDisplay(
                author: "Jane",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 40),
                timeZoneIdentifier: "Europe/Paris",
                caption: "We found a table beside the fishing boats.",
                location: "The Old Harbour",
                weather: WeatherDisplay(
                    temperatureCelsius: 23,
                    condition: "Sunny",
                    systemImage: "sun.max.fill"
                ),
                palette: .harbour
            ),
            BlogItemDisplay(
                author: "Rog",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 45),
                timeZoneIdentifier: "Europe/Paris",
                caption: "The bouillabaisse arrived looking heroic.",
                location: "The Old Harbour",
                weather: WeatherDisplay(
                    temperatureCelsius: 23,
                    condition: "Sunny",
                    systemImage: "sun.max.fill"
                ),
                palette: .lunch,
                syncStatus: .pending
            ),
            BlogItemDisplay(
                author: "Jane",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 49),
                timeZoneIdentifier: "Europe/Paris",
                caption: "Boats knocking softly against the quay.",
                location: "The Old Harbour",
                weather: WeatherDisplay(
                    temperatureCelsius: 23,
                    condition: "Sunny",
                    systemImage: "sun.max.fill"
                ),
                palette: .harbour
            ),
            BlogItemDisplay(
                author: "Rog",
                date: date(year: 2026, month: 6, day: 20, hour: 12, minute: 52),
                timeZoneIdentifier: "Europe/Paris",
                caption: "One last coffee before the road west.",
                location: "The Old Harbour",
                weather: WeatherDisplay(
                    temperatureCelsius: 24,
                    condition: "Sunny",
                    systemImage: "sun.max.fill"
                ),
                palette: .lunch
            )
        ]

        let gallery = GalleryDisplay(
            title: "The Old Harbour",
            location: "Marseille",
            items: galleryItems
        )

        let flamingos = BlogItemDisplay(
            author: "Rog",
            date: date(year: 2026, month: 6, day: 20, hour: 16, minute: 5),
            timeZoneIdentifier: "Europe/Paris",
            caption: "Flamingos gathering in the late light.",
            location: "Pont de Gau",
            weather: WeatherDisplay(
                temperatureCelsius: 24,
                condition: "Mostly Sunny",
                systemImage: "sun.haze.fill"
            ),
            palette: .flamingos,
            syncStatus: .failed
        )

        return DayPostDisplay(
            date: date(year: 2026, month: 6, day: 20, hour: 8),
            route: ["Arles", "Saintes-Maries-de-la-Mer"],
            entries: [.blogItem(marsh), .gallery(gallery), .blogItem(flamingos)]
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
        caption: String,
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
            caption: caption,
            locationName: location,
            countryCode: "FR",
            weatherTemperatureCelsius: temperature,
            weatherConditionCode: condition,
            photoFilename: "\(palette.rawValue).jpg"
        )
    }
}
