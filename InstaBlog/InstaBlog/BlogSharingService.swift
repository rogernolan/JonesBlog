import CloudKit
import OSLog
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
protocol BlogSharingServiceProtocol: Sendable {
    func restoreAcceptedSharedBlogIfNeeded() async
    func synchronizeCloudState() async
    func recoverSharedJournalRelationships() async
    func shareState(for blogID: Blog.ID) async -> BlogShareState
    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord
    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool
    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog
    func updateDisplayName(_ displayName: String, bloggerID: Blogger.ID) async throws
}

@MainActor
final class BlogSharingService: BlogSharingServiceProtocol {
    static let availablePermissions: UICloudSharingController.PermissionOptions = [
        .allowPrivate,
        .allowReadWrite,
    ]
    nonisolated private static let logger = Logger(
        subsystem: "com.jonesthevan.blog.InstaBlog",
        category: "BlogSharing"
    )

    private let database: any DatabaseWriter
    private let syncEngine: SyncEngine
    private let mediaDirectoryURL: URL
    private let mediaDataReader: @Sendable (URL) throws -> Data
    private let accountStatus: () async throws -> CKAccountStatus
    private let createShare: (Blog, String) async throws -> SharedRecord

    init(
        persistence: AppPersistence,
        fileManager: FileManager = .default,
        mediaDirectoryURL: URL? = nil,
        mediaDataReader: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0)
        },
        accountStatus: (() async throws -> CKAccountStatus)? = nil,
        createShare: ((Blog, String) async throws -> SharedRecord)? = nil
    ) {
        self.database = persistence.database
        self.syncEngine = persistence.syncEngine
        self.mediaDirectoryURL = mediaDirectoryURL
            ?? Self.defaultMediaDirectoryURL(fileManager: fileManager)
        self.mediaDataReader = mediaDataReader
        self.accountStatus = accountStatus ?? {
            guard let identifier = AppCloudKitConfiguration.containerIdentifier else {
                return .couldNotDetermine
            }
            return try await CKContainer(identifier: identifier).accountStatus()
        }
        self.createShare = createShare ?? { blog, title in
            try await persistence.syncEngine.share(record: blog) { share in
                share[CKShare.SystemFieldKey.title] = title as CKRecordValue
                share.publicPermission = .none
            }
        }
    }

    func restoreAcceptedSharedBlogIfNeeded() async {
        await synchronizeCloudState()
        do {
            let acceptedSharedBlogs = try await database.read { db in
                try Blog
                    .order { ($0.createdAt, $0.id) }
                    .fetchAll(db)
                    .compactMap { blog -> (Blog.ID, String?)? in
                        let share = try SyncMetadata
                            .find(blog.syncMetadataID)
                            .select(\.share)
                            .fetchOne(db)
                            ?? nil
                        guard share != nil else {
                            return nil
                        }
                        return (
                            blog.id,
                            share?.currentUserParticipant?.userIdentity.userRecordID?.recordName
                        )
                    }
            }
            Self.logger.info("Startup restore found \(acceptedSharedBlogs.count, privacy: .public) accepted shared blogs")
            try await Self.restoreAcceptedSharedBlogIfNeeded(
                database: database,
                acceptedSharedBlogs: acceptedSharedBlogs
            )
        } catch {
            Self.logger.error("Startup CloudKit restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func synchronizeCloudState() async {
        do {
            Self.logger.info("CloudKit sync started")
            try await syncEngine.syncChanges()
            Self.logger.info("CloudKit sync completed")
        } catch {
            Self.logger.error("CloudKit sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recoverSharedJournalRelationships() async {
        await synchronizeCloudState()
    }

    nonisolated static func restoreAcceptedSharedBlogIfNeeded(
        database: any DatabaseWriter,
        acceptedSharedBlogs: [(id: Blog.ID, participantIdentifier: String?)]
    ) async throws {
        let activeBlogID = try await database.read { db in
            try AppWorkspace
                .find(AppWorkspace.singletonID)
                .select(\.activeBlogID)
                .fetchOne(db)
                ?? nil
        }
        if let activeBlogID,
           acceptedSharedBlogs.contains(where: { $0.id == activeBlogID }) {
            logger.info("Startup restore kept accepted shared blog \(activeBlogID.uuidString, privacy: .public)")
            return
        }
        guard let restoredBlog = acceptedSharedBlogs.first else {
            logger.info("Startup restore found no accepted shared blog")
            return
        }
        // Accepted CloudKit shares, not local content volume, determine the workspace.
        try await database.write { db in
            guard try Blog.find(restoredBlog.id).fetchOne(db) != nil else { return }
            let bloggers = try Blogger
                .where { $0.blogID.eq(restoredBlog.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchAll(db)
            let trimmedParticipantIdentifier = restoredBlog.participantIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let participantIdentifier: String? = if let trimmedParticipantIdentifier,
                                                    !trimmedParticipantIdentifier.isEmpty {
                trimmedParticipantIdentifier
            } else {
                nil
            }
            let blogger = participantIdentifier.flatMap { identifier in
                bloggers.first { $0.cloudKitParticipantIdentifier == identifier }
            } ?? bloggers.first { $0.cloudKitParticipantIdentifier == nil }
                ?? bloggers.first
            guard let blogger else { return }

            if try AppBlogIdentity.find(restoredBlog.id).fetchOne(db) == nil {
                try AppBlogIdentity.insert {
                    AppBlogIdentity.Draft(blogID: restoredBlog.id, bloggerID: blogger.id)
                }.execute(db)
            } else {
                try AppBlogIdentity.find(restoredBlog.id)
                    .update { $0.bloggerID = #bind(blogger.id) }
                    .execute(db)
            }
            try AppWorkspace.find(AppWorkspace.singletonID)
                .update { $0.activeBlogID = #bind(restoredBlog.id) }
                .execute(db)
            logger.info("Startup restore activated blog \(restoredBlog.id.uuidString, privacy: .public)")
        }
    }

    func shareState(for blogID: Blog.ID) async -> BlogShareState {
        do {
            try await requireAvailableAccount()
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
        } catch let error as BlogSharingServiceError {
            return .unavailable(message: error.localizedDescription)
        } catch {
            return .error(message: error.localizedDescription)
        }
    }

    func prepareShare(for blogID: Blog.ID, title: String) async throws -> SharedRecord {
        try await requireAvailableAccount()
        try await backfillReferencedMediaData(for: blogID)
        let blog = try await database.read { db in
            try Blog.find(db, key: blogID)
        }
        return try await createShare(blog, title)
    }

    func backfillReferencedMediaData(for blogID: Blog.ID) async throws {
        let database = database
        let mediaDirectoryURL = mediaDirectoryURL
        try await Task.detached(priority: .userInitiated) {
            try await database.read { db in
                let itemIDs = try PhotoItem
                    .where { $0.blogID.eq(blogID) }
                    .fetchAll(db)
                    .map(\.mediaAssetID)
                let heroIDs = try Trip
                    .where { $0.blogID.eq(blogID) }
                    .fetchAll(db)
                    .compactMap(\.heroImageAssetID)
                let referencedIDs = Set(itemIDs + heroIDs)
                guard !referencedIDs.isEmpty else { return }
                let media = try MediaAsset
                    .where { $0.blogID.eq(blogID) && $0.id.in(Array(referencedIDs)) }
                    .fetchAll(db)

                for asset in media {
                    // Development seed palette names are rendering tokens, not photographs.
                    if asset.localOriginalPath == nil,
                       asset.cloudAssetIdentifier == nil,
                       JournalPalette(
                        rawValue: (asset.filename as NSString).deletingPathExtension
                       ) != nil {
                        continue
                    }
                    guard let photoURL = Self.resolvedLocalPhotoURL(
                        for: asset,
                        mediaDirectoryURL: mediaDirectoryURL
                    ) else {
                        throw BlogSharingServiceError.missingPhoto(filename: asset.filename)
                    }
                    guard FileManager.default.isReadableFile(atPath: photoURL.path) else {
                        throw BlogSharingServiceError.missingPhoto(filename: asset.filename)
                    }
                }
            }
        }.value
    }

    func isMeaningfulBlog(_ blogID: Blog.ID) async throws -> Bool {
        try await Self.isMeaningfulBlog(blogID, database: database)
    }

    nonisolated static func isMeaningfulBlog(
        _ blogID: Blog.ID,
        database: any DatabaseWriter
    ) async throws -> Bool {
        let developmentSeed = DevelopmentSampleData.firstRunSeed
        return try await database.read { db in
            let blog = try Blog.find(db, key: blogID)
            if blog.title != BootstrapDefaults.blogTitle {
                return true
            }

            let bloggers = try Blogger.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let trips = try Trip
                .where { $0.blogID.eq(blogID) }
                .where { !$0.deletedAt.isNot(nil) }
                .fetchAll(db)
            let items = try BlogItem.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let photoItems = try PhotoItem.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let media = try MediaAsset.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let mailingLists = try MailingList.where { $0.blogID.eq(blogID) }.fetchAll(db)
            let subscriberCount = try Subscriber.where { $0.blogID.eq(blogID) }.fetchCount(db)
            let publishCount = try PublishEvent.where { $0.blogID.eq(blogID) }.fetchCount(db)

            if Self.isDevelopmentSeed(
                developmentSeed,
                blog: blog,
                bloggers: bloggers,
                trips: trips,
                items: items,
                photoItems: photoItems,
                media: media,
                mailingLists: mailingLists,
                subscriberCount: subscriberCount,
                publishCount: publishCount
            ) {
                return false
            }
            return bloggers.contains { $0.displayName != BootstrapDefaults.bloggerDisplayName }
                || !trips.isEmpty
                || !items.isEmpty
                || !media.isEmpty
                || mailingLists.count != 1
                || mailingLists[0].name != BootstrapDefaults.mailingListName
                || subscriberCount > 0
                || publishCount > 0
        }
    }

    func acceptShare(_ metadata: CKShare.Metadata) async throws -> AcceptedBlog {
        try await requireAvailableAccount()
        guard Self.invitationAllowsWriting(
            participantPermission: metadata.participantPermission,
            publicPermission: metadata.share.publicPermission
        ) else {
            throw BlogSharingServiceError.readOnlyInvitation
        }
        let blogID = try Self.validatedBlogID(
            recordName: metadata.hierarchicalRootRecordID?.recordName
        )
        try await syncEngine.acceptShare(metadata: metadata)
        try await syncEngine.syncChanges()

        let blog = try await Self.awaitSharedBlog(
            blogID,
            database: database,
            syncChanges: { try await self.syncEngine.syncChanges() }
        )
        let userIdentity = metadata.share.currentUserParticipant?.userIdentity
        return try await acceptSharedBlog(
            blog,
            participant: ParticipantIdentity(
                identifier: userIdentity?.userRecordID?.recordName,
                displayName: Self.displayName(from: userIdentity?.nameComponents)
            )
        )
    }

    static func awaitSharedBlog(
        _ blogID: Blog.ID,
        database: any DatabaseWriter,
        retryCount: Int = 3,
        retryDelay: Duration = .milliseconds(500),
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        syncChanges: () async throws -> Void
    ) async throws -> Blog {
        for attempt in 0...retryCount {
            if let blog = try await database.read({
                try Blog.find(blogID).fetchOne($0)
            }) {
                return blog
            }
            guard attempt < retryCount else { break }
            try await sleep(retryDelay)
            try await syncChanges()
        }
        throw BlogSharingServiceError.sharedBlogNotFound
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
            let workspace = try AppWorkspace.find(db, key: AppWorkspace.singletonID)
            guard let activeBlogID = workspace.activeBlogID,
                  try Blog.find(activeBlogID).fetchOne(db) != nil,
                  let blogger = try Blogger.find(bloggerID).fetchOne(db),
                  blogger.blogID == activeBlogID
            else {
                throw BlogSharingServiceError.identityOutOfScope
            }
            if let identity = try AppBlogIdentity.find(activeBlogID).fetchOne(db) {
                guard identity.bloggerID == bloggerID else {
                    throw BlogSharingServiceError.identityOutOfScope
                }
            } else {
                let activeBloggers = try Blogger
                    .where { $0.blogID.eq(activeBlogID) }
                    .fetchAll(db)
                guard activeBloggers.count == 1,
                      activeBloggers[0].id == bloggerID
                else {
                    throw BlogSharingServiceError.identityOutOfScope
                }
                try AppBlogIdentity.insert {
                    AppBlogIdentity.Draft(blogID: activeBlogID, bloggerID: bloggerID)
                }.execute(db)
            }
            try Blogger.find(blogger.id)
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

    nonisolated static func invitationAllowsWriting(
        participantPermission: CKShare.ParticipantPermission,
        publicPermission: CKShare.ParticipantPermission
    ) -> Bool {
        participantPermission == .readWrite || publicPermission == .readWrite
    }

    nonisolated static func accountUnavailableMessage(for status: CKAccountStatus) -> String? {
        switch status {
        case .available:
            nil
        case .noAccount:
            "Sign in to iCloud to share this Blog."
        case .restricted:
            "iCloud access is restricted on this device. Check Screen Time or device management settings."
        case .couldNotDetermine:
            "Your iCloud account availability could not be confirmed. Check your connection and try again."
        case .temporarilyUnavailable:
            "iCloud is temporarily unavailable. Please try again shortly."
        @unknown default:
            "iCloud sharing is unavailable. Check your iCloud account and try again."
        }
    }

    private func requireAvailableAccount() async throws {
        do {
            if let message = Self.accountUnavailableMessage(for: try await accountStatus()) {
                throw BlogSharingServiceError.cloudAccountUnavailable(message: message)
            }
        } catch let error as BlogSharingServiceError {
            throw error
        } catch {
            throw BlogSharingServiceError.cloudAccountUnavailable(
                message: "iCloud account availability could not be confirmed. Check your connection and try again."
            )
        }
    }

    nonisolated private static func resolvedLocalPhotoURL(
        for media: MediaAsset,
        mediaDirectoryURL: URL
    ) -> URL? {
        let canonicalURL = MediaStoragePaths.canonicalURL(
            for: media,
            in: mediaDirectoryURL
        )
        if let resolvedURL = validatedLocalPhotoURL(
            canonicalURL,
            mediaDirectoryURL: mediaDirectoryURL
        ) {
            return resolvedURL
        }
        guard let legacyPath = media.localOriginalPath else { return nil }
        return validatedLocalPhotoURL(
            URL(fileURLWithPath: legacyPath),
            mediaDirectoryURL: mediaDirectoryURL
        )
    }

    nonisolated private static func validatedLocalPhotoURL(
        _ url: URL,
        mediaDirectoryURL: URL
    ) -> URL? {
        let rootURL = mediaDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidateURL.path.hasPrefix(rootURL.path + "/"),
              FileManager.default.isReadableFile(atPath: candidateURL.path),
              let values = try? candidateURL.resourceValues(
                forKeys: [.isRegularFileKey]
              )
        else { return nil }
        return values.isRegularFile == true ? candidateURL : nil
    }

    private static func defaultMediaDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (applicationSupport ?? fileManager.temporaryDirectory)
            .appendingPathComponent("BlogItemMedia", isDirectory: true)
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
        photoItems: [PhotoItem],
        media: [MediaAsset],
        mailingLists: [MailingList],
        subscriberCount: Int,
        publishCount: Int
    ) -> Bool {
        guard blog.createdAt == blog.updatedAt,
              subscriberCount == 0,
              publishCount == 0,
              trips.count == 1,
              mailingLists.count == 1,
              mailingLists[0].name == BootstrapDefaults.mailingListName,
              mailingLists[0].blogID == blog.id,
              mailingLists[0].createdAt == blog.createdAt,
              mailingLists[0].updatedAt == blog.updatedAt,
              media.count == seed.items.count,
              photoItems.count == seed.items.count,
              bloggers.allSatisfy({ $0.blogID == blog.id }),
              items.allSatisfy({ $0.blogID == blog.id }),
              media.allSatisfy({ $0.blogID == blog.id }),
              photoItems.allSatisfy({ $0.blogID == blog.id }),
              Set(photoItems.map(\.blogItemID)).count == items.count,
              Set(photoItems.map(\.mediaAssetID)).count == media.count
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
        let photoByBlogItemID = Dictionary(uniqueKeysWithValues: photoItems.map { ($0.blogItemID, $0) })
        let actualItems = items.map { item in
            let photoItem = photoByBlogItemID[item.id]
            return SeedItem(
                author: bloggersByID[item.authorID],
                blogText: item.blogText,
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
                media: photoItem.flatMap { mediaByID[$0.mediaAssetID] }.map(SeedMedia.init)
            )
        }
        let expectedItems = seed.items.map {
            SeedItem(
                author: $0.authorDisplayName,
                blogText: $0.blogText,
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
                    filename: $0.photoFilenames.first ?? "",
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
    let blogText: String?
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
    case identityOutOfScope
    case sharedBlogNotFound
    case missingPhoto(filename: String)
    case readOnlyInvitation
    case cloudAccountUnavailable(message: String)

    var errorDescription: String? {
        switch self {
        case .emptyDisplayName:
            "Display name cannot be empty."
        case .identityOutOfScope:
            "The selected Blogger is no longer the active Blog identity."
        case .sharedBlogNotFound:
            "The accepted shared blog could not be found."
        case let .missingPhoto(filename):
            "The photo “\(filename)” is missing or unreadable. Restore or remove it before sharing this Blog."
        case .readOnlyInvitation:
            "This Blog invitation is read-only. Ask the owner for permission to make changes."
        case let .cloudAccountUnavailable(message):
            message
        }
    }
}

@MainActor
final class UnavailableBlogSharingService: BlogSharingServiceProtocol {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func restoreAcceptedSharedBlogIfNeeded() async {}

    func synchronizeCloudState() async {}

    func recoverSharedJournalRelationships() async {}

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
