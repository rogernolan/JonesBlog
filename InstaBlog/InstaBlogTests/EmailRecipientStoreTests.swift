import Foundation
import GRDB
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Email recipient store")
struct EmailRecipientStoreTests {
    @Test func loadRecipientsReturnsEmptyInitially() throws {
        let fixture = try Fixture()

        let recipients = try fixture.store.loadRecipients()

        #expect(recipients.isEmpty)
    }

    @Test func addsRecipientAndTrimsInput() throws {
        let fixture = try Fixture()

        let id = try fixture.store.addRecipient(
            emailAddress: "  Rog@Example.com ",
            displayName: "  Rog  "
        )

        let recipients = try fixture.store.loadRecipients()
        #expect(recipients.count == 1)
        #expect(recipients.first?.id == id)
        #expect(recipients.first?.emailAddress == "Rog@Example.com")
        #expect(recipients.first?.displayName == "Rog")
        #expect(recipients.first?.blogID == fixture.blogID)
        #expect(recipients.first?.mailingListID == fixture.mailingListID)
    }

    @Test func trimsWhitespaceOnlyDisplayNameToNil() throws {
        let fixture = try Fixture()

        _ = try fixture.store.addRecipient(
            emailAddress: "jane@example.com",
            displayName: "   "
        )

        #expect(try fixture.store.loadRecipients().first?.displayName == nil)
    }

    @Test func rejectsDuplicateEmailCaseInsensitively() throws {
        let fixture = try Fixture()
        _ = try fixture.store.addRecipient(emailAddress: "Rog@example.com", displayName: nil)

        #expect(throws: ModelValidationError.duplicateSubscriberEmail) {
            try fixture.store.addRecipient(emailAddress: "ROG@EXAMPLE.com", displayName: nil)
        }
    }

    @Test func updatesRecipientEmailAndDisplayName() throws {
        let fixture = try Fixture()
        let id = try fixture.store.addRecipient(
            emailAddress: "rog@example.com",
            displayName: "Rog"
        )

        try fixture.store.updateRecipient(
            id: id,
            emailAddress: "  rog.nolan@example.com  ",
            displayName: "Rog Nolan"
        )

        let recipient = try #require(try fixture.store.loadRecipients().first)
        #expect(recipient.emailAddress == "rog.nolan@example.com")
        #expect(recipient.displayName == "Rog Nolan")
    }

    @Test func updatingToAnotherRecipientsEmailThrows() throws {
        let fixture = try Fixture()
        let firstID = try fixture.store.addRecipient(emailAddress: "rog@example.com", displayName: nil)
        let secondID = try fixture.store.addRecipient(emailAddress: "jane@example.com", displayName: nil)

        #expect(throws: ModelValidationError.duplicateSubscriberEmail) {
            try fixture.store.updateRecipient(
                id: secondID,
                emailAddress: "Rog@example.com",
                displayName: nil
            )
        }
        #expect(try fixture.store.loadRecipients().count == 2)
        #expect(try fixture.store.loadRecipients().contains { $0.id == firstID })
    }

    @Test func updatingRecipientToItsOwnEmailIsAllowed() throws {
        let fixture = try Fixture()
        let id = try fixture.store.addRecipient(emailAddress: "Rog@example.com", displayName: nil)

        try fixture.store.updateRecipient(
            id: id,
            emailAddress: "ROG@example.com",
            displayName: "Rog"
        )

        let recipient = try #require(try fixture.store.loadRecipients().first)
        #expect(recipient.emailAddress == "ROG@example.com")
        #expect(recipient.displayName == "Rog")
    }

    @Test func deletesRecipient() throws {
        let fixture = try Fixture()
        let id = try fixture.store.addRecipient(emailAddress: "rog@example.com", displayName: nil)

        try fixture.store.deleteRecipient(id: id)

        #expect(try fixture.store.loadRecipients().isEmpty)
    }

    @Test func importAddsOnlyNewAddressesAndReportsCounts() throws {
        let fixture = try Fixture()
        _ = try fixture.store.addRecipient(emailAddress: "Rog@example.com", displayName: nil)

        let summary = try fixture.store.importRecipients([
            ContactRecipient(emailAddress: "ROG@example.com", displayName: "Duplicate"),
            ContactRecipient(emailAddress: "jane@example.com", displayName: "Jane"),
            ContactRecipient(emailAddress: "  ", displayName: nil),
            ContactRecipient(emailAddress: "JANE@example.com", displayName: "Jane again"),
            ContactRecipient(emailAddress: "bob@example.com", displayName: nil),
        ])

        #expect(summary.added == 2)
        #expect(summary.skipped == 3)
        let emails = try fixture.store.loadRecipients().map(\.emailAddress).sorted()
        #expect(emails == ["Rog@example.com", "bob@example.com", "jane@example.com"])
    }

    @Test func importSkipsExistingAddressesCaseInsensitively() throws {
        let fixture = try Fixture()
        _ = try fixture.store.addRecipient(emailAddress: "rog@example.com", displayName: nil)

        let summary = try fixture.store.importRecipients([
            ContactRecipient(emailAddress: "ROG@EXAMPLE.COM", displayName: "Rog"),
        ])

        #expect(summary.added == 0)
        #expect(summary.skipped == 1)
        #expect(try fixture.store.loadRecipients().count == 1)
    }

    @Test func importStoresContactDisplayName() throws {
        let fixture = try Fixture()

        let summary = try fixture.store.importRecipients([
            ContactRecipient(emailAddress: "jane@example.com", displayName: "Jane Doe"),
        ])

        #expect(summary.added == 1)
        let recipient = try #require(try fixture.store.loadRecipients().first)
        #expect(recipient.emailAddress == "jane@example.com")
        #expect(recipient.displayName == "Jane Doe")
    }

    @Test func loadRecipientEmailAddressesReturnsAllEmails() throws {
        let fixture = try Fixture()
        _ = try fixture.store.addRecipient(emailAddress: "rog@example.com", displayName: "Rog")
        _ = try fixture.store.addRecipient(emailAddress: "jane@example.com", displayName: nil)

        #expect(
            try fixture.store.loadRecipientEmailAddresses().sorted()
                == ["jane@example.com", "rog@example.com"]
        )
    }

    @Test func recipientsAreScopedToActiveBlog() throws {
        let fixture = try Fixture()
        _ = try fixture.store.addRecipient(emailAddress: "rog@example.com", displayName: nil)
        try fixture.insertSubscriber(
            email: "jane@example.com",
            listID: fixture.secondListID,
            blogID: fixture.secondBlogID
        )

        let scopedStore = EmailRecipientStore(database: fixture.database)
        #expect(try scopedStore.loadRecipients().map(\.emailAddress) == ["rog@example.com"])

        try fixture.setActiveBlog(fixture.secondBlogID)
        #expect(try scopedStore.loadRecipients().map(\.emailAddress) == ["jane@example.com"])
    }
}

