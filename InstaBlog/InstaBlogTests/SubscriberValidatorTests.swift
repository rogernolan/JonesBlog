import Foundation
import GRDB
import Testing
@testable import InstaBlog

@Suite("Subscriber validation")
struct SubscriberValidatorTests {
    @Test func trimsSubscriberEmail() throws {
        let fixture = try Fixture()

        let email = try fixture.validator.validatedEmail(
            "  Rog@example.com ",
            mailingListID: fixture.firstListID
        )

        #expect(email == "Rog@example.com")
    }

    @Test(arguments: ["", " \t ", "\n"])
    func rejectsEmptySubscriberEmail(_ email: String) throws {
        let fixture = try Fixture()

        #expect(throws: ModelValidationError.emptySubscriberEmail) {
            try fixture.validator.validatedEmail(email, mailingListID: fixture.firstListID)
        }
    }

    @Test func rejectsCaseInsensitiveDuplicateInSameMailingList() throws {
        let fixture = try Fixture()
        try fixture.insertSubscriber(email: "Rog@example.com", mailingListID: fixture.firstListID)

        #expect(throws: ModelValidationError.duplicateSubscriberEmail) {
            try fixture.validator.validatedEmail(
                "rog@EXAMPLE.com",
                mailingListID: fixture.firstListID
            )
        }
    }

    @Test func allowsSameEmailInDifferentMailingList() throws {
        let fixture = try Fixture()
        try fixture.insertSubscriber(email: "Rog@example.com", mailingListID: fixture.firstListID)

        let email = try fixture.validator.validatedEmail(
            "rog@EXAMPLE.com",
            mailingListID: fixture.secondListID
        )

        #expect(email == "rog@EXAMPLE.com")
    }

    @Test func allowsExistingSubscriberWhenEditingItself() throws {
        let fixture = try Fixture()
        let subscriberID = UUID()
        try fixture.insertSubscriber(
            id: subscriberID,
            email: "Rog@example.com",
            mailingListID: fixture.firstListID
        )

        let email = try fixture.validator.validatedEmail(
            "rog@EXAMPLE.com",
            mailingListID: fixture.firstListID,
            excluding: subscriberID
        )

        #expect(email == "rog@EXAMPLE.com")
    }

    @Test func excludingSubscriberDoesNotHideAnotherDuplicate() throws {
        let fixture = try Fixture()
        let excludedID = UUID()
        try fixture.insertSubscriber(
            id: excludedID,
            email: "Rog@example.com",
            mailingListID: fixture.firstListID
        )
        try fixture.insertSubscriber(
            email: "ROG@example.com",
            mailingListID: fixture.firstListID
        )

        #expect(throws: ModelValidationError.duplicateSubscriberEmail) {
            try fixture.validator.validatedEmail(
                "rog@EXAMPLE.com",
                mailingListID: fixture.firstListID,
                excluding: excludedID
            )
        }
    }
}

private struct Fixture {
    let database: any DatabaseWriter
    let firstBlogID = UUID()
    let secondBlogID = UUID()
    let firstListID = UUID()
    let secondListID = UUID()

    var validator: SubscriberValidator {
        SubscriberValidator(database: database)
    }

    init() throws {
        database = try AppDatabase.makeInMemory()

        try database.write { db in
            for blogID in [firstBlogID, secondBlogID] {
                try db.execute(
                    sql: "INSERT INTO blogs (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                    arguments: [Self.databaseString(blogID), Self.date, Self.date]
                )
            }
            try db.execute(
                sql: "INSERT INTO mailingLists (id, blogID, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [
                    Self.databaseString(firstListID),
                    Self.databaseString(firstBlogID),
                    Self.date,
                    Self.date,
                ]
            )
            try db.execute(
                sql: "INSERT INTO mailingLists (id, blogID, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [
                    Self.databaseString(secondListID),
                    Self.databaseString(secondBlogID),
                    Self.date,
                    Self.date,
                ]
            )
        }
    }

    func insertSubscriber(
        id: UUID = UUID(),
        email: String,
        mailingListID: MailingList.ID
    ) throws {
        let blogID = mailingListID == firstListID ? firstBlogID : secondBlogID
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO subscribers
                      (id, blogID, mailingListID, emailAddress, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Self.databaseString(id),
                    Self.databaseString(blogID),
                    Self.databaseString(mailingListID),
                    email,
                    Self.date,
                    Self.date,
                ]
            )
        }
    }

    private static let date = "2027-01-15 08:00:00.000"

    private static func databaseString(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
