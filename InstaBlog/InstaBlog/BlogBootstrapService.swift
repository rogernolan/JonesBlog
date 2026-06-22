import Foundation
import SQLiteData

nonisolated struct BootstrapWorkspace: Equatable {
    let blog: Blog
    let blogger: Blogger
    let mailingList: MailingList
}

nonisolated struct BlogBootstrapService {
    private enum BootstrapError: Error {
        case insertDidNotReturnRecord
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

    func bootstrap() throws -> BootstrapWorkspace {
        try database.write { db in
            let timestamp = now()

            let blog: Blog
            let existingBlog = try Blog.order { ($0.createdAt, $0.id) }.fetchOne(db)
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

            let blogger: Blogger
            let existingBlogger = try Blogger
                .where { $0.blogID.eq(blog.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchOne(db)
            if let existingBlogger {
                blogger = existingBlogger
            } else {
                let insertedBlogger = try Blogger.insert {
                    Blogger.Draft(
                        id: uuid(),
                        blogID: blog.id,
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

            return BootstrapWorkspace(
                blog: blog,
                blogger: blogger,
                mailingList: mailingList
            )
        }
    }
}
