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
    let galleryCount: Int
    let galleryUpdatedAt: Date?
    let dayItemCount: Int
    let dayItemUpdatedAt: Date?
    let placementCount: Int
    let placementUpdatedAt: Date?
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
        let galleries = try Gallery
            .where { $0.blogID.eq(blogID) }
            .fetchAll(db)
        let dayItems = try DayItem
            .where { $0.blogID.eq(blogID) }
            .fetchAll(db)
        let dayItemIDs = dayItems.map(\.id)
        let placements: [BlogItemPlacement]
        if dayItemIDs.isEmpty {
            placements = []
        } else {
            placements = try BlogItemPlacement
                .where { $0.dayItemID.in(dayItemIDs) }
                .fetchAll(db)
        }
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
            galleryCount: galleries.count,
            galleryUpdatedAt: galleries.map(\.updatedAt).max(),
            dayItemCount: dayItems.count,
            dayItemUpdatedAt: dayItems.map(\.updatedAt).max(),
            placementCount: placements.count,
            placementUpdatedAt: placements.map(\.updatedAt).max(),
            mediaAssetCount: mediaAssets.count,
            mediaAssetUpdatedAt: mediaAssets.map(\.updatedAt).max()
        )
    }
}
