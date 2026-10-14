import Foundation
import Testing
@testable import Echo

/// Calling and messaging against a stand-in for Contacts, iOS and the Messages sheet: whom a
/// name means, what is handed to iOS, and what the agent is told. That iOS asks before a call
/// and that a message waits for the person's tap can only be seen on a phone.
struct PhonePeopleTests {
    final class FakeReach: PeopleReaching, @unchecked Sendable {
        private let lock = NSLock()
        private var state = (people: [Reachable](), opened: [URL](), composed: [(to: [String], text: String)](), opens: true, texts: true,
                             outcome: MessageOutcome.sent, searches: [String]())
        var people: [Reachable] { get { lock.withLock { state.people } } set { lock.withLock { state.people = newValue } } }
        var opens: Bool { get { lock.withLock { state.opens } } set { lock.withLock { state.opens = newValue } } }
        var texts: Bool { get { lock.withLock { state.texts } } set { lock.withLock { state.texts = newValue } } }
        var outcome: MessageOutcome { get { lock.withLock { state.outcome } } set { lock.withLock { state.outcome = newValue } } }
        var opened: [URL] { lock.withLock { state.opened } }
        var composed: [(to: [String], text: String)] { lock.withLock { state.composed } }
        var searches: [String] { lock.withLock { state.searches } }

        func find(_ name: String) async throws -> [Reachable] {
            lock.withLock {
                state.searches.append(name)
                return state.people.filter { $0.name.localizedCaseInsensitiveContains(name) }
            }
        }
        func open(_ url: URL) async -> Bool { lock.withLock { state.opened.append(url); return state.opens } }
        func canText() async -> Bool { texts }
        func compose(to recipients: [String], text: String) async -> MessageOutcome {
            lock.withLock { state.composed.append((recipients, text)); return state.outcome }
        }
    }

    struct Harness {
        let system = FakeReach()
        let people: DevicePeople

        init() {
            people = DevicePeople(system: system)
            system.people = [
                Reachable(name: "Dana Lee", phones: [.init(label: "mobile", value: "+1 (555) 010-2030"), .init(label: "work", value: "555 010 9000")],
                          emails: [.init(label: "home", value: "dana@example.com")]),
                Reachable(name: "Dana Smith", phones: [.init(label: "home", value: "555-010-4444")]),
                Reachable(name: "Riverside Vet", phones: [.init(label: "main", value: "(555) 010-7700"), .init(label: "after hours", value: "(555) 010-7701")]),
                Reachable(name: "Sasha Petrov", emails: [.init(label: "", value: "sasha@example.com")]),
                // The same mobile synced in twice, written two ways.
                Reachable(name: "Kai Moreno", phones: [.init(label: "mobile", value: "+1 555 010 3333"), .init(label: "mobile", value: "(555) 010-3333")]),
                Reachable(name: "Ines Ortiz", phones: [.init(label: "mobile", value: "555 010 1111"), .init(label: "mobile", value: "555 010 2222")]),
            ]
        }

        func call(_ args: [String: JSONValue], contacts: Bool = true) async throws -> JSONValue { try await people.call(.object(args), contactsOn: contacts) }
        func message(_ args: [String: JSONValue], contacts: Bool = true) async throws -> JSONValue { try await people.message(.object(args), contactsOn: contacts) }
    }

    private func refusal(_ work: () async throws -> JSONValue) async -> String? {
        do { _ = try await work(); return nil } catch let error as DeviceToolError { return error.message } catch { return "\(error)" }
    }

    // MARK: A call

    @Test func aNumberIsHandedToIOSToCall() async throws {
        let h = Harness()
        let answer = try await h.call(["to": .string("+1 (555) 010-2030")], contacts: false)
        #expect(h.system.opened.map(\.absoluteString) == ["tel:+15550102030"])
        #expect(h.system.searches.isEmpty, "A number needs no looking up")
        #expect(answer["asked"]?.string?.contains("asking the person whether to call") == true)
        #expect(answer["asked"]?.string?.contains("isn't told whether") == true, "Redde can't know if the call was made")
    }

    @Test func aNameIsLookedUpAndItsMobileIsTheOneMeant() async throws {
        let h = Harness()
        let answer = try await h.call(["to": .string("Dana Lee")])
        #expect(h.system.opened.map(\.absoluteString) == ["tel:+15550102030"])
        #expect(answer["to"]?.string == "Dana Lee" && answer["label"]?.string == "mobile")
        // Asked for by its label, the other one.
        _ = try await h.call(["to": .string("Dana Lee"), "label": .string("Work")])
        #expect(h.system.opened.last?.absoluteString == "tel:5550109000")
    }

