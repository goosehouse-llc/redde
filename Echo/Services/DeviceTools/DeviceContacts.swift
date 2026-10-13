import Contacts
import Foundation

/// The contacts tool: looking someone up. Reading only; nothing here adds to or changes the
/// address book.
nonisolated enum DeviceContacts {
    static func allowed() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .notDetermined: return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        default: return false
        }
    }

    /// `query`: a name, or part of one; a phone number or an email address finds whose it is.
    static func search(_ args: JSONValue) async throws -> JSONValue {
        guard await allowed() else { throw DeviceToolError.refused(.contacts) }
        let query = try args.required("query")
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor, CNContactBirthdayKey as CNKeyDescriptor,
        ]
        var predicates = [CNContact.predicateForContacts(matchingName: query)]
        if query.contains("@") { predicates.append(CNContact.predicateForContacts(matchingEmailAddress: query)) }
        if query.filter(\.isNumber).count >= 5 { predicates.append(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))) }
        var found: [CNContact] = []
        var seen: Set<String> = []
        do {
            for predicate in predicates {
                for contact in try store.unifiedContacts(matching: predicate, keysToFetch: keys) where seen.insert(contact.identifier).inserted {
                    found.append(contact)
                }
            }
        } catch {
            throw DeviceToolError("Contacts couldn't be searched: \(error.localizedDescription)")
        }
        let limit = args.limit(default: 10, most: 50)
        return .object([
            "contacts": .array(found.prefix(limit).map(describe)),
            "more": .number(Double(max(0, found.count - limit))),
        ])
    }

    private static func describe(_ contact: CNContact) -> JSONValue {
        func label(_ raw: String?) -> String { raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
        var fields: [String: JSONValue] = [
            "name": .string(CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName),
        ]
        if !contact.nickname.isEmpty { fields["nickname"] = .string(contact.nickname) }
        if !contact.organizationName.isEmpty { fields["organization"] = .string(contact.organizationName) }
        if !contact.jobTitle.isEmpty { fields["job_title"] = .string(contact.jobTitle) }
        if !contact.phoneNumbers.isEmpty {
            fields["phones"] = .array(contact.phoneNumbers.map { .object(["label": .string(label($0.label)), "number": .string($0.value.stringValue)]) })
        }
        if !contact.emailAddresses.isEmpty {
            fields["emails"] = .array(contact.emailAddresses.map { .object(["label": .string(label($0.label)), "address": .string($0.value as String)]) })
        }
        if !contact.postalAddresses.isEmpty {
            fields["addresses"] = .array(contact.postalAddresses.map {
                .object(["label": .string(label($0.label)),
                         "address": .string(CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", "))])
            })
        }
        if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
            fields["birthday"] = .string(birthday.year.map { String(format: "%04d-%02d-%02d", $0, month, day) } ?? String(format: "%02d-%02d", month, day))
        }
        return .object(fields)
    }
}
