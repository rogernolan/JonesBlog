#if DEBUG
import CloudKit
import Foundation
import GRDB
import SQLiteData

nonisolated enum DevelopmentCloudKitSchemaBootstrapper {
    static let launchArgument = "-bootstrap-development-cloudkit-schema"
    static let zoneName = "com.jonesthevan.blog.InstaBlog.schemaBootstrap.v1"
    static let expectedRecordTypes: Set<String> = [
        "blogItems",
        "bloggers",
        "blogs",
        "mailingLists",
        "mediaAssets",
        "photoItems",
        "publishEvents",
        "subscribers",
        "trips",
    ]

    struct Result: Equatable, Sendable {
        let recordTypes: Set<String>
        let deletedZoneName: String
    }

    struct SeedIDs: Sendable {
        let blog = UUID()
        let blogger = UUID()
        let blogItem = UUID()
        let mediaAsset = UUID()
        let photoItem = UUID()
        let trip = UUID()
        let mailingList = UUID()
        let subscriber = UUID()
        let publishEvent = UUID()
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func run(fileManager: FileManager = .default) async throws -> Result {
        guard AppBuildVariant.current == .debug,
              AppRuntimeEnvironment.current.cloudKitEnvironment == .development
        else {
            throw BootstrapError.developmentBuildRequired
        }
        guard let containerIdentifier = AppCloudKitConfiguration.containerIdentifier else {
            throw BootstrapError.missingContainer
        }

        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("InstaBlogSchemaBootstrap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let zone = CKRecordZone(zoneName: zoneName)
        let container = CKContainer(identifier: containerIdentifier)
        var database: (any DatabaseWriter)?
        var persistence: AppPersistence?

        do {
            let openedDatabase = try AppDatabase.makeLive(in: rootURL)
            database = openedDatabase
            let openedPersistence = try AppPersistence(
                database: openedDatabase,
                containerIdentifier: containerIdentifier,
                defaultZone: zone,
                startImmediately: false
            )
            persistence = openedPersistence
            let ids = SeedIDs()
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

            try insertBlog(ids: ids, timestamp: timestamp, database: openedDatabase)
            try await openedPersistence.syncEngine.start()
            _ = try await sendUntilUploaded(
                expectedRecordTypes: ["blogs"],
                persistence: openedPersistence
            )

            try insertDirectChildren(ids: ids, timestamp: timestamp, database: openedDatabase)
            _ = try await sendUntilUploaded(
                expectedRecordTypes: ["blogs", "bloggers", "mediaAssets", "mailingLists"],
                persistence: openedPersistence
            )

            try insertDependentRecords(ids: ids, timestamp: timestamp, database: openedDatabase)
            _ = try await sendUntilUploaded(
                expectedRecordTypes: [
                    "blogs", "bloggers", "mediaAssets", "mailingLists",
                    "blogItems", "trips", "subscribers",
                ],
                persistence: openedPersistence
            )

            try insertLeafRecords(ids: ids, timestamp: timestamp, database: openedDatabase)
            let uploadedTypes = try await sendUntilUploaded(
                expectedRecordTypes: expectedRecordTypes,
                persistence: openedPersistence
            )

            openedPersistence.syncEngine.stop()
            persistence = nil
            try openedDatabase.close()
            database = nil
            try await deleteBootstrapZone(zone.zoneID, from: container.privateCloudDatabase)
            try fileManager.removeItem(at: rootURL)
            return Result(recordTypes: uploadedTypes, deletedZoneName: zone.zoneID.zoneName)
        } catch {
            persistence?.syncEngine.stop()
            persistence = nil
            try? database?.close()
            try? await deleteBootstrapZone(zone.zoneID, from: container.privateCloudDatabase)
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    static func insertBlog(
        ids: SeedIDs,
        timestamp: Date,
        database: any DatabaseWriter
    ) throws {
        try database.write { db in
            try Blog.insert {
                Blog.Draft(
                    id: ids.blog,
                    title: "Schema Bootstrap",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }.execute(db)
        }
    }

    static func insertDirectChildren(
        ids: SeedIDs,
        timestamp: Date,
        database: any DatabaseWriter
    ) throws {
        try database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    id: ids.blogger,
                    blogID: ids.blog,
                    displayName: "Schema Bootstrap",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    cloudKitParticipantIdentifier: "schema-participant"
                )
            }.execute(db)
            try MediaAsset.insert {
                MediaAsset.Draft(
                    id: ids.mediaAsset,
                    blogID: ids.blog,
                    kind: "photo",
                    localOriginalPath: "schema-bootstrap.jpg",
                    photoLibraryAssetIdentifier: "schema-library-asset",
                    photoLibraryAssetUploaderID: ids.blogger,
                    cloudAssetIdentifier: "schema-cloud-asset",
                    contentHash: "schema-content-hash",
                    cloudAssetHash: "schema-cloud-hash",
                    cloudAssetSyncError: "schema-error",
                    filename: "schema-bootstrap.jpg",
                    mimeType: "image/jpeg",
                    pixelWidth: 1,
                    pixelHeight: 1,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }.execute(db)
            try MailingList.insert {
                MailingList.Draft(
                    id: ids.mailingList,
                    blogID: ids.blog,
                    name: "Schema Bootstrap",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }.execute(db)
        }
    }

    static func insertDependentRecords(
        ids: SeedIDs,
        timestamp: Date,
        database: any DatabaseWriter
    ) throws {
        try database.write { db in
            try BlogItem.insert {
                BlogItem.Draft(
                    id: ids.blogItem,
                    blogID: ids.blog,
                    authorID: ids.blogger,
                    lastEditorID: ids.blogger,
                    blogText: "Schema Bootstrap",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    lastEditedAt: timestamp,
                    itemDate: timestamp,
                    itemTimeZoneIdentifier: "UTC",
                    localDay: "2027-01-15",
                    latitude: 1,
                    longitude: 1,
                    locationName: "Schema Bootstrap",
                    countryCode: "GB",
                    weatherTemperatureCelsius: 1,
                    weatherConditionCode: "Clear",
                    deletedAt: timestamp
                )
            }.execute(db)
            try Trip.insert {
                Trip.Draft(
                    id: ids.trip,
                    blogID: ids.blog,
                    title: "Schema Bootstrap",
                    description: "Schema Bootstrap",
                    startLocalDay: "2027-01-15",
                    endLocalDay: "2027-01-16",
                    heroImageAssetID: ids.mediaAsset,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    closedAt: timestamp,
                    deletedAt: timestamp
                )
            }.execute(db)
            try Subscriber.insert {
                Subscriber.Draft(
                    id: ids.subscriber,
                    blogID: ids.blog,
                    mailingListID: ids.mailingList,
                    emailAddress: "schema@example.com",
                    displayName: "Schema Bootstrap",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }.execute(db)
        }
    }

    static func insertLeafRecords(
        ids: SeedIDs,
        timestamp: Date,
        database: any DatabaseWriter
    ) throws {
        try database.write { db in
            try PhotoItem.insert {
                PhotoItem.Draft(
                    id: ids.photoItem,
                    blogID: ids.blog,
                    blogItemID: ids.blogItem,
                    mediaAssetID: ids.mediaAsset,
                    photoCaption: "Schema Bootstrap",
                    photoDate: timestamp,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }.execute(db)
            try PublishEvent.insert {
                PublishEvent.Draft(
                    id: ids.publishEvent,
                    blogID: ids.blog,
                    tripID: ids.trip,
                    localDay: "2027-01-15",
                    mailingListID: ids.mailingList,
                    initiatedAt: timestamp,
                    initiatedByBloggerID: ids.blogger,
                    recipientCount: 1
                )
            }.execute(db)
        }
    }

    private static func sendUntilUploaded(
        expectedRecordTypes: Set<String>,
        persistence: AppPersistence
    ) async throws -> Set<String> {
        var lastError: (any Error)?
        for attempt in 0..<10 {
            do {
                try await persistence.syncEngine.sendChanges()
                lastError = nil
            } catch {
                lastError = error
            }

            let uploadedTypes = try await persistence.database.read { db in
                Set(
                    try SyncMetadata
                        .where(\.hasLastKnownServerRecord)
                        .fetchAll(db)
                        .map(\.recordType)
                )
            }
            if expectedRecordTypes.isSubset(of: uploadedTypes) {
                return uploadedTypes
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        if let lastError { throw lastError }
        throw BootstrapError.missingRecordTypes(expectedRecordTypes)
    }

    private static func deleteBootstrapZone(
        _ zoneID: CKRecordZone.ID,
        from database: CKDatabase
    ) async throws {
        let results = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        for result in results.deleteResults.values {
            _ = try result.get()
        }
    }

    enum BootstrapError: LocalizedError {
        case developmentBuildRequired
        case missingContainer
        case missingRecordTypes(Set<String>)

        var errorDescription: String? {
            switch self {
            case .developmentBuildRequired:
                "Schema bootstrap requires the ordinary Debug build and Development CloudKit."
            case .missingContainer:
                "The CloudKit container identifier is missing."
            case .missingRecordTypes(let recordTypes):
                "CloudKit did not accept all schema record types: \(recordTypes.sorted().joined(separator: ", "))."
            }
        }
    }
}
#endif
