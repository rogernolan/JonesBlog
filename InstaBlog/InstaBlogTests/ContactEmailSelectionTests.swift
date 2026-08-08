import Contacts
import Foundation
import Testing
@testable import InstaBlog

@Suite("Contact email selection")
struct ContactEmailSelectionTests {
    @Test func prefersFirstNonOtherEmail() {
        let emails = [
            email("other@example.com", label: CNLabelOther),
            email("home@example.com", label: CNLabelHome),
            email("work@example.com", label: CNLabelWork),
        ]

        let selected = ContactEmailSelection.preferredEmail(in: emails)
        #expect(selected?.address == "home@example.com")
    }

    @Test func prefersFirstNonOtherWhenMultipleExist() {
        let emails = [
            email("work@example.com", label: CNLabelWork),
            email("home@example.com", label: CNLabelHome),
        ]

        let selected = ContactEmailSelection.preferredEmail(in: emails)
        #expect(selected?.address == "work@example.com")
    }

    @Test func fallsBackToFirstWhenAllOther() {
        let emails = [
            email("first@example.com", label: CNLabelOther),
            email("second@example.com", label: CNLabelOther),
        ]

        let selected = ContactEmailSelection.preferredEmail(in: emails)
        #expect(selected?.address == "first@example.com")
    }

    @Test func returnsNilForNoEmails() {
        #expect(ContactEmailSelection.preferredEmail(in: []) == nil)
    }

    @Test func treatsUnlabeledEmailAsNonOther() {
        let emails = [
            email("unlabeled@example.com", label: nil),
            email("other@example.com", label: CNLabelOther),
        ]

        let selected = ContactEmailSelection.preferredEmail(in: emails)
        #expect(selected?.address == "unlabeled@example.com")
    }

    @Test func comparesOtherLabelCaseInsensitively() {
        let emails = [
            email("other@example.com", label: CNLabelOther.lowercased()),
            email("home@example.com", label: CNLabelHome),
        ]

        let selected = ContactEmailSelection.preferredEmail(in: emails)
        #expect(selected?.address == "home@example.com")
    }

    private func email(_ value: String, label: String?) -> ContactEmailAddress {
        ContactEmailAddress(address: value, label: label)
    }
}
