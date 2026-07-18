import CloudKit
import Foundation
import Testing
@testable import InstaBlog

@Suite("Temperature values")
struct TemperatureValueTests {
    @Test func constrainsAndRoundsValues() {
        #expect(TemperatureValue.normalized(72) == 60)
        #expect(TemperatureValue.normalized(-101) == -100)
        #expect(TemperatureValue.normalized(-100) == -100)
        #expect(TemperatureValue.normalized(12.26) == 12.5)
        #expect(TemperatureValue.normalized(-12.26) == -12.5)
    }

    @Test func constrainsEditableTextToTwoIntegerDigitsAndOneDecimalPlace() {
        #expect(TemperatureText.constrained("12.3") == "12.3")
        #expect(TemperatureText.constrained("-9.5") == "-9.5")
        #expect(TemperatureText.constrained("12.26") == "12.5")
        #expect(TemperatureText.constrained("100") == "60")
        #expect(TemperatureText.constrained("-100") == "-100")
        #expect(TemperatureText.constrained("1a.2b") == "1.2")
    }
}

@Suite("Photo caption text")
struct PhotoCaptionTextTests {
    @Test func ignoresAKeyboardReturn() {
        #expect(PhotoCaptionText.updating("First", with: "First\n") == "First")
        #expect(PhotoCaptionText.updating("FirstSecond", with: "First\nSecond") == "FirstSecond")
    }

    @Test func replacesPastedNewlinesWithSpaces() {
        #expect(PhotoCaptionText.updating("", with: "First\nSecond") == "First Second")
        #expect(PhotoCaptionText.updating("", with: "First\r\nSecond") == "First Second")
        #expect(PhotoCaptionText.updating("", with: "First\u{2028}Second") == "First Second")
    }

    @Test func preservesOrdinaryCaptionText() {
        #expect(PhotoCaptionText.singleLine("A day at the coast") == "A day at the coast")
    }
}

@Suite("BlogItem sync status")
struct BlogItemSyncStatusTests {
    @Test func unsharedItemIsStoredLocally() {
        #expect(BlogItemSyncStatus.resolve(record: .pending, media: .pending, isShared: false) == .storedLocally)
    }

    @Test func failuresAndPendingDependenciesAggregate() {
        #expect(BlogItemSyncStatus.resolve(record: .failed, media: .pending) == .failed)
        #expect(BlogItemSyncStatus.resolve(record: .pending, media: .synced) == .pending)
        #expect(BlogItemSyncStatus.resolve(record: .synced, media: .notRequired) == .synced)
    }
}

@Suite("External media sync status")
struct ExternalMediaSyncStatusTests {
    @Test func requiresMatchingRemoteIdentifierAndHash() {
        var asset = mediaAsset()
        #expect(asset.externalSyncState == .pending)

        asset.cloudAssetIdentifier = "remote-object"
        asset.cloudAssetHash = asset.contentHash
        #expect(asset.externalSyncState == .synced)

        asset.cloudAssetIdentifier = nil
        asset.cloudAssetSyncError = "Network unavailable"
        #expect(asset.externalSyncState == .failed)
    }

    private func mediaAsset() -> MediaAsset {
        MediaAsset(
            id: UUID(),
            blogID: UUID(),
            localOriginalPath: "abc.jpg",
            contentHash: "abc",
            filename: "abc.jpg",
            mimeType: "image/jpeg",
            createdAt: .now,
            updatedAt: .now
        )
    }
}

@Suite("External media CloudKit records")
struct ExternalMediaCloudKitRecordTests {
    @Test func parentReferenceUsesCloudKitRequiredNoneAction() {
        let parent = CKRecord(recordType: "mediaAssets")
        let reference = MediaAssetSyncService.parentReference(for: parent)
        #expect(reference.action == .none)
        #expect(reference.recordID == parent.recordID)
    }
}

@Suite("BlogItem date policy")
struct BlogItemDatePolicyTests {
    @Test func rejectsOnlyFutureDates() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(BlogItemDatePolicy.allows(now, relativeTo: now))
        #expect(BlogItemDatePolicy.allows(now.addingTimeInterval(-1), relativeTo: now))
        #expect(!BlogItemDatePolicy.allows(now.addingTimeInterval(1), relativeTo: now))
    }
}

