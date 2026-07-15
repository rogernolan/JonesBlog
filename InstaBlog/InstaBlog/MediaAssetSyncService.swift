import CloudKit
import CryptoKit
import Foundation
import OSLog
import SQLiteData

nonisolated enum MediaAssetCloudDatabaseScope: Equatable, Sendable {
    case privateDatabase
    case sharedDatabase
}

nonisolated struct MediaAssetCloudOperations: @unchecked Sendable {
    var fetch: @Sendable (CKRecord.ID, MediaAssetCloudDatabaseScope) async throws -> CKRecord?
    var save: @Sendable (CKRecord, MediaAssetCloudDatabaseScope) async throws -> CKRecord
}

nonisolated struct MediaAssetSyncService: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.jonesthevan.blog.InstaBlog",
        category: "MediaAssetSync"
    )
    private static let assetField = "original"
    private static let hashField = "contentHash"

    let database: any DatabaseWriter
    let fileManager: FileManager
    let mediaDirectoryURL: URL
    private let synchronizeStructuredRecords: @Sendable () async throws -> Void
    private let serverRecordProvider: @Sendable (MediaAsset) async throws -> CKRecord?
    private let cloud: MediaAssetCloudOperations
    private let failureLogger: @Sendable (String) -> Void
    private let synchronizationGate: MediaAssetSynchronizationGate

    init(
        persistence: AppPersistence,
        fileManager: FileManager = .default,
        mediaDirectoryURL: URL? = nil
    ) {
        let database = persistence.database
        let container = AppCloudKitConfiguration.containerIdentifier
            .map(CKContainer.init(identifier:))
            ?? .default()
        self.init(
            database: database,
            fileManager: fileManager,
            mediaDirectoryURL: mediaDirectoryURL
                ?? JournalService.defaultMediaDirectoryURL(fileManager: fileManager),
            synchronizeStructuredRecords: {
                try await persistence.syncEngine.syncChanges()
            },
            serverRecordProvider: { asset in
                try await database.read { db in
                    try SyncMetadata
                        .find(asset.syncMetadataID)
                        .select(\._lastKnownServerRecordAllFields)
                        .fetchOne(db)
                        ?? nil
                }
            },
            cloud: MediaAssetCloudOperations(
                fetch: { recordID, scope in
                    do {
                        return try await Self.cloudDatabase(
                            in: container,
                            scope: scope
                        )
                        .record(for: recordID)
                    } catch let error as CKError where error.code == .unknownItem {
                        return nil
                    }
                },
                save: { record, scope in
                    try await Self.cloudDatabase(in: container, scope: scope).save(record)
                }
            ),
            failureLogger: { message in
                Self.logger.error("\(message, privacy: .public)")
            }
        )
    }

    init(
        database: any DatabaseWriter,
        fileManager: FileManager = .default,
        mediaDirectoryURL: URL,
        synchronizeStructuredRecords: @escaping @Sendable () async throws -> Void,
        serverRecordProvider: @escaping @Sendable (MediaAsset) async throws -> CKRecord?,
        cloud: MediaAssetCloudOperations,
        failureLogger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.database = database
        self.fileManager = fileManager
        self.mediaDirectoryURL = mediaDirectoryURL
        self.synchronizeStructuredRecords = synchronizeStructuredRecords
        self.serverRecordProvider = serverRecordProvider
        self.cloud = cloud
        self.failureLogger = failureLogger
        synchronizationGate = MediaAssetSynchronizationGate()
    }

    func synchronize(blogID: Blog.ID) async throws {
        try await synchronizationGate.run {
            try await performSynchronization(blogID: blogID)
        }
    }

    private func performSynchronization(blogID: Blog.ID) async throws {
        try await synchronizeStructuredRecords(
            operation: "structured sync before media transfer",
            assetID: nil
        )
        let assets = try await database.read { db in
            try MediaAsset.where { $0.blogID.eq(blogID) }.fetchAll(db)
        }
        for asset in assets {
            let remoteIdentifier = asset.cloudAssetIdentifier.flatMap { identifier in
                identifier.isEmpty ? nil : identifier
            }
            if remoteIdentifier == nil,
               let localURL = localURL(for: asset),
               let contentHash = asset.contentHash,
               asset.cloudAssetHash != contentHash {
                do {
                    try await upload(asset, from: localURL, contentHash: contentHash)
                } catch {
                    logFailure(error, operation: "upload", assetID: asset.id)
                    try await database.write { db in
                        try MediaAsset.find(asset.id).update {
                            $0.cloudAssetSyncError = #bind(Self.errorDescription(error))
                        }.execute(db)
                    }
                }
            } else if asset.externalSyncState == .synced,
                      asset.cloudAssetSyncError != nil {
                try await database.write { db in
                    try MediaAsset.find(asset.id).update {
                        $0.cloudAssetSyncError = #bind(nil)
                    }.execute(db)
                }
            } else if let identifier = remoteIdentifier,
                      (localURL(for: asset) == nil || asset.cloudAssetHash != asset.contentHash) {
                do {
                    try await download(asset, identifier: identifier)
                } catch {
                    logFailure(error, operation: "download", assetID: asset.id)
                    throw error
                }
            }
        }
        try await synchronizeStructuredRecords(
            operation: "structured sync after media transfer",
            assetID: nil
        )
    }

    private func upload(
        _ asset: MediaAsset,
        from localURL: URL,
        contentHash: String
    ) async throws {
        guard let parentRecord = try await serverRecordProvider(asset) else { return }
        let recordID = CKRecord.ID(
            recordName: "\(asset.id.uuidString)-\(contentHash)",
            zoneID: parentRecord.recordID.zoneID
        )
        let scope = Self.databaseScope(for: recordID)
        let record = try await cloud.fetch(recordID, scope)
            ?? CKRecord(recordType: "MediaAssetObject", recordID: recordID)
        record.parent = Self.parentReference(for: parentRecord)
        record[Self.assetField] = CKAsset(fileURL: localURL)
        record[Self.hashField] = contentHash as CKRecordValue
        let saved = try await cloud.save(record, scope)
        try await database.write { db in
            try MediaAsset.find(asset.id).update {
                $0.cloudAssetIdentifier = #bind(saved.recordID.recordName)
                $0.cloudAssetHash = #bind(contentHash)
                $0.cloudAssetSyncError = #bind(nil)
                $0.updatedAt = #bind(Date.now)
            }.execute(db)
        }
    }

    private func download(_ asset: MediaAsset, identifier: String) async throws {
        guard let parentRecord = try await serverRecordProvider(asset) else { return }
        let recordID = CKRecord.ID(
            recordName: identifier,
            zoneID: parentRecord.recordID.zoneID
        )
        guard let record = try await cloud.fetch(
            recordID,
            Self.databaseScope(for: recordID)
        ) else {
            throw MediaAssetSyncError.remoteObjectMissing
        }
        guard let remoteHash = record[Self.hashField] as? String,
              let cloudAsset = record[Self.assetField] as? CKAsset,
              let sourceURL = cloudAsset.fileURL
        else {
            throw MediaAssetSyncError.malformedRemoteObject
        }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHash == remoteHash else {
            throw MediaAssetSyncError.hashMismatch
        }
        try fileManager.createDirectory(
            at: mediaDirectoryURL,
            withIntermediateDirectories: true
        )
        let filename = "\(remoteHash).\(MediaStoragePaths.preferredFileExtension(for: asset.mimeType))"
        let destinationURL = mediaDirectoryURL.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try data.write(to: destinationURL, options: .atomic)
        }
        try await database.write { db in
            try MediaAsset.find(asset.id).update {
                $0.localOriginalPath = #bind(filename)
                $0.contentHash = #bind(remoteHash)
                $0.cloudAssetHash = #bind(remoteHash)
                $0.cloudAssetSyncError = #bind(nil)
                $0.filename = #bind(filename)
            }.execute(db)
        }
    }

    static func databaseScope(for recordID: CKRecord.ID) -> MediaAssetCloudDatabaseScope {
        recordID.zoneID.ownerName == CKCurrentUserDefaultName
            ? .privateDatabase
            : .sharedDatabase
    }

    static func parentReference(for record: CKRecord) -> CKRecord.Reference {
        CKRecord.Reference(record: record, action: .none)
    }

    private static func cloudDatabase(
        in container: CKContainer,
        scope: MediaAssetCloudDatabaseScope
    ) -> CKDatabase {
        switch scope {
        case .privateDatabase:
            container.privateCloudDatabase
        case .sharedDatabase:
            container.sharedCloudDatabase
        }
    }

    private static func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    private func synchronizeStructuredRecords(
        operation: String,
        assetID: MediaAsset.ID?
    ) async throws {
        do {
            try await synchronizeStructuredRecords()
        } catch {
            logFailure(error, operation: operation, assetID: assetID)
            throw error
        }
    }

    private func logFailure(
        _ error: Error,
        operation: String,
        assetID: MediaAsset.ID?
    ) {
        let identifier = assetID?.uuidString ?? "none"
        if let cloudError = error as? CKError {
            failureLogger(
                "\(operation) failed; assetID=\(identifier); CKError=\(cloudError.code.rawValue); \(String(describing: cloudError))"
            )
        } else {
            failureLogger(
                "\(operation) failed; assetID=\(identifier); \(Self.errorDescription(error))"
            )
        }
    }

    private func localURL(for asset: MediaAsset) -> URL? {
        let canonicalURL = MediaStoragePaths.canonicalURL(for: asset, in: mediaDirectoryURL)
        guard fileManager.isReadableFile(atPath: canonicalURL.path) else { return nil }
        return canonicalURL
    }
}

private actor MediaAssetSynchronizationGate {
    private var tail: (id: UUID, completion: Task<Void, Never>)?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let predecessor = tail?.completion
        let operationTask = Task {
            if let predecessor {
                await predecessor.value
            }
            try await operation()
        }
        let operationID = UUID()
        let completion = Task {
            _ = try? await operationTask.value
        }
        tail = (operationID, completion)

        do {
            try await operationTask.value
            clearTail(ifMatching: operationID)
        } catch {
            clearTail(ifMatching: operationID)
            throw error
        }
    }

    private func clearTail(ifMatching operationID: UUID) {
        if tail?.id == operationID {
            tail = nil
        }
    }
}

nonisolated enum MediaAssetSyncError: Error, Equatable {
    case hashMismatch
    case malformedRemoteObject
    case remoteObjectMissing
}
