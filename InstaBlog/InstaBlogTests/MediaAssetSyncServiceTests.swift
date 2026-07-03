import CloudKit
import CryptoKit
import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Media asset sync service", .serialized)
struct MediaAssetSyncServiceTests {
    @Test func successfulAssetSaveSurvivesFollowUpStructuredSyncFailure() async throws {
        let fixture = try await Fixture.localAsset()
        let sync = SyncStub(failureOnCall: 2)
        let cloud = CloudStub()
        let logs = LogRecorder()
        let service = fixture.service(sync: sync, cloud: cloud, logs: logs)

        await #expect(throws: TestError.structuredSync) {
            try await service.synchronize(blogID: fixture.blogID)
        }

        let asset = try await fixture.asset()
        #expect(asset.externalSyncState == .synced)
        #expect(asset.cloudAssetSyncError == nil)
        #expect(asset.cloudAssetIdentifier != nil)
        #expect(await cloud.savedRecords().count == 1)
        #expect(logs.messages().contains { $0.contains("structured sync after media transfer") })
    }

    @Test func assetSaveFailurePersistsDetailedErrorAndLogsAssetIdentity() async throws {
        let fixture = try await Fixture.localAsset()
        let cloud = CloudStub(saveError: TestError.assetUpload)
        let logs = LogRecorder()
        let service = fixture.service(cloud: cloud, logs: logs)

        try await service.synchronize(blogID: fixture.blogID)

        let asset = try await fixture.asset()
        #expect(asset.externalSyncState == .failed)
        #expect(asset.cloudAssetIdentifier == nil)
        #expect(asset.cloudAssetSyncError?.contains("Asset upload failed") == true)
        let messages = logs.messages()
        #expect(messages.contains { $0.contains("upload failed") })
        #expect(messages.contains { $0.contains(fixture.assetID.uuidString) })
    }

    @Test func matchingRemoteMetadataClearsStaleFailureWithoutUploadingAgain() async throws {
        let fixture = try await Fixture.localAsset(
            cloudAssetIdentifier: "remote-object",
            cloudAssetHashMatches: true,
            cloudAssetSyncError: "Failed to send changes"
        )
        let cloud = CloudStub()

        try await fixture.service(cloud: cloud).synchronize(blogID: fixture.blogID)

        let asset = try await fixture.asset()
        #expect(asset.externalSyncState == .synced)
        #expect(asset.cloudAssetSyncError == nil)
        #expect(await cloud.savedRecords().isEmpty)
    }

    @Test func retryAfterUploadFailureSucceedsAndClearsFailure() async throws {
        let fixture = try await Fixture.localAsset()
        let cloud = CloudStub(saveError: TestError.assetUpload)
        let service = fixture.service(cloud: cloud)

        try await service.synchronize(blogID: fixture.blogID)
        #expect(try await fixture.asset().externalSyncState == .failed)

        await cloud.setSaveError(nil)
        try await service.synchronize(blogID: fixture.blogID)

        let asset = try await fixture.asset()
        #expect(asset.externalSyncState == .synced)
        #expect(asset.cloudAssetSyncError == nil)
        #expect(await cloud.savedRecords().count == 1)
    }

    @Test func hashMismatchRejectsDownloadedFileAndLogsFailure() async throws {
        let fixture = try await Fixture.remoteAsset()
        let wrongData = Data("wrong bytes".utf8)
        let sourceURL = fixture.rootURL.appendingPathComponent("remote-download")
        try wrongData.write(to: sourceURL)
        let remoteRecord = fixture.remoteObjectRecord(
            hash: String(repeating: "a", count: 64),
            fileURL: sourceURL
        )
        let cloud = CloudStub(fetchedRecord: remoteRecord)
        let logs = LogRecorder()
        let service = fixture.service(cloud: cloud, logs: logs)

        await #expect(throws: MediaAssetSyncError.hashMismatch) {
            try await service.synchronize(blogID: fixture.blogID)
        }

        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.mediaDirectoryURL,
            includingPropertiesForKeys: nil
        ).isEmpty)
        #expect(logs.messages().contains { $0.contains("download failed") })
    }

    @Test func existingRemoteObjectIsUpdatedInsteadOfDuplicated() async throws {
        let fixture = try await Fixture.localAsset()
        let existing = fixture.remoteObjectRecord(
            hash: fixture.contentHash,
            fileURL: fixture.localFileURL
        )
        existing["marker"] = "existing" as CKRecordValue
        let cloud = CloudStub(fetchedRecord: existing)

        try await fixture.service(cloud: cloud).synchronize(blogID: fixture.blogID)

        let savedRecords = await cloud.savedRecords()
        #expect(savedRecords.count == 1)
        let saved = try #require(savedRecords.first)
        #expect(saved.recordID == existing.recordID)
        #expect(saved["marker"] as? String == "existing")
        let savedParent = try #require(saved.parent)
        #expect(savedParent.action == .none)
    }

    @Test func databaseScopeTracksRecordZoneOwner() {
        let privateID = CKRecord.ID(
            recordName: "private",
            zoneID: CKRecordZone.ID(zoneName: "zone", ownerName: CKCurrentUserDefaultName)
        )
        let sharedID = CKRecord.ID(
            recordName: "shared",
            zoneID: CKRecordZone.ID(zoneName: "zone", ownerName: "another-user")
        )

        #expect(MediaAssetSyncService.databaseScope(for: privateID) == .privateDatabase)
        #expect(MediaAssetSyncService.databaseScope(for: sharedID) == .sharedDatabase)
    }

    @Test func missingParentRecordLeavesAssetPendingWithoutCloudMutation() async throws {
        let fixture = try await Fixture.localAsset()
        let cloud = CloudStub()
        let service = fixture.service(cloud: cloud, hasParentRecord: false)

        try await service.synchronize(blogID: fixture.blogID)

        #expect(try await fixture.asset().externalSyncState == .pending)
        #expect(await cloud.fetchCalls().isEmpty)
        #expect(await cloud.savedRecords().isEmpty)
    }
}

