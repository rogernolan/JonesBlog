import Foundation
import GRDB
import SQLiteData

/// Copies the local-only journal into a CloudKit-delivered Blog without ever
/// reusing a local record identity. Mapping rows live only in the local store,
/// so retries after termination resume with the same destination identities.
nonisolated struct LocalJournalAdoptionService {
    enum AdoptionError: Error {
        case missingWorkspace
        case missingSourceBlogger(Blogger.ID)
        case missingSourceMedia(MediaAsset.ID)
        case invalidMappedID(String)
        case copiedEntriesMissingFromCloud(Int)
    }

    let localDatabase: any DatabaseWriter
    let cloudDatabase: any DatabaseWriter
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> UUID

    init(
        localDatabase: any DatabaseWriter,
        cloudDatabase: any DatabaseWriter,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.localDatabase = localDatabase
        self.cloudDatabase = cloudDatabase
        self.now = now
        self.uuid = uuid
    }

    func sourceEntryCount() throws -> Int {
        try localDatabase.read { db in
            try BlogItem.fetchCount(db)
        }
    }

    struct Result: Sendable, Equatable {
        let destinationBlogID: Blog.ID
        let sourceItemIDs: [BlogItem.ID]
        let destinationItemIDs: [BlogItem.ID]
        let failures: [Failure]
    }

    struct Failure: Sendable, Equatable {
        let recordType: String
        let sourceID: UUID
        let message: String
    }

    struct ReportError: LocalizedError {
        let failures: [Failure]

        var errorDescription: String? {
            "\(failures.count) local journal record\(failures.count == 1 ? "" : "s") could not be copied."
        }
    }

    func adopt(into destinationBlogID: Blog.ID) throws -> Result {
        let source = try localDatabase.read { db -> LocalJournalSnapshot in
            let workspace = try AppWorkspace.find(db, key: AppWorkspace.singletonID)
            guard let blogID = workspace.activeBlogID else { throw AdoptionError.missingWorkspace }
            return try LocalJournalSnapshot.load(blogID: blogID, in: db)
        }

        var failures: [Failure] = []
        for blogger in source.bloggers {
            do {
                let destinationID = try mappedID(
                table: "localJournalBloggerMappings",
                sourceColumn: "sourceBloggerID",
                destinationColumn: "destinationBloggerID",
                sourceID: blogger.id
            )
                try cloudDatabase.write { db in
                guard try Blogger.find(destinationID).fetchOne(db) == nil else { return }
                try Blogger.insert {
                    Blogger.Draft(
                        id: destinationID,
                        blogID: destinationBlogID,
                        displayName: blogger.displayName,
                        createdAt: blogger.createdAt,
                        updatedAt: blogger.updatedAt,
                        cloudKitParticipantIdentifier: nil
                    )
                }.execute(db)
                }
            } catch {
                failures.append(Failure(recordType: "Blogger", sourceID: blogger.id, message: error.localizedDescription))
            }
        }

        var bloggerIDs: [Blogger.ID: Blogger.ID] = [:]
        for blogger in source.bloggers {
            do {
                bloggerIDs[blogger.id] = try mappedID(
                table: "localJournalBloggerMappings",
                sourceColumn: "sourceBloggerID",
                destinationColumn: "destinationBloggerID",
                sourceID: blogger.id
                )
            } catch {
                failures.append(Failure(recordType: "Blogger mapping", sourceID: blogger.id, message: error.localizedDescription))
            }
        }

        for asset in source.mediaAssets {
            do {
                let destinationID = try mappedID(
                table: "localJournalMediaMappings",
                sourceColumn: "sourceMediaID",
                destinationColumn: "destinationMediaID",
                sourceID: asset.id
            )
                try cloudDatabase.write { db in
                guard try MediaAsset.find(destinationID).fetchOne(db) == nil else { return }
                try MediaAsset.insert {
                    MediaAsset.Draft(
                        id: destinationID,
                        blogID: destinationBlogID,
                        kind: asset.kind,
                        localOriginalPath: asset.localOriginalPath,
                        photoLibraryAssetIdentifier: asset.photoLibraryAssetIdentifier,
                        photoLibraryAssetUploaderID: asset.photoLibraryAssetUploaderID.flatMap { bloggerIDs[$0] },
                        cloudAssetIdentifier: nil,
                        contentHash: asset.contentHash,
                        cloudAssetHash: nil,
                        cloudAssetSyncError: nil,
                        filename: asset.filename,
                        mimeType: asset.mimeType,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        createdAt: asset.createdAt,
                        updatedAt: asset.updatedAt
                    )
                }.execute(db)
                }
            } catch {
                failures.append(Failure(recordType: "MediaAsset", sourceID: asset.id, message: error.localizedDescription))
            }
        }

        for item in source.items {
            do {
                guard let authorID = bloggerIDs[item.authorID] else {
                    throw AdoptionError.missingSourceBlogger(item.authorID)
                }
                let destinationID = try mappedID(
                table: "localJournalItemMappings",
                sourceColumn: "sourceItemID",
                destinationColumn: "destinationItemID",
                sourceID: item.id
            )
                try cloudDatabase.write { db in
                guard try BlogItem.find(destinationID).fetchOne(db) == nil else { return }
                try BlogItem.insert {
                    BlogItem.Draft(
                        id: destinationID,
                        blogID: destinationBlogID,
                        authorID: authorID,
                        lastEditorID: item.lastEditorID.flatMap { bloggerIDs[$0] },
                        blogText: item.blogText,
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt,
                        lastEditedAt: item.lastEditedAt,
                        itemDate: item.itemDate,
                        itemTimeZoneIdentifier: item.itemTimeZoneIdentifier,
                        localDay: item.localDay,
                        latitude: item.latitude,
                        longitude: item.longitude,
                        locationName: item.locationName,
                        countryCode: item.countryCode,
                        weatherTemperatureCelsius: item.weatherTemperatureCelsius,
                        weatherConditionCode: item.weatherConditionCode,
                        deletedAt: item.deletedAt
                    )
                }.execute(db)
                }
            } catch {
                failures.append(Failure(recordType: "BlogItem", sourceID: item.id, message: error.localizedDescription))
            }
        }

        for photo in source.photos {
            do {
                guard let itemID = try existingMappedID(
                table: "localJournalItemMappings",
                sourceColumn: "sourceItemID",
                destinationColumn: "destinationItemID",
                sourceID: photo.blogItemID
            ), let mediaID = try existingMappedID(
                table: "localJournalMediaMappings",
                sourceColumn: "sourceMediaID",
                destinationColumn: "destinationMediaID",
                sourceID: photo.mediaAssetID
                ) else { throw AdoptionError.missingSourceMedia(photo.mediaAssetID) }
                let destinationID = try mappedID(
                table: "localJournalPhotoMappings",
                sourceColumn: "sourcePhotoID",
                destinationColumn: "destinationPhotoID",
                sourceID: photo.id
            )
                try cloudDatabase.write { db in
                guard try PhotoItem.find(destinationID).fetchOne(db) == nil else { return }
                try PhotoItem.insert {
                    PhotoItem.Draft(
                        id: destinationID,
                        blogID: destinationBlogID,
                        blogItemID: itemID,
                        mediaAssetID: mediaID,
                        photoCaption: photo.photoCaption,
                        photoDate: photo.photoDate,
                        createdAt: photo.createdAt,
                        updatedAt: photo.updatedAt
                    )
                }.execute(db)
                }
            } catch {
                failures.append(Failure(recordType: "PhotoItem", sourceID: photo.id, message: error.localizedDescription))
            }
        }

        do {
            try cloudDatabase.write { db in
                guard try AppBlogIdentity.find(destinationBlogID).fetchOne(db) == nil,
                      let localIdentity = source.identity,
                      let bloggerID = bloggerIDs[localIdentity.bloggerID]
                else { return }
                try AppBlogIdentity.insert {
                    AppBlogIdentity.Draft(blogID: destinationBlogID, bloggerID: bloggerID)
                }.execute(db)
            }
        } catch {
            failures.append(Failure(recordType: "AppBlogIdentity", sourceID: destinationBlogID, message: error.localizedDescription))
        }
        var missingMappingCount = 0
        let destinationItemIDs: [BlogItem.ID] = try source.items.compactMap { item in
            guard let destinationID = try existingMappedID(
                table: "localJournalItemMappings",
                sourceColumn: "sourceItemID",
                destinationColumn: "destinationItemID",
                sourceID: item.id
            ) else {
                missingMappingCount += 1
                return nil
            }
            return destinationID
        }
        guard missingMappingCount == 0 else {
            throw AdoptionError.copiedEntriesMissingFromCloud(missingMappingCount)
        }
        let result = Result(
            destinationBlogID: destinationBlogID,
            sourceItemIDs: source.items.map(\.id),
            destinationItemIDs: destinationItemIDs,
            failures: failures
        )
        return result
    }

    func verify(_ result: Result) throws {
        let missingCount = try result.sourceItemIDs.reduce(into: 0) { missingCount, sourceItemID in
            guard let destinationID = try existingMappedID(
                table: "localJournalItemMappings",
                sourceColumn: "sourceItemID",
                destinationColumn: "destinationItemID",
                sourceID: sourceItemID
            ) else {
                missingCount += 1
                return
            }
            let exists = try cloudDatabase.read { db in
                try BlogItem
                    .where { $0.id.eq(destinationID) && $0.blogID.eq(result.destinationBlogID) }
                    .fetchOne(db) != nil
            }
            if !exists { missingCount += 1 }
        }
        guard missingCount == 0 else {
            throw AdoptionError.copiedEntriesMissingFromCloud(missingCount)
        }
        guard result.failures.isEmpty else { return }
        try localDatabase.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO localJournalAdoptions (destinationBlogID, adoptedAt) VALUES (?, ?)",
                arguments: [result.destinationBlogID.uuidString, now()]
            )
        }
    }

    func copyMediaFiles(
        from localMediaDirectory: URL,
        to cloudMediaDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let assets = try localDatabase.read { db in
            try MediaAsset.fetchAll(db)
        }
        try fileManager.createDirectory(at: cloudMediaDirectory, withIntermediateDirectories: true)
        for asset in assets {
            let sourceURL = MediaStoragePaths.canonicalURL(for: asset, in: localMediaDirectory)
            let destinationURL = MediaStoragePaths.canonicalURL(for: asset, in: cloudMediaDirectory)
            guard fileManager.fileExists(atPath: sourceURL.path),
                  !fileManager.fileExists(atPath: destinationURL.path)
            else { continue }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private func mappedID(
        table: String,
        sourceColumn: String,
        destinationColumn: String,
        sourceID: UUID
    ) throws -> UUID {
        if let id = try existingMappedID(
            table: table,
            sourceColumn: sourceColumn,
            destinationColumn: destinationColumn,
            sourceID: sourceID
        ) { return id }
        let destinationID = uuid()
        try localDatabase.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO \(table) (\(sourceColumn), \(destinationColumn)) VALUES (?, ?)",
                arguments: [sourceID.uuidString, destinationID.uuidString]
            )
        }
        return try existingMappedID(
            table: table,
            sourceColumn: sourceColumn,
            destinationColumn: destinationColumn,
            sourceID: sourceID
        ) ?? destinationID
    }

    private func existingMappedID(
        table: String,
        sourceColumn: String,
        destinationColumn: String,
        sourceID: UUID
    ) throws -> UUID? {
        try localDatabase.read { db in
            let value = try String.fetchOne(
                db,
                sql: "SELECT \(destinationColumn) FROM \(table) WHERE \(sourceColumn) = ?",
                arguments: [sourceID.uuidString]
            )
            guard let value else { return nil }
            guard let id = UUID(uuidString: value) else { throw AdoptionError.invalidMappedID(value) }
            return id
        }
    }
}

nonisolated private struct LocalJournalSnapshot {
    let identity: AppBlogIdentity?
    let bloggers: [Blogger]
    let items: [BlogItem]
    let mediaAssets: [MediaAsset]
    let photos: [PhotoItem]

    static func load(blogID: Blog.ID, in db: Database) throws -> Self {
        try Self(
            identity: AppBlogIdentity.find(blogID).fetchOne(db),
            bloggers: Blogger.where { $0.blogID.eq(blogID) }.fetchAll(db),
            items: BlogItem.where { $0.blogID.eq(blogID) }.order { ($0.createdAt, $0.id) }.fetchAll(db),
            mediaAssets: MediaAsset.where { $0.blogID.eq(blogID) }.fetchAll(db),
            photos: PhotoItem.where { $0.blogID.eq(blogID) }.order { ($0.photoDate, $0.id) }.fetchAll(db)
        )
    }
}
