import CryptoKit
import Foundation
import GRDB
import SQLiteData
import UniformTypeIdentifiers

extension UTType {
    static let instaBlogArchive = UTType(
        exportedAs: "com.jonesthevan.blog.instablog-archive",
        conformingTo: .package
    )
}

nonisolated struct BlogArchiveExport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
}

nonisolated struct BlogArchiveSummary: Equatable, Sendable {
    let blogTitle: String
    let tripCount: Int
    let postCount: Int
    let photoCount: Int

    var importDescription: String {
        let trips = Self.countDescription(tripCount, singular: "trip")
        let posts = Self.countDescription(postCount, singular: "post")
        let photos = Self.countDescription(photoCount, singular: "photo")
        return "This will create \(trips) and \(posts), containing \(photos)."
    }

    private static func countDescription(_ count: Int, singular: String) -> String {
        let noun = count == 1 ? singular : "\(singular)s"
        return "\(count) \(noun)"
    }
}

nonisolated struct BlogArchiveManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct MediaFile: Codable, Equatable, Sendable {
        let assetID: MediaAsset.ID
        let filename: String
        let sha256: String
    }

    let version: Int
    let exportedAt: Date
    let selectedBloggerID: Blogger.ID
    let blog: Blog
    let bloggers: [Blogger]
    let blogItems: [BlogItem]
    let photoItems: [PhotoItem]
    let mediaAssets: [MediaAsset]
    let trips: [Trip]
    let mailingLists: [MailingList]
    let subscribers: [Subscriber]
    let publishEvents: [PublishEvent]
    let mediaFiles: [MediaFile]
}

nonisolated enum BlogArchiveError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case malformedArchive(String)
    case missingMedia(String)
    case mediaHashMismatch(String)
    case destinationContainsData

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "This archive uses unsupported format version \(version)."
        case .malformedArchive(let detail):
            "The archive is not valid: \(detail)"
        case .missingMedia(let filename):
            "The archive is missing photo file \(filename)."
        case .mediaHashMismatch(let filename):
            "Photo file \(filename) did not pass its integrity check."
        case .destinationContainsData:
            "Import is only allowed when this build contains no journal or trip data."
        }
    }
}