private extension MediaAssetSyncServiceTests {
    struct Fixture {
        let database: any DatabaseWriter
        let rootURL: URL
        let mediaDirectoryURL: URL
        let blogID: Blog.ID
        let assetID: MediaAsset.ID
        let contentHash: String
        let parentRecord: CKRecord

        var localFileURL: URL {
            mediaDirectoryURL.appendingPathComponent("\(contentHash).jpg")
        }

        static func localAsset(
            cloudAssetIdentifier: String? = nil,
            cloudAssetHashMatches: Bool = false,
            cloudAssetSyncError: String? = nil
        ) async throws -> Self {
            let data = Data("original image".utf8)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let fixture = try await make(
                contentHash: hash,
                localOriginalPath: "\(hash).jpg",
                cloudAssetIdentifier: cloudAssetIdentifier,
                cloudAssetHash: cloudAssetHashMatches ? hash : nil,
                cloudAssetSyncError: cloudAssetSyncError
            )
            try FileManager.default.createDirectory(
                at: fixture.mediaDirectoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fixture.localFileURL)
            return fixture
        }

        static func remoteAsset() async throws -> Self {
            try await make(
                contentHash: nil,
                localOriginalPath: nil,
                cloudAssetIdentifier: "remote-object",
                cloudAssetHash: nil,
                cloudAssetSyncError: nil
            )
        }

        private static func make(
            contentHash: String?,
            localOriginalPath: String?,
            cloudAssetIdentifier: String?,
            cloudAssetHash: String?,
            cloudAssetSyncError: String?
        ) async throws -> Self {
            let database = try AppDatabase.makeInMemory()
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaAssetSyncTests-\(UUID())", isDirectory: true)
            let mediaDirectoryURL = rootURL.appendingPathComponent("BlogItemMedia", isDirectory: true)
            try FileManager.default.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)
            let blogID = UUID()
            let assetID = UUID()
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
            try await database.write { db in
                try Blog.insert {
                    Blog.Draft(id: blogID, createdAt: timestamp, updatedAt: timestamp)
                }.execute(db)
                try MediaAsset.insert {
                    MediaAsset.Draft(
                        id: assetID,
                        blogID: blogID,
                        localOriginalPath: localOriginalPath,
                        cloudAssetIdentifier: cloudAssetIdentifier,
                        contentHash: contentHash,
                        cloudAssetHash: cloudAssetHash,
                        cloudAssetSyncError: cloudAssetSyncError,
                        filename: contentHash.map { "\($0).jpg" } ?? "remote.jpg",
                        mimeType: "image/jpeg",
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }.execute(db)
            }
            let parentID = CKRecord.ID(
                recordName: "\(assetID.uuidString):mediaAssets",
                zoneID: CKRecordZone.ID(
                    zoneName: "co.pointfree.SQLiteData.defaultZone",
                    ownerName: CKCurrentUserDefaultName
                )
            )
            return Self(
                database: database,
                rootURL: rootURL,
                mediaDirectoryURL: mediaDirectoryURL,
                blogID: blogID,
                assetID: assetID,
                contentHash: contentHash ?? "",
                parentRecord: CKRecord(recordType: "mediaAssets", recordID: parentID)
            )
        }

