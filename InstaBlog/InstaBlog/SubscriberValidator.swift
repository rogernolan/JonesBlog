import Foundation
import SQLiteData

nonisolated struct SubscriberValidator {
    let database: any DatabaseReader

    func validatedEmail(
        _ email: String,
        mailingListID: MailingList.ID,
        excluding subscriberID: Subscriber.ID? = nil
    ) throws -> String {
        try database.read { db in
            try validatedEmail(
                email,
                mailingListID: mailingListID,
                excluding: subscriberID,
                in: db
            )
        }
    }

    /// Validates against the caller's open database connection so the duplicate
    /// check and the subsequent write share one transaction.
    func validatedEmail(
        _ email: String,
        mailingListID: MailingList.ID,
        excluding subscriberID: Subscriber.ID? = nil,
        in db: Database
    ) throws -> String {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw ModelValidationError.emptySubscriberEmail
        }

        let duplicateCount: Int
        if let subscriberID {
            duplicateCount = try Subscriber
                .where {
                    $0.mailingListID.eq(#bind(mailingListID))
                        && $0.emailAddress.collate(.nocase).eq(#bind(email))
                        && !$0.id.eq(#bind(subscriberID))
                }
                .count()
                .fetchOne(db) ?? 0
        } else {
            duplicateCount = try Subscriber
                .where {
                    $0.mailingListID.eq(#bind(mailingListID))
                        && $0.emailAddress.collate(.nocase).eq(#bind(email))
                }
                .count()
                .fetchOne(db) ?? 0
        }

        guard duplicateCount == 0 else {
            throw ModelValidationError.duplicateSubscriberEmail
        }
        return email
    }
}
