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
        let bloggers = try revision(in: db, table: "bloggers", blogID: blogID)
        let trips = try revision(in: db, table: "trips", blogID: blogID)
        let items = try revision(in: db, table: "blogItems", blogID: blogID)
        let photoItems = try revision(in: db, table: "photoItems", blogID: blogID)
        let mediaAssets = try revision(in: db, table: "mediaAssets", blogID: blogID)

        return JournalChangeToken(
            blogUpdatedAt: blog.updatedAt,
            bloggerCount: bloggers.count,
            bloggerUpdatedAt: bloggers.updatedAt,
            tripCount: trips.count,
            tripUpdatedAt: trips.updatedAt,
            blogItemCount: items.count,
            blogItemUpdatedAt: items.updatedAt,
            photoItemCount: photoItems.count,
            photoItemUpdatedAt: photoItems.updatedAt,
            mediaAssetCount: mediaAssets.count,
            mediaAssetUpdatedAt: mediaAssets.updatedAt
        )
    }

    private static func revision(
        in db: Database,
        table: String,
        blogID: Blog.ID
    ) throws -> JournalTableRevision {
        try JournalTableRevision.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS count, MAX(updatedAt) AS updatedAt FROM \(table) WHERE blogID = ?",
            arguments: [blogID.uuidString]
        ) ?? JournalTableRevision(count: 0, updatedAt: nil)
    }
}

private struct JournalTableRevision: FetchableRecord, Decodable {
    let count: Int
    let updatedAt: Date?
}
