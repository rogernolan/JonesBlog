import Foundation
import Testing
@testable import InstaBlog

@Suite("BlogItem sync status")
struct BlogItemSyncStatusTests {
    @Test("A failed record takes precedence over pending media")
    func failedRecordTakesPrecedence() {
        let status = BlogItemSyncStatus.resolve(
            record: .failed,
            media: .pending
        )

        #expect(status == .failed)
    }

    @Test("Failed media takes precedence over a pending record")
    func failedMediaTakesPrecedence() {
        let status = BlogItemSyncStatus.resolve(
            record: .pending,
            media: .failed
        )

        #expect(status == .failed)
    }

    @Test("Either pending dependency makes the BlogItem pending")
    func pendingDependencyMakesItemPending() {
        #expect(BlogItemSyncStatus.resolve(record: .pending, media: .synced) == .pending)
        #expect(BlogItemSyncStatus.resolve(record: .synced, media: .pending) == .pending)
    }

    @Test("A text-only BlogItem can be fully synced without media")
    func missingMediaCanBeSynced() {
        let status = BlogItemSyncStatus.resolve(
            record: .synced,
            media: .notRequired
        )

        #expect(status == .synced)
    }
}

@Suite("BlogItem date policy")
struct BlogItemDatePolicyTests {
    @Test("Past and present dates are allowed")
    func pastAndPresentDatesAreAllowed() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(BlogItemDatePolicy.allows(now, relativeTo: now))
        #expect(BlogItemDatePolicy.allows(now.addingTimeInterval(-1), relativeTo: now))
    }

    @Test("Future dates are rejected")
    func futureDatesAreRejected() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(!BlogItemDatePolicy.allows(now.addingTimeInterval(1), relativeTo: now))
    }
}

@Suite("BlogItem local time")
struct BlogItemLocalTimeTests {
    @Test("Time is formatted in the BlogItem timezone")
    func formatsStoredLocalTime() {
        let date = Date(timeIntervalSince1970: 1_781_943_840)
        let item = BlogItemDisplay(
            author: "Jane",
            date: date,
            timeZoneIdentifier: "Europe/Paris",
            caption: "",
            location: "Arles",
            weather: WeatherDisplay(temperatureCelsius: 22, condition: "Sunny", systemImage: "sun.max.fill"),
            palette: nil
        )

        #expect(item.localTimeText(locale: Locale(identifier: "en_GB")) == "10:24")
    }
}

@Suite("Trip title transition")
struct TripTitleTransitionTests {
    @Test("Progress follows the scroll distance and clamps at both ends")
    func progressTracksScrollDistance() {
        #expect(TripTitleTransition.progress(scrollOffset: -12, collapseDistance: 64) == 0)
        #expect(TripTitleTransition.progress(scrollOffset: 32, collapseDistance: 64) == 0.5)
        #expect(TripTitleTransition.progress(scrollOffset: 80, collapseDistance: 64) == 1)
    }
}

@Suite("iPhone tab selection highlight")
struct IPhoneTabSelectionHighlightTests {
    @Test("Destination slots leave the centre compose slot clear")
    func tabsMapAroundComposeSlot() {
        #expect(IPhoneTab.journal.tabBarSlot == 0)
        #expect(IPhoneTab.trips.tabBarSlot == 1)
        #expect(IPhoneTab.search.tabBarSlot == 3)
        #expect(IPhoneTab.settings.tabBarSlot == 4)
    }
}
