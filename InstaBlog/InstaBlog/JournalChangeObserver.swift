import Foundation
import GRDB
import SQLiteData

nonisolated struct JournalChangeToken: Equatable {
    let blogUpdatedAt: Date
    let bloggerCount: Int
    let bloggerUpdatedAt: Date?
    let tripCount: Int
    let tripUpdatedAt: Date?
    let blogItemCount: Int
    let blogItemUpdatedAt: Date?
    let photoItemCount: Int
    let photoItemUpdatedAt: Date?
    let mediaAssetCount: Int
    let mediaAssetUpdatedAt: Date?
}

enum JournalChangeObserver {
    static func observe(
        database: any DatabaseWriter,
        blogID: Blog.ID
    ) -> AsyncValueObservation<JournalChangeToken> {
        ValueObservation
            .tracking { db in
                try token(from: db, blogID: blogID)
            }
            .values(in: database)
    }

    static func token(from db: Database, blogID: Blog.ID) throws -> JournalChangeToken {
        let blog = try Blog.find(db, key: blogID)
        let bloggers = try Blogger
            .where { $0.blogID.eq(blogID) }
            .fetchAll(db)
        let trips = try Trip
            .where { $0.blogID.eq(blogID) }
            .fetchAll(db)
        let items = try BlogItem
            .where { $0.blogID.eq(blogID) }
            .fetchAll(db)
        let photoItems = try PhotoItem
            .where { $0.blogID.eq(blogID) }
            .fetchAll(db)
        let mediaAssets = try MediaAsset
            .where { $0.blogID.eq(blogID) }
            .fetchAll(db)

        return JournalChangeToken(
            blogUpdatedAt: blog.updatedAt,
            bloggerCount: bloggers.count,
            bloggerUpdatedAt: bloggers.map(\.updatedAt).max(),
            tripCount: trips.count,
            tripUpdatedAt: trips.map(\.updatedAt).max(),
            blogItemCount: items.count,
            blogItemUpdatedAt: items.map(\.updatedAt).max(),
            photoItemCount: photoItems.count,
            photoItemUpdatedAt: photoItems.map(\.updatedAt).max(),
            mediaAssetCount: mediaAssets.count,
            mediaAssetUpdatedAt: mediaAssets.map(\.updatedAt).max()
        )
    }
}