nonisolated struct BlogArchiveService: @unchecked Sendable {
    private static let manifestFilename = "manifest.json"
    private static let mediaDirectoryName = "Media"

    let database: any DatabaseWriter
    let fileManager: FileManager
    let mediaDirectoryURL: URL
    let mediaAssetSyncService: MediaAssetSyncService?

    init(
        database: any DatabaseWriter,
        fileManager: FileManager = .default,
        mediaDirectoryURL: URL? = nil,
        mediaAssetSyncService: MediaAssetSyncService? = nil
    ) {
        self.database = database
        self.fileManager = fileManager
        self.mediaDirectoryURL = mediaDirectoryURL
            ?? JournalService.defaultMediaDirectoryURL(fileManager: fileManager)
        self.mediaAssetSyncService = mediaAssetSyncService
    }

    func exportBlog(
        blogID: Blog.ID,
        selectedBloggerID: Blogger.ID
    ) async throws -> BlogArchiveExport {
        try await mediaAssetSyncService?.synchronize(blogID: blogID)
        var manifest = try await makeManifest(
            blogID: blogID,
            selectedBloggerID: selectedBloggerID
        )
        try Self.validate(manifest)

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("InstaBlogArchives", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(
                "\(Self.safeFilename(manifest.blog.title)).instablogarchive",
                isDirectory: true
            )
        let archiveMediaURL = archiveURL
            .appendingPathComponent(Self.mediaDirectoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: archiveMediaURL,
            withIntermediateDirectories: true
        )

        var mediaFiles: [BlogArchiveManifest.MediaFile] = []
        do {
            for asset in manifest.mediaAssets {
                guard let contentHash = asset.contentHash, !contentHash.isEmpty else {
                    throw BlogArchiveError.malformedArchive(
                        "photo \(asset.id.uuidString) has no content hash"
                    )
                }
                let sourceURL = MediaStoragePaths.canonicalURL(
                    for: asset,
                    in: mediaDirectoryURL
                )
                guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                    throw BlogArchiveError.missingMedia(asset.filename)
                }
                let archiveFilename = "\(asset.id.uuidString).\(MediaStoragePaths.preferredFileExtension(for: asset.mimeType))"
                let destinationURL = archiveMediaURL.appendingPathComponent(archiveFilename)
                let actualHash = try Self.sha256(of: sourceURL)
                guard actualHash == contentHash else {
                    throw BlogArchiveError.mediaHashMismatch(asset.filename)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                mediaFiles.append(.init(
                    assetID: asset.id,
                    filename: archiveFilename,
                    sha256: actualHash
                ))
            }

            manifest = BlogArchiveManifest(
                version: manifest.version,
                exportedAt: manifest.exportedAt,
                selectedBloggerID: manifest.selectedBloggerID,
                blog: manifest.blog,
                bloggers: manifest.bloggers,
                blogItems: manifest.blogItems,
                photoItems: manifest.photoItems,
                mediaAssets: manifest.mediaAssets,
                trips: manifest.trips,
                mailingLists: manifest.mailingLists,
                subscribers: manifest.subscribers,
                publishEvents: manifest.publishEvents,
                mediaFiles: mediaFiles
            )
            let manifestData = try Self.encoder.encode(manifest)
            try manifestData.write(
                to: archiveURL.appendingPathComponent(Self.manifestFilename),
                options: .atomic
            )
            return BlogArchiveExport(url: archiveURL)
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }
    }

    @discardableResult
    func importBlog(from archiveURL: URL) async throws -> Blog.ID {
        let manifest = try loadManifest(from: archiveURL)
        try validateMedia(in: archiveURL, manifest: manifest)

        guard try await database.read({ db in try Self.isImportable(db) }) else {
            throw BlogArchiveError.destinationContainsData
        }

        var newlyCreatedMediaURLs: [URL] = []
        do {
            try fileManager.createDirectory(
                at: mediaDirectoryURL,
                withIntermediateDirectories: true
            )
            for mediaFile in manifest.mediaFiles {
                guard let asset = manifest.mediaAssets.first(where: { $0.id == mediaFile.assetID }) else {
                    throw BlogArchiveError.malformedArchive("a media file has no matching photo")
                }
                let sourceURL = archiveURL
                    .appendingPathComponent(Self.mediaDirectoryName, isDirectory: true)
                    .appendingPathComponent(mediaFile.filename)
                let destinationURL = mediaDirectoryURL.appendingPathComponent(
                    "\(mediaFile.sha256).\(MediaStoragePaths.preferredFileExtension(for: asset.mimeType))"
                )
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    newlyCreatedMediaURLs.append(destinationURL)
                }
            }
            let importedBlogID = try await database.write { db in
                try Self.replaceBootstrapData(with: manifest, in: db)
            }
            return importedBlogID
        } catch {
            for url in newlyCreatedMediaURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    func summary(of archiveURL: URL) throws -> BlogArchiveSummary {
        let manifest = try loadManifest(from: archiveURL)
        try validateMedia(in: archiveURL, manifest: manifest)
        return BlogArchiveSummary(
            blogTitle: manifest.blog.title,
            tripCount: manifest.trips.count,
            postCount: manifest.blogItems.count,
            photoCount: manifest.photoItems.count
        )
    }

    private func loadManifest(from archiveURL: URL) throws -> BlogArchiveManifest {
        let manifestURL = archiveURL.appendingPathComponent(Self.manifestFilename)
        guard fileManager.isReadableFile(atPath: manifestURL.path) else {
            throw BlogArchiveError.malformedArchive("manifest.json is missing")
        }
        let manifest = try Self.decoder.decode(
            BlogArchiveManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.version == BlogArchiveManifest.currentVersion else {
            throw BlogArchiveError.unsupportedVersion(manifest.version)
        }
        try Self.validate(manifest)
        return manifest
    }

    private func makeManifest(
        blogID: Blog.ID,
        selectedBloggerID: Blogger.ID
    ) async throws -> BlogArchiveManifest {
        try await database.read { db in
            let blog = try Blog.find(db, key: blogID)
            let bloggers = try Blogger.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let blogItems = try BlogItem.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let photoItems = try PhotoItem.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let mediaAssets = try MediaAsset.where { $0.blogID.eq(blogID) }.fetchAll(db)
                .map { asset in
                    var copy = asset
                    copy.localOriginalPath = nil
                    copy.cloudAssetIdentifier = nil
                    copy.cloudAssetHash = nil
                    copy.cloudAssetSyncError = nil
                    return copy
                }
            return BlogArchiveManifest(
                version: BlogArchiveManifest.currentVersion,
                exportedAt: .now,
                selectedBloggerID: selectedBloggerID,
                blog: blog,
                bloggers: bloggers,
                blogItems: blogItems,
                photoItems: photoItems,
                mediaAssets: mediaAssets,
                trips: try Trip.where { $0.blogID.eq(blogID) }.fetchAll(db),
                mailingLists: try MailingList.where { $0.blogID.eq(blogID) }.fetchAll(db),
                subscribers: try Subscriber.where { $0.blogID.eq(blogID) }.fetchAll(db),
                publishEvents: try PublishEvent.where { $0.blogID.eq(blogID) }.fetchAll(db),
                mediaFiles: []
            )
        }
    }

    private func validateMedia(
        in archiveURL: URL,
        manifest: BlogArchiveManifest
    ) throws {
        guard manifest.mediaFiles.count == manifest.mediaAssets.count else {
            throw BlogArchiveError.malformedArchive("the photo file count is incorrect")
        }
        let assetIDs = Set(manifest.mediaAssets.map(\.id))
        guard Set(manifest.mediaFiles.map(\.assetID)) == assetIDs else {
            throw BlogArchiveError.malformedArchive("the photo file list is incomplete")
        }
        let mediaURL = archiveURL.appendingPathComponent(Self.mediaDirectoryName, isDirectory: true)
        for mediaFile in manifest.mediaFiles {
            guard mediaFile.filename == URL(fileURLWithPath: mediaFile.filename).lastPathComponent else {
                throw BlogArchiveError.malformedArchive("a photo filename is unsafe")
            }
            let fileURL = mediaURL.appendingPathComponent(mediaFile.filename)
            guard fileManager.isReadableFile(atPath: fileURL.path) else {
                throw BlogArchiveError.missingMedia(mediaFile.filename)
            }
            guard try Self.sha256(of: fileURL) == mediaFile.sha256 else {
                throw BlogArchiveError.mediaHashMismatch(mediaFile.filename)
            }
        }
    }

    static func validate(_ manifest: BlogArchiveManifest) throws {
        let blogID = manifest.blog.id
        let bloggerIDs = Set(manifest.bloggers.map(\.id))
        let itemIDs = Set(manifest.blogItems.map(\.id))
        let assetIDs = Set(manifest.mediaAssets.map(\.id))
        let mailingListIDs = Set(manifest.mailingLists.map(\.id))
        let tripIDs = Set(manifest.trips.map(\.id))

        guard bloggerIDs.count == manifest.bloggers.count,
              itemIDs.count == manifest.blogItems.count,
              assetIDs.count == manifest.mediaAssets.count,
              Set(manifest.photoItems.map(\.id)).count == manifest.photoItems.count,
              tripIDs.count == manifest.trips.count,
              mailingListIDs.count == manifest.mailingLists.count,
              Set(manifest.subscribers.map(\.id)).count == manifest.subscribers.count,
              Set(manifest.publishEvents.map(\.id)).count == manifest.publishEvents.count,
              bloggerIDs.contains(manifest.selectedBloggerID),
              manifest.bloggers.allSatisfy({ $0.blogID == blogID }),
              manifest.blogItems.allSatisfy({
                  $0.blogID == blogID
                      && bloggerIDs.contains($0.authorID)
                      && ($0.lastEditorID.map(bloggerIDs.contains) ?? true)
              }),
              manifest.mediaAssets.allSatisfy({
                  $0.blogID == blogID
                      && ($0.photoLibraryAssetUploaderID.map(bloggerIDs.contains) ?? true)
              }),
              manifest.photoItems.allSatisfy({
                  $0.blogID == blogID
                      && itemIDs.contains($0.blogItemID)
                      && assetIDs.contains($0.mediaAssetID)
              }),
              manifest.trips.allSatisfy({
                  $0.blogID == blogID
                      && ($0.heroImageAssetID.map(assetIDs.contains) ?? true)
              }),
              manifest.mailingLists.allSatisfy({ $0.blogID == blogID }),
              manifest.subscribers.allSatisfy({
                  $0.blogID == blogID && mailingListIDs.contains($0.mailingListID)
              }),
              manifest.publishEvents.allSatisfy({
                  $0.blogID == blogID
                      && mailingListIDs.contains($0.mailingListID)
                      && bloggerIDs.contains($0.initiatedByBloggerID)
                      && ($0.tripID.map(tripIDs.contains) ?? true)
              })
        else {
            throw BlogArchiveError.malformedArchive("record relationships are inconsistent")
        }
    }

    private static func isImportable(_ db: Database) throws -> Bool {
        let blogs = try Blog.all.fetchAll(db)
        let bloggers = try Blogger.all.fetchAll(db)
        let mailingLists = try MailingList.all.fetchAll(db)
        return try BlogItem.all.fetchAll(db).isEmpty
            && PhotoItem.all.fetchAll(db).isEmpty
            && MediaAsset.all.fetchAll(db).isEmpty
            && Trip.all.fetchAll(db).isEmpty
            && Subscriber.all.fetchAll(db).isEmpty
            && PublishEvent.all.fetchAll(db).isEmpty
            && blogs.allSatisfy { $0.title == BootstrapDefaults.blogTitle }
            && bloggers.allSatisfy {
                $0.displayName == BootstrapDefaults.bloggerDisplayName
                    && $0.cloudKitParticipantIdentifier == nil
            }
            && mailingLists.allSatisfy { $0.name == BootstrapDefaults.mailingListName }
    }

    private static func replaceBootstrapData(
        with manifest: BlogArchiveManifest,
        in db: Database
    ) throws -> Blog.ID {
        let importedBlogID = UUID()
        let bloggerIDs = Dictionary(uniqueKeysWithValues: manifest.bloggers.map { ($0.id, UUID()) })
        let blogItemIDs = Dictionary(uniqueKeysWithValues: manifest.blogItems.map { ($0.id, UUID()) })
        let mediaAssetIDs = Dictionary(uniqueKeysWithValues: manifest.mediaAssets.map { ($0.id, UUID()) })
        let photoItemIDs = Dictionary(uniqueKeysWithValues: manifest.photoItems.map { ($0.id, UUID()) })
        let tripIDs = Dictionary(uniqueKeysWithValues: manifest.trips.map { ($0.id, UUID()) })
        let mailingListIDs = Dictionary(uniqueKeysWithValues: manifest.mailingLists.map { ($0.id, UUID()) })
        let subscriberIDs = Dictionary(uniqueKeysWithValues: manifest.subscribers.map { ($0.id, UUID()) })
        let publishEventIDs = Dictionary(uniqueKeysWithValues: manifest.publishEvents.map { ($0.id, UUID()) })

        func mapped(_ id: UUID, in identifiers: [UUID: UUID]) throws -> UUID {
            guard let mappedID = identifiers[id] else {
                throw BlogArchiveError.malformedArchive("an imported record relationship is missing")
            }
            return mappedID
        }

        for identity in try AppBlogIdentity.all.fetchAll(db) {
            try AppBlogIdentity.find(identity.id).delete().execute(db)
        }
        for mailingList in try MailingList.all.fetchAll(db) {
            try MailingList.find(mailingList.id).delete().execute(db)
        }
        for blogger in try Blogger.all.fetchAll(db) {
            try Blogger.find(blogger.id).delete().execute(db)
        }
        for blog in try Blog.all.fetchAll(db) {
            try Blog.find(blog.id).delete().execute(db)
        }

        try Blog.insert {
            Blog.Draft(
                id: importedBlogID,
                title: manifest.blog.title,
                createdAt: manifest.blog.createdAt,
                updatedAt: manifest.blog.updatedAt
            )
        }.execute(db)
        for blogger in manifest.bloggers {
            let importedBloggerID = try mapped(blogger.id, in: bloggerIDs)
            try Blogger.insert {
                Blogger.Draft(
                    id: importedBloggerID,
                    blogID: importedBlogID,
                    displayName: blogger.displayName,
                    createdAt: blogger.createdAt,
                    updatedAt: blogger.updatedAt,
                    cloudKitParticipantIdentifier: nil
                )
            }.execute(db)
        }
        for asset in manifest.mediaAssets {
            guard let contentHash = asset.contentHash else {
                throw BlogArchiveError.malformedArchive("a photo has no content hash")
            }
            let importedAssetID = try mapped(asset.id, in: mediaAssetIDs)
            let importedUploaderID = try asset.photoLibraryAssetUploaderID.map {
                try mapped($0, in: bloggerIDs)
            }
            let localFilename = "\(contentHash).\(MediaStoragePaths.preferredFileExtension(for: asset.mimeType))"
            try MediaAsset.insert {
                MediaAsset.Draft(
                    id: importedAssetID,
                    blogID: importedBlogID,
                    kind: asset.kind,
                    localOriginalPath: localFilename,
                    photoLibraryAssetIdentifier: asset.photoLibraryAssetIdentifier,
                    photoLibraryAssetUploaderID: importedUploaderID,
                    cloudAssetIdentifier: nil,
                    contentHash: contentHash,
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
        for item in manifest.blogItems {
            let importedItemID = try mapped(item.id, in: blogItemIDs)
            let importedAuthorID = try mapped(item.authorID, in: bloggerIDs)
            let importedLastEditorID = try item.lastEditorID.map {
                try mapped($0, in: bloggerIDs)
            }
            try BlogItem.insert {
                BlogItem.Draft(
                    id: importedItemID,
                    blogID: importedBlogID,
                    authorID: importedAuthorID,
                    lastEditorID: importedLastEditorID,
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
        for photo in manifest.photoItems {
            let importedPhotoID = try mapped(photo.id, in: photoItemIDs)
            let importedItemID = try mapped(photo.blogItemID, in: blogItemIDs)
            let importedAssetID = try mapped(photo.mediaAssetID, in: mediaAssetIDs)
            try PhotoItem.insert {
                PhotoItem.Draft(
                    id: importedPhotoID,
                    blogID: importedBlogID,
                    blogItemID: importedItemID,
                    mediaAssetID: importedAssetID,
                    photoCaption: photo.photoCaption,
                    photoDate: photo.photoDate,
                    createdAt: photo.createdAt,
                    updatedAt: photo.updatedAt
                )
            }.execute(db)
        }
        for trip in manifest.trips {
            let importedTripID = try mapped(trip.id, in: tripIDs)
            let importedHeroImageAssetID = try trip.heroImageAssetID.map {
                try mapped($0, in: mediaAssetIDs)
            }
            try Trip.insert {
                Trip.Draft(
                    id: importedTripID,
                    blogID: importedBlogID,
                    title: trip.title,
                    description: trip.description,
                    startLocalDay: trip.startLocalDay,
                    endLocalDay: trip.endLocalDay,
                    heroImageAssetID: importedHeroImageAssetID,
                    createdAt: trip.createdAt,
                    updatedAt: trip.updatedAt,
                    closedAt: trip.closedAt,
                    deletedAt: trip.deletedAt
                )
            }.execute(db)
        }
        for mailingList in manifest.mailingLists {
            let importedMailingListID = try mapped(mailingList.id, in: mailingListIDs)
            try MailingList.insert {
                MailingList.Draft(
                    id: importedMailingListID,
                    blogID: importedBlogID,
                    name: mailingList.name,
                    createdAt: mailingList.createdAt,
                    updatedAt: mailingList.updatedAt
                )
            }.execute(db)
        }
        for subscriber in manifest.subscribers {
            let importedSubscriberID = try mapped(subscriber.id, in: subscriberIDs)
            let importedMailingListID = try mapped(subscriber.mailingListID, in: mailingListIDs)
            try Subscriber.insert {
                Subscriber.Draft(
                    id: importedSubscriberID,
                    blogID: importedBlogID,
                    mailingListID: importedMailingListID,
                    emailAddress: subscriber.emailAddress,
                    displayName: subscriber.displayName,
                    createdAt: subscriber.createdAt,
                    updatedAt: subscriber.updatedAt
                )
            }.execute(db)
        }
        for event in manifest.publishEvents {
            let importedEventID = try mapped(event.id, in: publishEventIDs)
            let importedTripID = try event.tripID.map { try mapped($0, in: tripIDs) }
            let importedMailingListID = try mapped(event.mailingListID, in: mailingListIDs)
            let importedBloggerID = try mapped(event.initiatedByBloggerID, in: bloggerIDs)
            try PublishEvent.insert {
                PublishEvent.Draft(
                    id: importedEventID,
                    blogID: importedBlogID,
                    tripID: importedTripID,
                    localDay: event.localDay,
                    mailingListID: importedMailingListID,
                    initiatedAt: event.initiatedAt,
                    initiatedByBloggerID: importedBloggerID,
                    recipientCount: event.recipientCount
                )
            }.execute(db)
        }
        let importedSelectedBloggerID = try mapped(manifest.selectedBloggerID, in: bloggerIDs)
        try AppBlogIdentity.insert {
            AppBlogIdentity.Draft(
                blogID: importedBlogID,
                bloggerID: importedSelectedBloggerID
            )
        }.execute(db)
        try AppWorkspace.find(AppWorkspace.singletonID)
            .update { $0.activeBlogID = #bind(importedBlogID) }
            .execute(db)
        return importedBlogID
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFilename(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = title.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let collapsed = String(result).replacingOccurrences(of: "--", with: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "InstaBlog" : trimmed
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
