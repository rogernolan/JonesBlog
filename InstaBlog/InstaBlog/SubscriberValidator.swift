import Foundation
import SQLiteData

nonisolated struct SubscriberValidator {
    let database: any DatabaseReader

    func validatedEmail(
        _ email: String,
        mailingListID: MailingList.ID,
        excluding subscriberID: Subscriber.ID? = nil
    ) throws -> String {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw ModelValidationError.emptySubscriberEmail
        }

        let duplicateCount = try database.read { db in
            if let subscriberID {
                return try Subscriber
                    .where {
                        $0.mailingListID.eq(#bind(mailingListID))
                            && $0.emailAddress.collate(.nocase).eq(#bind(email))
                            && !$0.id.eq(#bind(subscriberID))
                    }
                    .count()
                    .fetchOne(db) ?? 0
            }

            return try Subscriber
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