private struct Fixture {
    let database: any DatabaseWriter
    let blogID = UUID()
    let secondBlogID = UUID()
    let mailingListID = UUID()
    let secondListID = UUID()

    var store: EmailRecipientStore {
        EmailRecipientStore(database: database, blogID: blogID)
    }

    init() throws {
        database = try AppDatabase.makeInMemory()

        try database.write { db in
            for blogID in [self.blogID, secondBlogID] {
                try db.execute(
                    sql: "INSERT INTO blogs (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                    arguments: [Self.databaseString(blogID), Self.date, Self.date]
                )
            }
            for (listID, blogID) in [(mailingListID, self.blogID), (secondListID, secondBlogID)] {
                try db.execute(
                    sql: "INSERT INTO mailingLists (id, blogID, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                    arguments: [
                        Self.databaseString(listID),
                        Self.databaseString(blogID),
                        Self.date,
                        Self.date,
                    ]
                )
            }
            try db.execute(
                sql: "UPDATE appWorkspaces SET activeBlogID = ? WHERE id = 'default'",
                arguments: [Self.databaseString(self.blogID)]
            )
        }
    }

    func insertSubscriber(email: String, listID: UUID, blogID: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO subscribers
                      (id, blogID, mailingListID, emailAddress, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Self.databaseString(UUID()),
                    Self.databaseString(blogID),
                    Self.databaseString(listID),
                    email,
                    Self.date,
                    Self.date,
                ]
            )
        }
    }

    func setActiveBlog(_ id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE appWorkspaces SET activeBlogID = ? WHERE id = 'default'",
                arguments: [Self.databaseString(id)]
            )
        }
    }

    static let date = "2027-01-15 08:00:00.000"

    static func databaseString(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
