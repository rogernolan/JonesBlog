import Foundation
import GRDB
import SQLiteData
import StructuredQueriesCore
import Testing
@testable import InstaBlog

@Suite("Journal change observation")
struct JournalChangeObserverTests {
    @Test func tokenTracksLargeJournalWithAggregateRevisions() throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        try database.write { db in
            for offset in 0..<250 {
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                try BlogItem.insert {
                    BlogItem.Draft(
                        blogID: workspace.blog.id,
                        authorID: workspace.blogger.id,
                        blogText: "Journal item \(offset)",
                        createdAt: timestamp,
                        updatedAt: timestamp,
                        itemDate: timestamp,
                        localDay: "2027-01-15"
                    )
                }.execute(db)
            }
        }

        let token = try database.read { db in
            try JournalChangeObserver.token(from: db, blogID: workspace.blog.id)
        }

        #expect(token.blogItemCount == 250)
        #expect(token.blogItemUpdatedAt == baseDate.addingTimeInterval(249))
    }

    @Test func tokenChangesWhenActiveBlogContentChanges() throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        let baseline = try database.read { db in
            try JournalChangeObserver.token(from: db, blogID: workspace.blog.id)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try database.write { db in
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: workspace.blog.id,
                    authorID: workspace.blogger.id,
                    blogText: "Imported from shared blog",
                    createdAt: now,
                    updatedAt: now,
                    itemDate: now,
                    localDay: "2026-07-10"
                )
            }.execute(db)
        }

        let updated = try database.read { db in
            try JournalChangeObserver.token(from: db, blogID: workspace.blog.id)
        }
        #expect(updated != baseline)
    }

    @Test func tokenIgnoresOtherBlogs() throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        let otherBlog = try database.write { db in
            try Blog.insert {
                Blog.Draft(
                    title: "Other",
                    createdAt: .now,
                    updatedAt: .now
                )
            }
            .returning(\.self)
            .fetchOne(db)
        }
        let other = try #require(otherBlog)
        let otherBloggerID = UUID()
        let baseline = try database.read { db in
            try JournalChangeObserver.token(from: db, blogID: workspace.blog.id)
        }

        try database.write { db in
            try Blogger.insert {
                Blogger.Draft(
                    id: otherBloggerID,
                    blogID: other.id,
                    displayName: "Jane",
                    createdAt: .now,
                    updatedAt: .now
                )
            }.execute(db)
            try BlogItem.insert {
                BlogItem.Draft(
                    blogID: other.id,
                    authorID: otherBloggerID,
                    blogText: "Other blog item",
                    createdAt: .now,
                    updatedAt: .now,
                    itemDate: .now,
                    localDay: "2026-07-10"
                )
            }.execute(db)
        }

        let unchanged = try database.read { db in
            try JournalChangeObserver.token(from: db, blogID: workspace.blog.id)
        }
        #expect(unchanged == baseline)
    }
}
