import CryptoKit
import Foundation
import SQLiteData

nonisolated struct BootstrapWorkspace: Equatable {
    let blog: Blog
    let blogger: Blogger
    let mailingList: MailingList
}

nonisolated struct BloggerSelectionRequirement: Equatable {
    let blog: Blog
    let bloggers: [Blogger]
    let mailingList: MailingList
}

nonisolated enum BootstrapPreparation: Equatable {
    case ready(BootstrapWorkspace)
    case bloggerSelectionRequired(BloggerSelectionRequirement)
}

nonisolated struct FirstRunSeed: Sendable {
    let primaryBloggerDisplayName: String
    let additionalBloggerDisplayNames: [String]
    let tripTitle: String
    let tripDescription: String
    let startLocalDay: String
    let endLocalDay: String?
    let items: [FirstRunBlogItemSeed]
}

nonisolated struct FirstRunBlogItemSeed: Sendable {
    let authorDisplayName: String
    let date: Date
    let timeZoneIdentifier: String
    let localDay: String
    let blogText: String
    let locationName: String
    let countryCode: String
    let weatherTemperatureCelsius: Double
    let weatherConditionCode: String
    let photoFilenames: [String]
    let altitude: Double?
    let showElevation: Bool?

    init(
        authorDisplayName: String,
        date: Date,
        timeZoneIdentifier: String,
        localDay: String,
        blogText: String,
        locationName: String,
        countryCode: String,
        weatherTemperatureCelsius: Double,
        weatherConditionCode: String,
        photoFilenames: [String],
        altitude: Double? = nil,
        showElevation: Bool? = nil
    ) {
        self.authorDisplayName = authorDisplayName
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.localDay = localDay
        self.blogText = blogText
        self.locationName = locationName
        self.countryCode = countryCode
        self.weatherTemperatureCelsius = weatherTemperatureCelsius
        self.weatherConditionCode = weatherConditionCode
        self.photoFilenames = photoFilenames
        self.altitude = altitude
        self.showElevation = showElevation
    }
}

