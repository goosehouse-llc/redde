import Contacts
import Foundation
import MessageUI
import UIKit

/// Someone in Contacts, as far as reaching them goes: their name and what they can be reached at.
nonisolated struct Reachable: Equatable, Sendable {
    nonisolated struct Line: Equatable, Sendable {
        /// "mobile", "work"; empty when the contact gives none.
        var label: String
        var value: String
    }
    var name: String
    var phones: [Line] = []
    var emails: [Line] = []
}

nonisolated enum MessageOutcome: Sendable { case sent, cancelled, failed }

/// What calling and messaging need of iOS; stand-ins in tests.
nonisolated protocol PeopleReaching: Sendable {
    /// The contacts a name matches.
    func find(_ name: String) async throws -> [Reachable]
    /// Hands iOS an address to open (`tel:`, `facetime:`). False when this device can't.
    func open(_ url: URL) async -> Bool
    func canText() async -> Bool
    /// Puts up the Messages sheet with the message written, and says how the person left it.
    func compose(to recipients: [String], text: String) async -> MessageOutcome
}

/// The tools that reach a person: start a call, and write a message for the person to send.
/// Neither goes out on Redde's say-so. A call is handed to iOS, which asks "Call…?" itself, and
/// a message is put into the Messages sheet, where sending is a tap of the person's own: no app
/// may send one. So Redde doesn't ask first, as it doesn't before iOS asks about deleting
/// photos. The agent is not on the call and reads no messages.
nonisolated struct DevicePeople: Sendable {
    var system: any PeopleReaching = SystemPeople()

    static let longestMessage = 2000

    /// `to` (a number, or a name in Contacts), and optionally `label` (which of their numbers)
    /// and `kind` (phone, facetime, facetime_audio).
    func call(_ args: JSONValue, contactsOn: Bool) async throws -> JSONValue {
        let to = try args.required("to")
        let scheme = switch (args["kind"]?.string ?? "phone").lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") {
        case "phone", "call", "": "tel:"
        case "facetime", "facetime_video", "video": "facetime://"
        case "facetime_audio", "audio": "facetime-audio://"
        default: throw DeviceToolError("\"kind\" is phone, facetime or facetime_audio.")
        }
        let who = try await resolve(to, label: args["label"]?.string, contactsOn: contactsOn, emailToo: scheme != "tel:")
        let address = who.address.contains("@") ? who.address : Self.dialable(who.address)
        guard !address.isEmpty, let url = URL(string: scheme + (address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address)) else {
            throw DeviceToolError("\"\(to)\" isn't a number that can be called.")
        }
        guard await system.open(url) else {
            throw DeviceToolError(scheme == "tel:" ? "This device couldn't start the call. It may be one that makes no phone calls, like an iPad." : "This device couldn't start FaceTime.")
        }
        var answer: [String: JSONValue] = [
            "asked": .string("The iPhone is asking the person whether to call \(who.shown). Redde isn't told whether they went ahead."),
            "to": .string(who.name),
        ]
        if !who.label.isEmpty { answer["label"] = .string(who.label) }
        return .object(answer)
    }

    /// `to` (a number, an address, a name in Contacts, or several) and `text`.
    func message(_ args: JSONValue, contactsOn: Bool) async throws -> JSONValue {
        let text = try args.required("text")
        guard text.count <= Self.longestMessage else { throw DeviceToolError("A message holds \(Self.longestMessage) characters at most; this one has \(text.count).") }
        let asked = args["to"]?.array?.compactMap(\.string) ?? args["to"]?.string.map { $0.split(separator: ",").map(String.init) } ?? []
        let names = asked.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw DeviceToolError.missing("to") }
        guard await system.canText() else { throw DeviceToolError("This device can't send messages.") }
        var people: [(name: String, label: String, address: String, shown: String)] = []
        for name in names { people.append(try await resolve(name, label: args["label"]?.string, contactsOn: contactsOn, emailToo: true)) }
        let recipients = people.map { $0.address.contains("@") ? $0.address : Self.dialable($0.address) }
        switch await system.compose(to: recipients, text: text) {
        case .sent: return .object(["sent": .bool(true), "to": .array(people.map { .string($0.name) })])
        case .cancelled: return .object(["sent": .bool(false), "note": .string("The person closed the message without sending it.")])
        case .failed: throw DeviceToolError("The message couldn't be sent.")
        }
    }

    /// Digits, with a leading plus kept: what a `tel:` address and Messages take.
    static func dialable(_ number: String) -> String {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("+") ? "+" : "") + trimmed.filter { $0.isNumber || $0 == "*" || $0 == "#" }
    }

    /// Written as a number: digits and what goes between them, at least three digits.
    static func isNumber(_ text: String) -> Bool {
        text.filter(\.isNumber).count >= 3 && text.allSatisfy { $0.isNumber || " +-().*#".contains($0) }
    }

    /// Whom `to` means: a number or an address as it stands, or a name looked up in Contacts,
    /// which takes the Contacts area. One person and one of their numbers, or an error that
    /// says what to ask: guessing between two Danas, or between someone's mobile and their
    /// work line, is not for a tool that makes a phone ring.
    private func resolve(_ to: String, label: String?, contactsOn: Bool, emailToo: Bool) async throws -> (name: String, label: String, address: String, shown: String) {
        if Self.isNumber(to) || (emailToo && to.contains("@") && !to.contains(" ")) { return (to, "", to, to) }
        guard contactsOn else {
            throw DeviceToolError("To reach someone by name, Contacts has to be on in Redde on the iPhone (Settings → Phone tools). Or give their number.")
        }
        var found = try await system.find(to)
        if found.count > 1, let exact = found.first(where: { $0.name.caseInsensitiveCompare(to) == .orderedSame }) { found = [exact] }
        guard let person = found.first else { throw DeviceToolError("Nobody in Contacts matches \"\(to)\".") }
        guard found.count == 1 else {
            throw DeviceToolError("Several contacts match \"\(to)\": \(found.prefix(6).map(\.name).joined(separator: ", ")). Ask which one, and give the full name.")
        }
        let all = Self.distinct(person.phones.isEmpty && emailToo ? person.emails : person.phones)
        guard !all.isEmpty else { throw DeviceToolError("\(person.name) has no phone number in Contacts.") }
        var lines = all
        if let wanted = label?.trimmingCharacters(in: .whitespaces).lowercased(), !wanted.isEmpty {
            lines = lines.filter { Self.fits($0, wanted) }
            guard !lines.isEmpty else {
                throw DeviceToolError("\(person.name) has no number labelled \"\(wanted)\". There are: \(Self.labels(all)).")
            }
        }
        if lines.count > 1 {
            // A mobile is what a person means, when there is exactly one.
            let mobile = lines.filter { ["mobile", "iphone"].contains($0.label.lowercased()) }
            guard mobile.count == 1 else {
                throw DeviceToolError("\(person.name) has several numbers: \(Self.labels(lines)). Ask which one, and give it as \"label\" (where two share a label, their last four digits).")
            }
            lines = mobile
        }
        let line = lines[0]
        return (person.name, line.label, line.value, line.label.isEmpty ? person.name : "\(person.name) (\(line.label))")
    }

    /// One of each: the same number in a contact twice (synced in twice, or once with the
    /// country code and once without) is one number, not a choice to ask about.
    static func distinct(_ lines: [Reachable.Line]) -> [Reachable.Line] {
        var kept: [Reachable.Line] = []
        for line in lines where !kept.contains(where: { same($0.value, line.value) }) { kept.append(line) }
        return kept
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        if a.contains("@") || b.contains("@") { return a.lowercased() == b.lowercased() }
        let (x, y) = (a.filter(\.isNumber), b.filter(\.isNumber))
        return min(x.count, y.count) >= 7 ? x.hasSuffix(y) || y.hasSuffix(x) : x == y
    }

    /// Whether a line is the one asked for: by a word of its label, or by the last digits of its
    /// number, which is what tells apart two that share a label.
    private static func fits(_ line: Reachable.Line, _ wanted: String) -> Bool {
        wanted.allSatisfy(\.isNumber) ? line.value.filter(\.isNumber).hasSuffix(wanted) : line.label.lowercased().contains(wanted)
    }

    /// The choices as the agent can give them back: labels, and the last four digits where two share one.
    private static func labels(_ lines: [Reachable.Line]) -> String {
        let named = lines.map { $0.label.isEmpty ? "one without a label" : $0.label }
        return zip(lines, named).map { line, name in
            guard named.filter({ $0 == name }).count > 1, !line.value.contains("@") else { return name }
            return "\(name) ending \(line.value.filter(\.isNumber).suffix(4))"
        }.joined(separator: ", ")
    }
}