        func service(
            sync: SyncStub = SyncStub(),
            cloud: CloudStub,
            logs: LogRecorder = LogRecorder(),
            hasParentRecord: Bool = true
        ) -> MediaAssetSyncService {
            let resolvedParent = hasParentRecord ? parentRecord : nil
            return MediaAssetSyncService(
                database: database,
                mediaDirectoryURL: mediaDirectoryURL,
                synchronizeStructuredRecords: {
                    try await sync.synchronize()
                },
                serverRecordProvider: { _ in resolvedParent },
                cloud: cloud.operations,
                failureLogger: { message in
                    logs.append(message)
                }
            )
        }

        func asset() async throws -> MediaAsset {
            try await database.read { db in
                try MediaAsset.find(db, key: assetID)
            }
        }

        func remoteObjectRecord(hash: String, fileURL: URL) -> CKRecord {
            let recordID = CKRecord.ID(
                recordName: "\(assetID.uuidString)-\(contentHash)",
                zoneID: parentRecord.recordID.zoneID
            )
            let record = CKRecord(recordType: "MediaAssetObject", recordID: recordID)
            record["contentHash"] = hash as CKRecordValue
            record["original"] = CKAsset(fileURL: fileURL)
            return record
        }
    }

    actor SyncStub {
        private var callCount = 0
        private let failureOnCall: Int?

        init(failureOnCall: Int? = nil) {
            self.failureOnCall = failureOnCall
        }

        func synchronize() throws {
            callCount += 1
            if callCount == failureOnCall {
                throw TestError.structuredSync
            }
        }
    }

    actor CloudStub {
        private var fetchedRecord: CKRecord?
        private var saveError: Error?
        private var fetchInvocations: [(CKRecord.ID, MediaAssetCloudDatabaseScope)] = []
        private var saves: [CKRecord] = []

        init(fetchedRecord: CKRecord? = nil, saveError: Error? = nil) {
            self.fetchedRecord = fetchedRecord
            self.saveError = saveError
        }

        nonisolated var operations: MediaAssetCloudOperations {
            MediaAssetCloudOperations(
                fetch: { recordID, scope in
                    await self.fetch(recordID, scope: scope)
                },
                save: { record, scope in
                    try await self.save(record, scope: scope)
                }
            )
        }

        func setSaveError(_ error: Error?) {
            saveError = error
        }

        func fetchCalls() -> [(CKRecord.ID, MediaAssetCloudDatabaseScope)] {
            fetchInvocations
        }

        func savedRecords() -> [CKRecord] {
            saves
        }

        private func fetch(
            _ recordID: CKRecord.ID,
            scope: MediaAssetCloudDatabaseScope
        ) -> CKRecord? {
            fetchInvocations.append((recordID, scope))
            return fetchedRecord
        }

        private func save(
            _ record: CKRecord,
            scope: MediaAssetCloudDatabaseScope
        ) throws -> CKRecord {
            if let saveError {
                throw saveError
            }
            saves.append(record)
            return record
        }
    }

    final class LogRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedMessages: [String] = []

        func append(_ message: String) {
            lock.lock()
            defer { lock.unlock() }
            recordedMessages.append(message)
        }

        func messages() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedMessages
        }
    }

    enum TestError: LocalizedError {
        case assetUpload
        case structuredSync

        var errorDescription: String? {
            switch self {
            case .assetUpload:
                "Asset upload failed"
            case .structuredSync:
                "Structured sync failed"
            }
        }
    }
}