nonisolated struct BlogBootstrapService {
    private enum BootstrapError: Error {
        case insertDidNotReturnRecord
        case bloggerSelectionRequired
        case unknownSeedAuthor(String)
    }

    let database: any DatabaseWriter
    let now: @Sendable () -> Date
    let uuid: @Sendable () -> UUID

    init(
        database: any DatabaseWriter,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.database = database
        self.now = now
        self.uuid = uuid
    }

    func bootstrap(seed: FirstRunSeed? = nil) throws -> BootstrapWorkspace {
        switch try prepare(seed: seed) {
        case .ready(let workspace):
            return workspace
        case .bloggerSelectionRequired:
            throw BootstrapError.bloggerSelectionRequired
        }
    }

    func prepare(seed: FirstRunSeed? = nil) throws -> BootstrapPreparation {
        try database.write { db in
            let timestamp = now()

            let workspace = try AppWorkspace.find(db, key: AppWorkspace.singletonID)
            let blog: Blog
            let existingBlog = try workspace.activeBlogID.flatMap { activeBlogID in
                try Blog.find(activeBlogID).fetchOne(db)
            } ?? Blog.order { ($0.createdAt, $0.id) }.fetchOne(db)
            let isNewWorkspace = existingBlog == nil
            if let existingBlog {
                blog = existingBlog
            } else {
                let insertedBlog = try Blog.insert {
                    Blog.Draft(
                        id: uuid(),
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .returning(\.self)
                .fetchOne(db)
                guard let insertedBlog else {
                    throw BootstrapError.insertDidNotReturnRecord
                }
                blog = insertedBlog
            }

            let blogger: Blogger?
            let existingIdentity = try AppBlogIdentity.find(blog.id).fetchOne(db)
            let availableBloggers = try Blogger
                .where { $0.blogID.eq(blog.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchAll(db)
            let localBlogger = availableBloggers.first { $0.cloudKitParticipantIdentifier == nil }
            if let existingIdentity {
                blogger = availableBloggers.first { $0.id == existingIdentity.bloggerID }
            } else if let localBlogger {
                blogger = localBlogger
            } else {
                let insertedBlogger = try Blogger.insert {
                    Blogger.Draft(
                        id: uuid(),
                        blogID: blog.id,
                        displayName: seed?.primaryBloggerDisplayName ?? BootstrapDefaults.bloggerDisplayName,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .returning(\.self)
                .fetchOne(db)
                guard let insertedBlogger else {
                    throw BootstrapError.insertDidNotReturnRecord
                }
                blogger = insertedBlogger
            }

            let mailingList: MailingList
            let existingMailingList = try MailingList
                .where { $0.blogID.eq(blog.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchOne(db)
            if let existingMailingList {
                mailingList = existingMailingList
            } else {
                let insertedMailingList = try MailingList.insert {
                    MailingList.Draft(
                        id: uuid(),
                        blogID: blog.id,
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .returning(\.self)
                .fetchOne(db)
                guard let insertedMailingList else {
                    throw BootstrapError.insertDidNotReturnRecord
                }
                mailingList = insertedMailingList
            }

            if isNewWorkspace, let seed, let blogger {
                try insert(seed, in: blog, primaryBlogger: blogger, timestamp: timestamp, db: db)
            }
            if workspace.activeBlogID == nil {
                try AppWorkspace.find(AppWorkspace.singletonID)
                    .update { $0.activeBlogID = #bind(blog.id) }
                    .execute(db)
            }
            if existingIdentity == nil, let blogger {
                try AppBlogIdentity.insert {
                    AppBlogIdentity.Draft(blogID: blog.id, bloggerID: blogger.id)
                }.execute(db)
            }

            if let blogger {
                return .ready(BootstrapWorkspace(
                    blog: blog,
                    blogger: blogger,
                    mailingList: mailingList
                ))
            }
            return .bloggerSelectionRequired(BloggerSelectionRequirement(
                blog: blog,
                bloggers: availableBloggers,
                mailingList: mailingList
            ))
        }
    }

    func selectBlogger(blogID: Blog.ID, bloggerID: Blogger.ID) throws -> BootstrapWorkspace {
        try database.write { db in
            let blog = try Blog.find(db, key: blogID)
            let blogger = try Blogger.find(db, key: bloggerID)
            guard blogger.blogID == blog.id else {
                throw BootstrapError.insertDidNotReturnRecord
            }
            let mailingList = try MailingList
                .where { $0.blogID.eq(blog.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchOne(db)
            guard let mailingList else {
                throw BootstrapError.insertDidNotReturnRecord
            }
            try setIdentity(blogID: blog.id, bloggerID: blogger.id, in: db)
            return BootstrapWorkspace(blog: blog, blogger: blogger, mailingList: mailingList)
        }
    }

    func createAndSelectBlogger(blogID: Blog.ID, displayName: String) throws -> BootstrapWorkspace {
        try database.write { db in
            let blog = try Blog.find(db, key: blogID)
            let mailingList = try MailingList
                .where { $0.blogID.eq(blog.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchOne(db)
            guard let mailingList else {
                throw BootstrapError.insertDidNotReturnRecord
            }
            let timestamp = now()
            let blogger = try Blogger.insert {
                Blogger.Draft(
                    id: uuid(),
                    blogID: blog.id,
                    displayName: displayName,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
            .returning(\.self)
            .fetchOne(db)
            guard let blogger else {
                throw BootstrapError.insertDidNotReturnRecord
            }
            try setIdentity(blogID: blog.id, bloggerID: blogger.id, in: db)
            return BootstrapWorkspace(blog: blog, blogger: blogger, mailingList: mailingList)
        }
    }

    /// Derives a stable UUID for a seed blog item from its content, so UI tests that
    /// relaunch with a re-seeded in-memory database can still match editor drafts keyed by
    /// the item's id. Seed data is only inserted for new workspaces during UI testing.
    private static func deterministicItemID(for seed: FirstRunBlogItemSeed) -> UUID {
        var digest = SHA256()
        for value in [
            seed.authorDisplayName,
            seed.blogText,
            seed.locationName,
            seed.localDay,
            seed.timeZoneIdentifier,
            String(seed.date.timeIntervalSince1970),
        ] {
            digest.update(data: Data(value.utf8))
            digest.update(data: [0])
        }
        var bytes = Array(digest.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func setIdentity(blogID: Blog.ID, bloggerID: Blogger.ID, in db: Database) throws {
        if try AppBlogIdentity.find(blogID).fetchOne(db) == nil {
            try AppBlogIdentity.insert {
                AppBlogIdentity.Draft(blogID: blogID, bloggerID: bloggerID)
            }.execute(db)
        } else {
            try AppBlogIdentity.find(blogID)
                .update { $0.bloggerID = #bind(bloggerID) }
                .execute(db)
        }
    }

    private func insert(
        _ seed: FirstRunSeed,
        in blog: Blog,
        primaryBlogger: Blogger,
        timestamp: Date,
        db: Database
    ) throws {
        var bloggersByName = [primaryBlogger.displayName: primaryBlogger]
        for displayName in seed.additionalBloggerDisplayNames {
            let blogger = try Blogger.insert {
                Blogger.Draft(
                    id: uuid(),
                    blogID: blog.id,
                    displayName: displayName,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
            .returning(\.self)
            .fetchOne(db)
            guard let blogger else { throw BootstrapError.insertDidNotReturnRecord }
            bloggersByName[displayName] = blogger
        }

        try Trip.insert {
            Trip.Draft(
                id: uuid(),
                blogID: blog.id,
                title: seed.tripTitle,
                description: seed.tripDescription,
                startLocalDay: seed.startLocalDay,
                endLocalDay: seed.endLocalDay,
                heroImageAssetID: nil,
                createdAt: timestamp,
                updatedAt: timestamp,
                closedAt: nil,
                deletedAt: nil
            )
        }
        .execute(db)

        for item in seed.items {
            guard let author = bloggersByName[item.authorDisplayName] else {
                throw BootstrapError.unknownSeedAuthor(item.authorDisplayName)
            }
            let itemID = Self.deterministicItemID(for: item)
            try BlogItem.insert {
                BlogItem.Draft(
                    id: itemID,
                    blogID: blog.id,
                    authorID: author.id,
                    blogText: item.blogText,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    itemDate: item.date,
                    itemTimeZoneIdentifier: item.timeZoneIdentifier,
                    localDay: item.localDay,
                    altitude: item.altitude,
                    showElevation: item.showElevation ?? (item.altitude.map { $0 > 800 && $0.isFinite } ?? false),
                    locationName: item.locationName,
                    countryCode: item.countryCode,
                    weatherTemperatureCelsius: item.weatherTemperatureCelsius,
                    weatherConditionCode: item.weatherConditionCode,
                    deletedAt: nil
                )
            }
            .execute(db)

            for (index, filename) in item.photoFilenames.enumerated() {
                let mediaID = uuid()
                // Development seed filenames select generated palettes; there are no source image bytes to synchronize.
                try MediaAsset.insert {
                    MediaAsset.Draft(
                        id: mediaID,
                        blogID: blog.id,
                        filename: filename,
                        mimeType: "image/jpeg",
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .execute(db)
                try PhotoItem.insert {
                    PhotoItem.Draft(
                        id: uuid(),
                        blogID: blog.id,
                        blogItemID: itemID,
                        mediaAssetID: mediaID,
                        photoCaption: nil,
                        photoDate: item.date.addingTimeInterval(TimeInterval(index)),
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .execute(db)
            }
        }
    }
}
