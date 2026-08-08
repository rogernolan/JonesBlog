@preconcurrency import Contacts
import Foundation

nonisolated enum ContactsAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

nonisolated struct ContactGroup: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let contactCount: Int

    var id: String { identifier }
}

nonisolated struct ContactEmailAddress: Equatable, Sendable {
    let address: String
    let label: String?
}

nonisolated struct ContactEntry: Identifiable, Equatable, Sendable {
    let identifier: String
    let displayName: String?
    let emails: [ContactEmailAddress]

    var id: String { identifier }

    var preferredEmail: String? {
        ContactEmailSelection.preferredEmail(in: emails)?.address
    }
}

nonisolated protocol ContactsGroupProviding: Sendable {
    var authorizationStatus: ContactsAuthorizationStatus { get async }
    func requestAccess() async -> ContactsAuthorizationStatus
    func loadGroups() throws -> [ContactGroup]
    func recipients(inGroup identifier: String) throws -> [ContactRecipient]
    func loadAllContacts() throws -> [ContactEntry]
    func recipients(from entries: [ContactEntry]) -> [ContactRecipient]
}

nonisolated struct LiveContactsGroupProvider: ContactsGroupProviding {
    private let store = CNContactStore()

    var authorizationStatus: ContactsAuthorizationStatus {
        get async { Self.map(CNContactStore.authorizationStatus(for: .contacts)) }
    }

    func requestAccess() async -> ContactsAuthorizationStatus {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    func loadGroups() throws -> [ContactGroup] {
        let groups = try store.groups(matching: nil)
        return try groups.map { group in
            ContactGroup(
                identifier: group.identifier,
                name: group.name,
                contactCount: try self.contactCount(inGroup: group.identifier)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func recipients(inGroup identifier: String) throws -> [ContactRecipient] {
        let matching = CNContact.predicateForContactsInGroup(withIdentifier: identifier)
        return Self.recipients(from: try contacts(matching: matching))
    }

    func loadAllContacts() throws -> [ContactEntry] {
        try contacts(matching: nil).map(Self.contactEntry(from:))
    }

    func recipients(from entries: [ContactEntry]) -> [ContactRecipient] {
        Self.recipients(fromEntries: entries)
    }

    private static func recipients(fromEntries entries: [ContactEntry]) -> [ContactRecipient] {
        var seen = Set<String>()
        var result: [ContactRecipient] = []
        for entry in entries {
            guard let email = entry.preferredEmail else { continue }
            let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(ContactRecipient(emailAddress: email, displayName: entry.displayName))
        }
        return result
    }

    private func contacts(matching predicate: NSPredicate?) throws -> [CNContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        if let predicate {
            return try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        }
        let request = CNContactFetchRequest(keysToFetch: keys)
        let collector = ContactCollector()
        try store.enumerateContacts(with: request) { contact, _ in
            collector.append(contact)
        }
        return collector.contacts
    }

    private static func recipients(from contacts: [CNContact]) -> [ContactRecipient] {
        Self.recipients(fromEntries: contacts.map(Self.contactEntry(from:)))
    }

    private static func contactEntry(from contact: CNContact) -> ContactEntry {
        ContactEntry(
            identifier: contact.identifier,
            displayName: displayName(from: contact),
            emails: contact.emailAddresses.map {
                ContactEmailAddress(address: $0.value as String, label: $0.label)
            }
        )
    }

    private static func displayName(from contact: CNContact) -> String? {
        let name = [contact.givenName, contact.middleName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private func contactCount(inGroup identifier: String) throws -> Int {
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
        return try store.unifiedContacts(
            matching: CNContact.predicateForContactsInGroup(withIdentifier: identifier),
            keysToFetch: keys
        ).count
    }

    private static func map(_ status: CNAuthorizationStatus) -> ContactsAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        default:
            return .restricted
        }
    }
}

/// Picks the email address to use when importing a contact. Prefers the first
/// address that is not labelled "other"; falls back to the first address.
nonisolated enum ContactEmailSelection {
    static func preferredEmail(in emails: [ContactEmailAddress]) -> ContactEmailAddress? {
        guard let first = emails.first else { return nil }
        guard let nonOther = emails.first(where: { $0.label?.caseInsensitiveCompare(CNLabelOther) != .orderedSame })
        else { return first }
        return nonOther
    }
}

/// Collects contacts from the enumeration callback of `CNContactStore`.
/// `CNContactStore.enumerateContacts` invokes its block from a single thread,
/// so the array is mutated on one thread only.
nonisolated final class ContactCollector: @unchecked Sendable {
    private(set) var contacts: [CNContact] = []

    func append(_ contact: CNContact) {
        contacts.append(contact)
    }
}