@Suite("BlogItem local time")
struct BlogItemLocalTimeTests {
    @Test func formatsTimeUsingTheStoredTimezone() {
        let date = ISO8601DateFormatter().date(from: "2026-07-10T12:00:00Z")!
        let item = BlogItemDisplay(
            author: "Jane",
            date: date,
            timeZoneIdentifier: "America/New_York",
            blogText: "Post",
            location: "New York",
            weather: WeatherDisplay()
        )

        #expect(item.localTimeText(locale: Locale(identifier: "en_GB")) == "08:00")
    }
}

@Suite("Journal presentation caching")
struct JournalPresentationCachingTests {
    @Test func reusesLinkificationForUnchangedText() {
        PostTextLinkifier.resetCacheForTesting()

        _ = PostTextLinkifier.attributedString("Read https://example.com/trip")
        _ = PostTextLinkifier.attributedString("Read https://example.com/trip")

        #expect(PostTextLinkifier.cacheMetrics.detectorRuns == 1)
        #expect(PostTextLinkifier.cacheMetrics.cacheHits == 1)
    }

    @Test func linksOnlyHTTPAndHTTPSURLs() {
        let text = "Safe https://example.com and unsafe ftp://example.com"
        let attributed = PostTextLinkifier.attributedString(text)
        let runs = attributed.runs

        #expect(runs.contains { $0.link?.scheme == "https" })
        #expect(!runs.contains { $0.link?.scheme == "ftp" })
    }

    @Test func reusesDatePresentationUntilTheRelativeDayChanges() {
        BlogItemDatePresentationCache.resetForTesting()
        let item = makeItem(date: "2026-07-10T22:30:00Z", timeZoneIdentifier: "Europe/London")
        let sameDay = date("2026-07-10T22:45:00Z")
        let nextDay = date("2026-07-10T23:15:00Z")

        #expect(item.metadataDateTimeText(relativeTo: sameDay, locale: Locale(identifier: "en_GB")) == "Today, 23:30")
        #expect(item.metadataDateTimeText(relativeTo: sameDay, locale: Locale(identifier: "en_GB")) == "Today, 23:30")
        #expect(item.metadataDateTimeText(relativeTo: nextDay, locale: Locale(identifier: "en_GB")) == "Yesterday, 23:30")
        #expect(BlogItemDatePresentationCache.cacheMetrics.cacheHits == 1)
        #expect(BlogItemDatePresentationCache.cacheMetrics.cacheMisses == 2)
    }

    @Test func datePresentationRespectsLocaleAndStoredTimeZone() {
        let item = makeItem(date: "2026-07-10T12:00:00Z", timeZoneIdentifier: "America/New_York")
        let now = date("2026-07-12T12:00:00Z")

        let british = item.metadataDateTimeText(relativeTo: now, locale: Locale(identifier: "en_GB"))
        let american = item.metadataDateTimeText(relativeTo: now, locale: Locale(identifier: "en_US"))

        #expect(british.contains("08:00"))
        #expect(american.contains("08:00"))
        #expect(british != american)
    }

    private func makeItem(date value: String, timeZoneIdentifier: String) -> BlogItemDisplay {
        BlogItemDisplay(
            author: "Rog",
            date: date(value),
            timeZoneIdentifier: timeZoneIdentifier,
            blogText: "Post",
            location: "York",
            weather: WeatherDisplay()
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

@Suite("Trip title transition")
struct TripTitleTransitionTests {
    @Test func progressClampsAtBothEnds() {
        #expect(TripTitleTransition.progress(scrollOffset: -10, collapseDistance: 100) == 0)
        #expect(TripTitleTransition.progress(scrollOffset: 50, collapseDistance: 100) == 0.5)
        #expect(TripTitleTransition.progress(scrollOffset: 150, collapseDistance: 100) == 1)
    }
}

@Suite("Day post model")
struct DayPostDisplayTests {
    @Test func directlyContainsBlogItems() {
        let item = BlogItemDisplay(
            author: "Jane",
            date: .now,
            blogText: "Direct post",
            location: "York",
            weather: WeatherDisplay()
        )
        let day = DayPostDisplay(date: .now, route: ["York"], blogItems: [item])

        #expect(day.blogItems == [item])
        #expect(day.routeBreadcrumb == "York")
    }
}