/// Contacts, `UIApplication` and the Messages sheet.
nonisolated struct SystemPeople: PeopleReaching {
    func find(_ name: String) async throws -> [Reachable] {
        guard await DeviceContacts.allowed() else { throw DeviceToolError.refused(.contacts) }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
                                       CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
        func label(_ raw: String?) -> String { raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
        do {
            return try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys).map { contact in
                Reachable(name: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName,
                          phones: contact.phoneNumbers.map { .init(label: label($0.label), value: $0.value.stringValue) },
                          emails: contact.emailAddresses.map { .init(label: label($0.label), value: $0.value as String) })
            }
        } catch {
            throw DeviceToolError("Contacts couldn't be searched: \(error.localizedDescription)")
        }
    }

    func open(_ url: URL) async -> Bool { await Self.hand(url) }

    @MainActor private static func hand(_ url: URL) async -> Bool { await UIApplication.shared.open(url) }

    func canText() async -> Bool { await MainActor.run { MFMessageComposeViewController.canSendText() } }

    func compose(to recipients: [String], text: String) async -> MessageOutcome { await MessageSheet.shared.present(to: recipients, text: text) }
}

/// The Messages sheet over whatever Redde is showing, one at a time.
final class MessageSheet: NSObject, MFMessageComposeViewControllerDelegate {
    static let shared = MessageSheet()
    private var done: ((MessageOutcome) -> Void)?

    func present(to recipients: [String], text: String) async -> MessageOutcome {
        guard done == nil, MFMessageComposeViewController.canSendText(),
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return .failed }
        while let presented = top.presentedViewController { top = presented }
        let sheet = MFMessageComposeViewController()
        sheet.recipients = recipients
        sheet.body = text
        sheet.messageComposeDelegate = self
        return await withCheckedContinuation { finished in
            done = { finished.resume(returning: $0) }
            top.present(sheet, animated: true)
        }
    }

    /// Declared for any thread, as every callback of iOS's is here; the work is done on the main one.
    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        let outcome: MessageOutcome = switch result {
        case .sent: .sent
        case .cancelled: .cancelled
        default: .failed
        }
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.done?(outcome)
            self.done = nil
        }
    }
}
