#if DEBUG && !MIGRATION_EXPORT
import Foundation
import SQLiteData
import Testing

@testable import InstaBlog

@Suite("Development CloudKit schema bootstrap")
struct DevelopmentCloudKitSchemaBootstrapperTests {
    @Test func seedCoversEverySynchronizedRecordTypeAndOptionalField() async throws {
        let persistence = try AppPersistence.makeTesting()
        let database = persistence.database
        let ids = DevelopmentCloudKitSchemaBootstrapper.SeedIDs()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        try DevelopmentCloudKitSchemaBootstrapper.insertBlog(
            ids: ids,
            timestamp: timestamp,
            database: database
        )
        try DevelopmentCloudKitSchemaBootstrapper.insertDirectChildren(
            ids: ids,
            timestamp: timestamp,
            database: database
        )
        try DevelopmentCloudKitSchemaBootstrapper.insertDependentRecords(
            ids: ids,
            timestamp: timestamp,
            database: database
        )
        try DevelopmentCloudKitSchemaBootstrapper.insertLeafRecords(
            ids: ids,
            timestamp: timestamp,
            database: database
        )

        let snapshot = try await database.read { db in
            (
                Set(try SyncMetadata.all.fetchAll(db).map(\.recordType)),
                try Blogger.find(db, key: ids.blogger),
                try BlogItem.find(db, key: ids.blogItem),
                try MediaAsset.find(db, key: ids.mediaAsset),
                try PhotoItem.find(db, key: ids.photoItem),
                try Trip.find(db, key: ids.trip),
                try Subscriber.find(db, key: ids.subscriber),
                try PublishEvent.find(db, key: ids.publishEvent)
            )
        }
        persistence.syncEngine.stop()

        #expect(snapshot.0 == DevelopmentCloudKitSchemaBootstrapper.expectedRecordTypes)
        #expect(snapshot.1.cloudKitParticipantIdentifier != nil)

        let item = snapshot.2
        #expect(item.lastEditorID != nil)
        #expect(item.blogText != nil)
        #expect(item.lastEditedAt != nil)
        #expect(item.itemTimeZoneIdentifier != nil)
        #expect(item.latitude != nil)
        #expect(item.longitude != nil)
        #expect(item.locationName != nil)
        #expect(item.countryCode != nil)
        #expect(item.weatherTemperatureCelsius != nil)
        #expect(item.weatherConditionCode != nil)
        #expect(item.deletedAt != nil)

        let media = snapshot.3
        #expect(media.localOriginalPath != nil)
        #expect(media.photoLibraryAssetIdentifier != nil)
        #expect(media.photoLibraryAssetUploaderID != nil)
        #expect(media.cloudAssetIdentifier != nil)
        #expect(media.contentHash != nil)
        #expect(media.cloudAssetHash != nil)
        #expect(media.cloudAssetSyncError != nil)
        #expect(media.pixelWidth != nil)
        #expect(media.pixelHeight != nil)

        #expect(snapshot.4.photoCaption != nil)
        #expect(snapshot.5.endLocalDay != nil)
        #expect(snapshot.5.heroImageAssetID != nil)
        #expect(snapshot.5.closedAt != nil)
        #expect(snapshot.5.deletedAt != nil)
        #expect(snapshot.6.displayName != nil)
        #expect(snapshot.7.tripID != nil)
    }
}
#endif
