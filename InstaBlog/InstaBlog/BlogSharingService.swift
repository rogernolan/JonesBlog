import CloudKit
import SQLiteData
import UIKit

nonisolated enum BlogShareState: Equatable {
    case notShared
    case sharedOwner
    case sharedParticipant
    case unavailable(message: String)
    case error(message: String)
}

nonisolated struct BlogShareMetadata: Equatable {
    var isShared: Bool
    var currentUserIsOwner: Bool
    var currentUserCanWrite: Bool

    var shareState: BlogShareState {
        guard isShared else {
            return .notShared
        }
        if currentUserIsOwner {
            return .sharedOwner
        }
        if currentUserCanWrite {
            return .sharedParticipant
        }
        return .unavailable(message: "This shared blog is read-only.")
    }
}

nonisolated struct AcceptedBlog: Equatable {
    let blogID: Blog.ID
    let bloggerID: Blogger.ID
}

nonisolated struct ParticipantIdentity: Equatable, Sendable {
    let identifier: String?
    let displayName: String?
}

@MainActor
protocol BlogSharingServiceProtocol {
    func shareState(for blogID: Blog.ID) async -> BlogShareState
    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord
    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool
    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog
    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws
}

@MainActor
final class BlogSharingService: BlogSharingServiceProtocol {
    static let availablePermissions: UICloudSharingController.PermissionOptions = [.allowReadWrite]

    private let database: any DatabaseWriter
    private let syncEngine: SyncEngine

    init(persistence: AppPersistence) {
        self.database = persistence.database
        self.syncEngine = persistence.syncEngine
    }

    func shareState(for blogID: Blog.ID) async -> BlogShareState {
        do {
            let share = try await database.read { db -> CKShare? in
                let blog = try Blog.find(db, key: blogID)
                return try SyncMetadata
                    .find(blog.syncMetadataID)
                    .select(\.share)
                    .fetchOne(db)
                    ?? nil
            }
            guard let share else {
                return .notShared
            }
            let participant = share.currentUserParticipant
            return BlogShareMetadata(
                isShared: true,
                currentUserIsOwner: participant?.role == .owner,
                currentUserCanWrite: participant?.permission == .readWrite
                    || share.publicPermission == .readWrite
            ).shareState
        } catch {
            return .error(message: error.localizedDescription)
        }
    }

    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord {
        let blog = try await database.read { db in
            try Blog.find(db, key: blogID)
        }
        return try await syncEngine.share(record: blog) { share in
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            share.publicPermission = .none
        }
    }

    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool {
        try await Self.isMeaningfulBlog(blogID, database: database)
    }

    nonisolated static func isMeaningfulBlog(
        _ blogID: Blog.ID,
        database: any DatabaseWriter
    ) async throws -> Bool {
        let developmentSeed = await DevelopmentSampleData.firstRunSeed
        return try await database.read { db in
            let blog = try Blog.find(db, key: blogID)
            if blog.title != BootstrapDefaults.blogTitle
                || blog.galleryIntervalSeconds != BootstrapDefaults.galleryIntervalSeconds
                || blog.galleryDistanceMeters != BootstrapDefaults.galleryDistanceMeters
            {
                return true
            }

            let bloggers = try Blogger.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let trips = try Trip.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let items = try BlogItem.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let media = try MediaAsset.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let mailingLists = try MailingList.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let mediaDataCount = try MediaAssetData
                .where { $0.mediaAssetID.in(media.map(\.id)) }
                .fetchCount(db)
            let subscriberCount = try Subscriber.where { $0.blogID.eq(blogID) }.fetchCount(db)
            let publishCount = try PublishEvent.where { $0.blogID.eq(blogID) }.fetchCount(db)

            if Self.isDevelopmentSeed(
                developmentSeed,
                blog: blog,
                bloggers: bloggers,
                trips: trips,
                items: items,
                media: media,
                mailingLists: mailingLists,
                mediaDataCount: mediaDataCount,
                subscriberCount: subscriberCount,
                publishCount: publishCount
            ) {
                return false
            }
            return bloggers.contains { $0.displayName != BootstrapDefaults.bloggerDisplayName }
                || !trips.isEmpty
                || !items.isEmpty
                || !media.isEmpty
                || mediaDataCount > 0
                || mailingLists.count != 1
                || mailingLists[0].name != BootstrapDefaults.mailingListName
                || subscriberCount > 0
                || publishCount > 0
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog {
        let blogID = try Self.validatedBlogID(
            recordName: metadata.hierarchicalRootRecordID?.recordName
        )
        try await syncEngine.acceptShare(metadata: metadata)
        try await syncEngine.syncChanges()

        let blog = try await database.read { db in
            try Blog.find(db, key: blogID)
        }
        let userIdentity = metadata.share.currentUserParticipant?.userIdentity
        return try await acceptSharedBlog(
            blog,
            participant: ParticipantIdentity(
                identifier: userIdentity?.userRecordID?.recordName,
                displayName: Self.displayName(from: userIdentity?.nameComponents)
            )
        )
    }

    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws {
        try await Self.updateDisplayName(
            displayName,
            bloggerID: bloggerID,
            database: database
        )
    }

    nonisolated static func updateDisplayName(
        _ displayName: String,
        bloggerID: Blogger.ID,
        database: any DatabaseWriter
    ) async throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BlogSharingServiceError.emptyDisplayName
        }
        try await database.write { db in
            try Blogger.find(bloggerID)
                .update {
                    $0.displayName = #bind(trimmedName)
                    $0.updatedAt = #bind(Date.now)
                }
                .execute(db)
        }
    }