    @Test func whenItIsNotClearWhomOrWhichNumberNothingIsDialled() async throws {
        let h = Harness()
        let two = await refusal { try await h.call(["to": .string("Dana")]) }
        #expect(two?.contains("Several contacts match") == true && two?.contains("Dana Lee, Dana Smith") == true)
        let which = await refusal { try await h.call(["to": .string("Riverside Vet")]) }
        #expect(which?.contains("several numbers: main, after hours") == true && which?.contains("\"label\"") == true)
        let none = await refusal { try await h.call(["to": .string("Mortimer")]) }
        #expect(none == "Nobody in Contacts matches \"Mortimer\".")
        let noNumber = await refusal { try await h.call(["to": .string("Sasha Petrov")]) }
        #expect(noNumber == "Sasha Petrov has no phone number in Contacts.")
        let noLabel = await refusal { try await h.call(["to": .string("Dana Lee"), "label": .string("fax")]) }
        #expect(noLabel?.contains("no number labelled \"fax\"") == true)
        #expect(h.system.opened.isEmpty)
    }

    @Test func twoNumbersWithOneLabelAreToldApartByTheirLastDigits() async throws {
        let h = Harness()
        // The same number twice is one number: no choice to ask about.
        _ = try await h.call(["to": .string("Kai Moreno")])
        #expect(h.system.opened.last?.absoluteString == "tel:+15550103333")
        // Two mobiles: named by their endings, and one is picked by its ending.
        let which = await refusal { try await h.call(["to": .string("Ines Ortiz")]) }
        #expect(which?.contains("several numbers: mobile ending 1111, mobile ending 2222") == true)
        _ = try await h.call(["to": .string("Ines Ortiz"), "label": .string("2222")])
        #expect(h.system.opened.last?.absoluteString == "tel:5550102222")
        let wrong = await refusal { try await h.call(["to": .string("Ines Ortiz"), "label": .string("9999")]) }
        #expect(wrong?.contains("There are: mobile ending 1111, mobile ending 2222") == true)
    }

    @Test func aNameNeedsContactsTurnedOn() async throws {
        let h = Harness()
        let off = await refusal { try await h.call(["to": .string("Dana Lee")], contacts: false) }
        #expect(off?.contains("Contacts has to be on") == true && off?.contains("Or give their number") == true)
        #expect(h.system.searches.isEmpty && h.system.opened.isEmpty, "With Contacts off nobody is looked up")
    }

    @Test func faceTimeGoesTheSameWayAndTakesAnAddress() async throws {
        let h = Harness()
        _ = try await h.call(["to": .string("Dana Lee"), "kind": .string("facetime")])
        _ = try await h.call(["to": .string("Sasha Petrov"), "kind": .string("FaceTime Audio")])
        _ = try await h.call(["to": .string("sasha@example.com"), "kind": .string("facetime_audio")], contacts: false)
        #expect(h.system.opened.map(\.absoluteString) == ["facetime://+15550102030", "facetime-audio://sasha@example.com", "facetime-audio://sasha@example.com"])
        #expect(await refusal { try await h.call(["to": .string("555 0100"), "kind": .string("carrier pigeon")]) } == "\"kind\" is phone, facetime or facetime_audio.")
    }

    @Test func aDeviceThatMakesNoCallsSaysSo() async throws {
        let h = Harness()
        h.system.opens = false
        #expect(await refusal { try await h.call(["to": .string("555 010 2030")]) }?.contains("couldn't start the call") == true)
        #expect(await refusal { try await h.call([:]) } == DeviceToolError.missing("to").message)
    }

    // MARK: A message

    @Test func aMessageIsWrittenForThePersonToSend() async throws {
        let h = Harness()
        let answer = try await h.message(["to": .string("Dana Lee"), "text": .string("Running ten minutes late.")])
        let composed = try #require(h.system.composed.first)
        #expect(composed.to == ["+15550102030"] && composed.text == "Running ten minutes late.")
        #expect(answer["sent"]?.bool == true && answer["to"]?.array?.compactMap(\.string) == ["Dana Lee"])
    }

