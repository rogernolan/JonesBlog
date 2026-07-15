import CloudKit
import Foundation
import Testing
@testable import InstaBlog

@Suite("Temperature values")
struct TemperatureValueTests {
    @Test func constrainsAndRoundsValues() {
        #expect(TemperatureValue.normalized(72) == 60)
        #expect(TemperatureValue.normalized(-100) == -90)
        #expect(TemperatureValue.normalized(12.26) == 12.5)
        #expect(TemperatureValue.normalized(-12.26) == -12.5)
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