    func acceptSharedBlog(
        _ blog: Blog,
        participant: ParticipantIdentity
    ) async throws -> AcceptedBlog {
        let identifier = participant.identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let suppliedDisplayName = participant.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return try await database.write { db in
            guard try Blog.find(blog.id).fetchOne(db) != nil else {
                throw BlogSharingServiceError.sharedBlogNotFound
            }
            let mappedIdentity = try AppBlogIdentity.find(blog.id).fetchOne(db)
            let existing: Blogger?
            if let mappedIdentity {
                existing = try Blogger.find(mappedIdentity.bloggerID).fetchOne(db)
            } else if let identifier {
                existing = try Blogger.where {
                    $0.blogID.eq(blog.id) && $0.cloudKitParticipantIdentifier.eq(identifier)
                }.fetchOne(db)
            } else {
                existing = nil
            }

            let bloggerID: Blogger.ID
            if let existing {
                bloggerID = existing.id
                try Blogger.find(existing.id)
                    .update {
                        $0.displayName = #bind(suppliedDisplayName ?? existing.displayName)
                        $0.updatedAt = #bind(Date.now)
                        $0.cloudKitParticipantIdentifier = #bind(
                            identifier ?? existing.cloudKitParticipantIdentifier
                        )
                    }
                    .execute(db)
            } else {
                bloggerID = UUID()
                try Blogger.insert {
                    Blogger.Draft(
                        id: bloggerID,
                        blogID: blog.id,
                        displayName: suppliedDisplayName ?? "Blogger",
                        createdAt: .now,
                        updatedAt: .now,
                        cloudKitParticipantIdentifier: identifier
                    )
                }
                .execute(db)
            }

            if mappedIdentity == nil {
                try AppBlogIdentity.insert {
                    AppBlogIdentity.Draft(blogID: blog.id, bloggerID: bloggerID)
                }.execute(db)
            } else if mappedIdentity?.bloggerID != bloggerID {
                try AppBlogIdentity.find(blog.id)
                    .update { $0.bloggerID = #bind(bloggerID) }
                    .execute(db)
            }
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(blog.id) }
                .execute(db)
            return AcceptedBlog(blogID: blog.id, bloggerID: bloggerID)
        }
    }

    nonisolated static func validatedBlogID(recordName: String?) throws -> Blog.ID {
        guard let recordName,
              recordName.hasSuffix(":blogs"),
              let id = UUID(uuidString: String(recordName.dropLast(":blogs".count)))
        else { throw BlogSharingServiceError.sharedBlogNotFound }
        return id
    }

    private static func displayName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let parts = [components.givenName, components.middleName, components.familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    nonisolated private static func isDevelopmentSeed(
        _ seed: FirstRunSeed,
        blog: Blog,
        bloggers: [Blogger],
        trips: [Trip],
        items: [BlogItem],
        media: [MediaAsset],
        mailingLists: [MailingList],
        mediaDataCount: Int,
        subscriberCount: Int,
        publishCount: Int
    ) -> Bool {
        guard blog.createdAt == blog.updatedAt,
              subscriberCount == 0,
              publishCount == 0,
              mediaDataCount == 0,
              trips.count == 1,
              mailingLists.count == 1,
              mailingLists[0].name == BootstrapDefaults.mailingListName,
              mailingLists[0].blogID == blog.id,
              mailingLists[0].createdAt == blog.createdAt,
              mailingLists[0].updatedAt == blog.updatedAt,
              media.count == seed.items.count,
              bloggers.allSatisfy({ $0.blogID == blog.id }),
              items.allSatisfy({ $0.blogID == blog.id }),
              media.allSatisfy({ $0.blogID == blog.id }),
              Set(items.compactMap(\.photoAssetID)).count == items.count,
              Set(items.compactMap(\.photoAssetID)).count == media.count
        else { return false }

        let expectedBloggers = [seed.primaryBloggerDisplayName]
            + seed.additionalBloggerDisplayNames
        guard multiset(bloggers.map {
            SeedBlogger(
                displayName: $0.displayName,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                participantIdentifier: $0.cloudKitParticipantIdentifier
            )
        }) == multiset(expectedBloggers.map {
            SeedBlogger(
                displayName: $0,
                createdAt: blog.createdAt,
                updatedAt: blog.updatedAt,
                participantIdentifier: nil
            )
        }) else { return false }

        let trip = trips[0]
        guard trip.blogID == blog.id,
              trip.title == seed.tripTitle,
              trip.description == seed.tripDescription,
              trip.startLocalDay == seed.startLocalDay,
              trip.endLocalDay == seed.endLocalDay,
              trip.heroImageAssetID == nil,
              trip.createdAt == blog.createdAt,
              trip.updatedAt == blog.updatedAt,
              trip.closedAt == nil
        else { return false }

        let bloggersByID = Dictionary(uniqueKeysWithValues: bloggers.map { ($0.id, $0.displayName) })
        let mediaByID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        let actualItems = items.map { item in
            SeedItem(
                author: bloggersByID[item.authorID],
                caption: item.caption,
                itemDate: item.itemDate,
                timeZone: item.itemTimeZoneIdentifier,
                localDay: item.localDay,
                latitude: item.latitude,
                longitude: item.longitude,
                location: item.locationName,
                countryCode: item.countryCode,
                temperature: item.weatherTemperatureCelsius,
                condition: item.weatherConditionCode,
                deletedAt: item.deletedAt,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                media: item.photoAssetID.flatMap { mediaByID[$0] }.map(SeedMedia.init)
            )
        }
        let expectedItems = seed.items.map {
            SeedItem(
                author: $0.authorDisplayName,
                caption: $0.caption,
                itemDate: $0.date,
                timeZone: $0.timeZoneIdentifier,
                localDay: $0.localDay,
                latitude: nil,
                longitude: nil,
                location: $0.locationName,
                countryCode: $0.countryCode,
                temperature: $0.weatherTemperatureCelsius,
                condition: $0.weatherConditionCode,
                deletedAt: nil,
                createdAt: blog.createdAt,
                updatedAt: blog.updatedAt,
                media: SeedMedia(
                    kind: "photo",
                    localOriginalPath: nil,
                    cloudAssetIdentifier: nil,
                    filename: $0.photoFilename,
                    mimeType: "image/jpeg",
                    pixelWidth: nil,
                    pixelHeight: nil,
                    createdAt: blog.createdAt,
                    updatedAt: blog.updatedAt
                )
            )
        }
        return multiset(actualItems) == multiset(expectedItems)
    }

    nonisolated private static func multiset<Element: Hashable>(
        _ elements: [Element]
    ) -> [Element: Int] {
        elements.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}

nonisolated private struct SeedBlogger: Hashable {
    let displayName: String
    let createdAt: Date
    let updatedAt: Date
    let participantIdentifier: String?
}

nonisolated private struct SeedItem: Hashable {
    let author: String?
    let caption: String?
    let itemDate: Date
    let timeZone: String?
    let localDay: String
    let latitude: Double?
    let longitude: Double?
    let location: String?
    let countryCode: String?
    let temperature: Double?
    let condition: String?
    let deletedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let media: SeedMedia?
}

nonisolated private struct SeedMedia: Hashable {
    let kind: String
    let localOriginalPath: String?
    let cloudAssetIdentifier: String?
    let filename: String
    let mimeType: String
    let pixelWidth: Int?
    let pixelHeight: Int?
    let createdAt: Date
    let updatedAt: Date

    init(_ media: MediaAsset) {
        kind = media.kind
        localOriginalPath = media.localOriginalPath
        cloudAssetIdentifier = media.cloudAssetIdentifier
        filename = media.filename
        mimeType = media.mimeType
        pixelWidth = media.pixelWidth
        pixelHeight = media.pixelHeight
        createdAt = media.createdAt
        updatedAt = media.updatedAt
    }

    init(
        kind: String,
        localOriginalPath: String?,
        cloudAssetIdentifier: String?,
        filename: String,
        mimeType: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.kind = kind
        self.localOriginalPath = localOriginalPath
        self.cloudAssetIdentifier = cloudAssetIdentifier
        self.filename = filename
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum BlogSharingServiceError: LocalizedError {
    case emptyDisplayName
    case sharedBlogNotFound

    var errorDescription: String? {
        switch self {
        case .emptyDisplayName:
            "Display name cannot be empty."
        case .sharedBlogNotFound:
            "The accepted shared blog could not be found."
        }
    }
}

@MainActor
final class UnavailableBlogSharingService: BlogSharingServiceProtocol {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func shareState(for blogID: Blog.ID) async -> BlogShareState {
        .unavailable(message: "Sign in to iCloud to share this Blog.")
    }

    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord {
        throw BlogSharingUnavailableError()
    }

    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool {
        try await BlogSharingService.isMeaningfulBlog(blogID, database: database)
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog {
        throw BlogSharingUnavailableError()
    }

    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws {
        try await BlogSharingService.updateDisplayName(
            displayName,
            bloggerID: bloggerID,
            database: database
        )
    }
}

private struct BlogSharingUnavailableError: LocalizedError {
    var errorDescription: String? {
        "Sign in to iCloud to use Blog sharing."
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