    @Test func aMessageThePersonClosedWasNotSent() async throws {
        let h = Harness()
        h.system.outcome = .cancelled
        let answer = try await h.message(["to": .string("555 010 2030"), "text": .string("On my way")], contacts: false)
        #expect(answer["sent"]?.bool == false && answer["note"]?.string?.contains("without sending") == true)
        h.system.outcome = .failed
        #expect(await refusal { try await h.message(["to": .string("555 010 2030"), "text": .string("On my way")]) } == "The message couldn't be sent.")
    }

    @Test func aMessageCanGoToSeveralAndToAnAddress() async throws {
        let h = Harness()
        _ = try await h.message(["to": .string("Dana Lee, Sasha Petrov, 555 010 4444"), "text": .string("Dinner at 7?")])
        #expect(h.system.composed.last?.to == ["+15550102030", "sasha@example.com", "5550104444"])
        _ = try await h.message(["to": .array([.string("Dana Smith"), .string("sasha@example.com")]), "text": .string("Hi")])
        #expect(h.system.composed.last?.to == ["5550104444", "sasha@example.com"])
    }

    @Test func whatCannotBeWrittenIsRefusedBeforeTheSheetOpens() async throws {
        let h = Harness()
        #expect(await refusal { try await h.message(["to": .string("Dana Lee")]) } == DeviceToolError.missing("text").message)
        #expect(await refusal { try await h.message(["text": .string("Hi")]) } == DeviceToolError.missing("to").message)
        #expect(await refusal { try await h.message(["to": .string("Dana"), "text": .string("Hi")]) }?.contains("Several contacts match") == true)
        #expect(await refusal { try await h.message(["to": .string("555 0100"), "text": .string(String(repeating: "x", count: 2001))]) }?.contains("2000 characters") == true)
        h.system.texts = false
        #expect(await refusal { try await h.message(["to": .string("555 0100"), "text": .string("Hi")]) } == "This device can't send messages.")
        #expect(h.system.composed.isEmpty)
    }

    // MARK: Asking

    /// iOS asks before a call and the Messages sheet waits for a tap, so Redde doesn't ask
    /// first; but neither can happen with Redde off the screen.
    @Test @MainActor func redeDoesNotAskFirstAndHasToBeOnTheScreen() async throws {
        #expect([DeviceTool.peopleCall, .peopleMessage].allSatisfy { $0.area == .people && $0.asksItself && !$0.changes })
        #expect(DeviceTool.photosDelete.asksItself && !DeviceTool.contactsSearch.asksItself)
        #expect(!DeviceArea.people.offersAsking && DeviceArea.people.allowLabel == "On" && DeviceArea.widget.offersAsking)
        for access in [PhoneToolsSettings.Access.allow, .ask] {
            let h = PhoneToolsTests.Harness([.people: access])
            _ = try await h.service.perform(.init(id: "1", tool: "phone_people_call", arguments: .object(["to": .string("555 0100")])))
            #expect(h.world.asked.isEmpty && h.world.ran == [.peopleCall])
            h.world.onScreen = false
            let away = await { do { _ = try await h.service.perform(.init(id: "2", tool: "phone_people_message")); return "" } catch { return (error as? DeviceToolError)?.message ?? "" } }()
            #expect(away.contains("isn't on its screen"))
        }
        let call = DeviceAsk(.peopleCall, .object(["to": .string("Dana Lee"), "label": .string("work")]))
        #expect(call.title == "Start a phone call" && call.detail == "“Dana Lee”, “work”")
        #expect(DeviceAsk(.peopleCall, .object(["to": .string("Dana"), "kind": .string("facetime_audio")])).title == "Start a FaceTime audio call")
        let message = DeviceAsk(.peopleMessage, .object(["to": .string("Dana Lee"), "text": .string("Hi")]))
        #expect(message.title == "Write a message for you to send" && message.detail == "To “Dana Lee”")
    }

    @Test func aNumberIsToldFromAName() {
        #expect(DevicePeople.isNumber("+1 (555) 010-2030") && DevicePeople.isNumber("911") && DevicePeople.isNumber("*67 555 0100"))
        #expect(!DevicePeople.isNumber("Dana") && !DevicePeople.isNumber("Studio 54") && !DevicePeople.isNumber("12"))
        #expect(DevicePeople.dialable(" +1 (555) 010-2030 ") == "+15550102030" && DevicePeople.dialable("555.010.2030") == "5550102030")
    }
}
