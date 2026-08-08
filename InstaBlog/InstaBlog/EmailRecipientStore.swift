import Foundation
import SQLiteData

nonisolated enum EmailRecipientStoreError: LocalizedError, Equatable {
    case missingMailingList
    case inactiveBlogMutation

    var errorDescription: String? {
        switch self {
        case .missingMailingList:
            "The recipient list is unavailable."
        case .inactiveBlogMutation:
            "This recipient belongs to another Blog."
        }
    }
}

nonisolated struct ContactRecipient: Equatable, Sendable {
    let emailAddress: String
    let displayName: String?
}

nonisolated struct ContactRecipientImportSummary: Equatable, Sendable {
    let added: Int
    let skipped: Int
}

nonisolated struct EmailRecipientStore: Sendable {
    let database: any DatabaseWriter
    let blogID: Blog.ID?
    let now: @Sendable () -> Date

    init(
        database: any DatabaseWriter,
        blogID: Blog.ID? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.blogID = blogID
        self.now = now
    }

    func loadRecipients() throws -> [Subscriber] {
        try database.read { db in
            guard let mailingList = try resolveMailingList(in: db) else { return [] }
            return try Subscriber
                .where { $0.mailingListID.eq(mailingList.id) }
                .order { ($0.createdAt, $0.id) }
                .fetchAll(db)
        }
    }

    func loadRecipientEmailAddresses() throws -> [String] {
        try loadRecipients().map(\.emailAddress)
    }

    @discardableResult
    func addRecipient(emailAddress: String, displayName: String?) throws -> Subscriber.ID {
        try database.write { db in
            guard let mailingList = try resolveMailingList(in: db) else {
                throw EmailRecipientStoreError.missingMailingList
            }
            let email = try SubscriberValidator(database: database).validatedEmail(
                emailAddress,
                mailingListID: mailingList.id,
                in: db
            )
            let timestamp = now()
            let id = UUID()
            try Subscriber.insert {
                Subscriber.Draft(
                    id: id,
                    blogID: mailingList.blogID,
                    mailingListID: mailingList.id,
                    emailAddress: email,
                    displayName: trimmedDisplayName(displayName),
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            }
            .execute(db)
            return id
        }
    }

    func updateRecipient(id: Subscriber.ID, emailAddress: String, displayName: String?) throws {
        try database.write { db in
            guard let mailingList = try resolveMailingList(in: db) else {
                throw EmailRecipientStoreError.missingMailingList
            }
            let subscriber = try Subscriber.find(db, key: id)
            guard subscriber.mailingListID == mailingList.id else {
                throw EmailRecipientStoreError.inactiveBlogMutation
            }
            let email = try SubscriberValidator(database: database).validatedEmail(
                emailAddress,
                mailingListID: mailingList.id,
                excluding: id,
                in: db
            )
            try Subscriber.find(id).update {
                $0.emailAddress = #bind(email)
                $0.displayName = #bind(trimmedDisplayName(displayName))
                $0.updatedAt = #bind(now())
            }
            .execute(db)
        }
    }

    func deleteRecipient(id: Subscriber.ID) throws {
        try database.write { db in
            guard let mailingList = try resolveMailingList(in: db) else {
                throw EmailRecipientStoreError.missingMailingList
            }
            let subscriber = try Subscriber.find(db, key: id)
            guard subscriber.mailingListID == mailingList.id else {
                throw EmailRecipientStoreError.inactiveBlogMutation
            }
            try Subscriber.find(id).delete().execute(db)
        }
    }

    /// Inserts candidate recipients that are new to the active mailing list,
    /// matching case-insensitively. Existing or empty addresses are skipped.
    @discardableResult
    func importRecipients(_ candidates: [ContactRecipient]) throws -> ContactRecipientImportSummary {
        try database.write { db in
            guard let mailingList = try resolveMailingList(in: db) else {
                throw EmailRecipientStoreError.missingMailingList
            }
            var seen = Set(try Subscriber
                .where { $0.mailingListID.eq(mailingList.id) }
                .select(\.emailAddress)
                .fetchAll(db)
                .map { $0.lowercased() })
            let timestamp = now()
            var added = 0
            for candidate in candidates {
                let email = candidate.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = email.lowercased()
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                try Subscriber.insert {
                    Subscriber.Draft(
                        id: UUID(),
                        blogID: mailingList.blogID,
                        mailingListID: mailingList.id,
                        emailAddress: email,
                        displayName: trimmedDisplayName(candidate.displayName),
                        createdAt: timestamp,
                        updatedAt: timestamp
                    )
                }
                .execute(db)
                added += 1
            }
            return ContactRecipientImportSummary(added: added, skipped: candidates.count - added)
        }
    }

    private func resolveMailingList(in db: Database) throws -> MailingList? {
        guard let blog = try requireActiveBlog(in: db) else { return nil }
        return try MailingList
            .where { $0.blogID.eq(blog.id) }
            .order { ($0.createdAt, $0.id) }
            .fetchOne(db)
    }

    private func requireActiveBlog(in db: Database) throws -> Blog? {
        let workspaceBlogID = try AppWorkspace
            .find(AppWorkspace.singletonID)
            .select(\.activeBlogID)
            .fetchOne(db) ?? nil
        let oldestBlogID = try Blog.order { ($0.createdAt, $0.id) }.select(\.id).fetchOne(db)
        let activeBlogID = workspaceBlogID ?? blogID ?? oldestBlogID
        guard let activeBlogID, let blog = try Blog.find(activeBlogID).fetchOne(db) else {
            return nil
        }
        guard self.blogID == nil || self.blogID == activeBlogID else {
            throw EmailRecipientStoreError.inactiveBlogMutation
        }
        return blog
    }

    private func trimmedDisplayName(_ displayName: String?) -> String? {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
