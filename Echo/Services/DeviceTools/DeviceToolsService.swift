import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import os

/// Which phone tools the agent may use, kept in Settings (Settings → Phone tools).
nonisolated struct PhoneToolsSettings: Codable, Equatable, Sendable {
    /// What an area allows: nothing, anything once the person has said yes each time, or
    /// reading without being asked (changes are asked about either way).
    enum Access: String, Codable, Sendable, CaseIterable { case off, ask, allow }

    /// The whole thing. Off until turned on.
    var on = false
    var areas: [String: Access] = [:]

    func access(_ area: DeviceArea) -> Access { on ? areas[area.rawValue] ?? .off : .off }
    mutating func set(_ area: DeviceArea, _ access: Access) { areas[area.rawValue] = access }

    /// The areas the agent is shown tools for.
    var open: [DeviceArea] { DeviceArea.allCases.filter { access($0) != .off } }
}

/// The phone's side of phone tools: it learns that the agent has called one, asks the plugin on
/// the Hermes server what is wanted, settles whether it may be done (is the area on, does the
/// person have to say yes), does it, and hands the answer back for the agent to read.
///
/// It talks to the plugin over the Dashboard connection, with the command the plugin already has
/// for the app (`/redde-push device …`): `next` gives the requests that are waiting, `done`
/// takes an answer, `areas` says which tools the agent should be offered at all. So phone tools
/// need the Dashboard login, also when the conversation itself runs over the Hermes API.
///
/// A request reaches the phone only while Redde is following the turn it was made in: the
/// agent's tool call shows in that turn, and that is the cue to ask. A turn started somewhere
/// else gets "the phone didn't answer".
@Observable
final class DeviceToolsService {
    static let shared = DeviceToolsService()

    /// One thing the agent asked for, for the list in Settings.
    nonisolated struct Entry: Codable, Equatable, Sendable, Identifiable {
        enum Outcome: String, Codable, Sendable { case done, denied, failed }
        var id = UUID()
        var at: Date
        var title: String
        var detail: String
        var outcome: Outcome
        /// What went wrong, for a failure.
        var note: String?
    }

    /// What the person is asked, and what they can say.
    nonisolated struct Question: Equatable, Sendable {
        var ask: DeviceAsk
        /// A read in an area that asks: "always" is offered, and stops the asking for that area.
        var offersAlways: Bool
        var area: DeviceArea?
    }
    nonisolated enum Answer: Sendable { case allow, always, deny }

    /// Newest first; the last forty.
    private(set) var log: [Entry] {
        didSet { if log != oldValue { defaults.set(try? JSONEncoder().encode(log), forKey: Self.logKey) } }
    }
    /// A request is being dealt with.
    private(set) var isBusy = false
    /// Areas that are on but that the plugin didn't take when last told: an older plugin knows
    /// fewer, and the agent isn't offered their tools. Empty when the plugin couldn't be asked.
    private(set) var unoffered: [DeviceArea] = []

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let defaults: UserDefaults
    /// `/redde-push <arguments>` on the server, and what the plugin says.
    @ObservationIgnored private let command: (String) async throws -> String
    @ObservationIgnored private let run: (DeviceTool, JSONValue, JSONValue) async throws -> JSONValue
    @ObservationIgnored private let ask: (Question) async -> Answer
    /// Whether Redde is on the phone's screen, where a question can be put.
    @ObservationIgnored private let onScreen: () -> Bool
    @ObservationIgnored private var handled: Set<String> = []
    /// Puts a picture in front of the person, in the reply the agent's call belongs to: what is
    /// handed to the agent is shown as it goes. Given by the conversation with the cue.
    @ObservationIgnored private var show: ((Attachment) -> Void)?
    @ObservationIgnored private var checking: Task<Void, Never>?
    /// Another phone tool started while `checking` was at work.
    @ObservationIgnored private var again = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.goosehouse.echo", category: "phone-tools")
    /// How often, and how many times, the plugin is asked for a request the turn says exists
    /// (the agent's call can show a moment before the plugin has written it down).
    @ObservationIgnored var patience: (tries: Int, pause: Duration) = (12, .milliseconds(400))

    private static let logKey = "phoneTools.log"

    init(settings: Settings = .shared, defaults: UserDefaults = .standard,
         command: ((String) async throws -> String)? = nil,
         run: ((DeviceTool, JSONValue, JSONValue) async throws -> JSONValue)? = nil,
         ask: ((Question) async -> Answer)? = nil,
         onScreen: @escaping () -> Bool = { AppState.isActive }) {
        self.settings = settings
        self.defaults = defaults
        self.command = command ?? PushService.command(over: HermesServeClient.shared)
        let runner = DeviceToolRunner()
        self.run = run ?? { try await runner.run($0, $1, info: $2) }
        self.ask = ask ?? { await DeviceToolsService.alert($0) }
        self.onScreen = onScreen
        log = defaults.data(forKey: Self.logKey).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    // MARK: - From a turn

    /// The agent has started a tool in a turn Redde is following. If it is one of the phone's,
    /// the plugin is asked what is wanted. `show` puts a picture into that turn's reply.
    func toolStarted(_ name: String, show: ((Attachment) -> Void)? = nil) {
        guard name.hasPrefix(DeviceTool.prefix) else { return }
        if let show { self.show = show }
        // A call that starts while another is being answered (an agent fetching several photos
        // one after the other, or at once) is looked for when that one is done: its request
        // may not have been with the plugin yet when the first was asked for.
        guard checking == nil else { again = true; return }
        checking = Task { [weak self] in
            repeat {
                self?.again = false
                await self?.collect()
            } while self?.again == true
            self?.checking = nil
        }
    }

    /// Asks the plugin for what is waiting and deals with each request, until one has been
    /// found and dealt with or patience runs out.
    func collect() async {
        for attempt in 0 ..< patience.tries {
            if attempt > 0 { try? await Task.sleep(for: patience.pause) }
            guard let waiting = try? await pending() else { return }   // no Dashboard, or no plugin: nothing to do here
            let fresh = waiting.filter { handled.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            for request in fresh { await answer(request) }
            return
        }
    }

    /// The requests the plugin is holding for the phone.
    func pending() async throws -> [DeviceRequest] {
        let reply = try await command("device next")
        guard let list = Self.payload(of: reply, after: "redde-push device next ")?.array else { return [] }
        return list.compactMap(DeviceRequest.init)
    }

    /// Deals with one request and hands the plugin the answer.
    func answer(_ request: DeviceRequest) async {
        isBusy = true
        defer { isBusy = false }
        let envelope: JSONValue
        do {
            let result = try await perform(request)
            // A photo on its way to the agent is put in the conversation too: the person sees
            // which picture left the phone, and "show me my latest photo" shows it.
            if request.tool == DeviceTool.photosGet.rawValue, let file = result["file"],
               let data = file["base64"]?.string.flatMap({ Data(base64Encoded: $0) }) {
                show?(Attachment(kind: .image, filename: file["name"]?.string ?? "photo.jpg", mimeType: "image/jpeg", data: data))
            }
            envelope = .object(["ok": .bool(true), "result": result])
        } catch let error as DeviceToolError {
            envelope = .object(["ok": .bool(false), "error": .string(error.message)])
        } catch {
            envelope = .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
        }
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        do {
            _ = try await command("device done \(request.id) \(data.base64EncodedString())")
        } catch {
            logger.error("a phone tool's answer didn't reach the server: \(error.localizedDescription)")
        }
    }

    /// Settles whether the request may be carried out, and carries it out.
    func perform(_ request: DeviceRequest) async throws -> JSONValue {
        guard let tool = DeviceTool(rawValue: request.tool) else {
            throw DeviceToolError("This Redde doesn't know the tool \(request.tool): the plugin on the server is newer than the app.")
        }
        let question = DeviceAsk(tool, request.arguments)
        func note(_ outcome: Entry.Outcome, _ why: String? = nil) {
            log = Array(([Entry(at: .now, title: question.title, detail: question.detail, outcome: outcome, note: why)] + log).prefix(40))
        }
        var access = PhoneToolsSettings.Access.allow
        do {
            guard settings.phoneTools.on else { throw DeviceToolError.off }
            if let area = tool.area {
                access = settings.phoneTools.access(area)
                guard access != .off else { throw DeviceToolError.areaOff(area) }
            }
            // Changes are asked about every time; reads where the area says ask. A delete of
            // photos is put to the person by iOS, with the photos shown: not by Redde as well.
            if tool.changes || (access == .ask && !tool.asksItself) {
                guard onScreen() else {
                    throw DeviceToolError("This needs a yes on the iPhone, and Redde isn't on its screen. Ask the person to open Redde and try again.")
                }
                switch await ask(Question(ask: question, offersAlways: !tool.changes, area: tool.area)) {
                case .deny: throw DeviceToolError.denied
                case .always: if let area = tool.area, !tool.changes { settings.phoneTools.set(area, .allow) }
                case .allow: break
                }
            } else if tool.asksItself, !onScreen() {
                throw DeviceToolError(tool == .photosDelete ? "Deleting photos needs the person at the iPhone, and Redde isn't on its screen."
                                      : "This needs the person at the iPhone, and Redde isn't on its screen. Ask them to open Redde and try again.")
            }
        } catch let error as DeviceToolError {
            note(error == .denied ? .denied : .failed, error == .denied ? nil : error.message)
            throw error
        }
        do {
            let result = try await run(tool, request.arguments, info())
            note(.done)
            return result
        } catch let error as DeviceToolError {
            note(error == .denied ? .denied : .failed, error == .denied ? nil : error.message)
            throw error
        }
    }

    /// What `phone_info` tells the agent: when it is here, and what it may ask for.
    func info(now: Date = .now) -> JSONValue {
        let app = "Redde \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
        var areas: [String: JSONValue] = [:]
        for area in DeviceArea.allCases {
            let state = switch settings.phoneTools.access(area) {
            case .off: "off"
            case .ask: "on; the person is asked each time"
            case .allow where area == .people: "on; iOS asks the person before a call goes out, and a message is theirs to send"
            case .allow where area == .widget: "on; written on without asking"
            case .allow: "on; reading needs no asking, changes are asked about"
            }
            areas[area.rawValue] = .string(state)
        }
        return .object([
            "device": .string(Self.deviceName),
            "system": .string(Self.systemName),
            "app": .string(app),
            "time": .string(DeviceDates.string(now)),
            "time_zone": .string(TimeZone.current.identifier),
            "locale": .string(Locale.current.identifier),
            "areas": .object(areas),
            "note": .string("Phone tools work only while Redde is open on the phone and following this conversation."),
        ])
    }

    // MARK: - What the agent is offered

    /// Tells the plugin which areas are on, so the agent is offered their tools and no others.
    /// Called when the switches change and when a Dashboard connection comes up. Returns what
    /// the plugin holds afterwards, or nil if it couldn't be told.
    @discardableResult
    func publish() async -> [DeviceArea]? {
        let open = settings.phoneTools.open
        guard let reply = try? await command("device areas " + (open.isEmpty ? "none" : open.map(\.rawValue).joined(separator: ","))),
              reply.hasPrefix("redde-push device areas") else { return nil }
        let named = reply.dropFirst("redde-push device areas".count).split(whereSeparator: { $0 == " " || $0 == "," })
        let held = named.compactMap { DeviceArea(rawValue: String($0)) }
        unoffered = open.filter { !held.contains($0) }
        return held
    }

    func clearLog() { log = [] }

    /// The JSON after `prefix` in a reply from the plugin, which sends it as base64.
    nonisolated static func payload(of reply: String, after prefix: String) -> JSONValue? {
        guard reply.hasPrefix(prefix), let data = Data(base64Encoded: String(reply.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? JSONValue.parse(data)
    }

    #if canImport(UIKit)
    private static var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    private static var systemName: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }
    #else
    private static let deviceName = "Mac"
    private static var systemName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    #endif

    // MARK: - Asking the person

    #if canImport(UIKit)
    /// The question as an alert over whatever Redde is showing, voice mode included.
    private static func alert(_ question: Question) async -> Answer {
        await withCheckedContinuation { done in
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
                  var top = scene.keyWindow?.rootViewController else { done.resume(returning: .deny); return }
            while let presented = top.presentedViewController { top = presented }
            let alert = UIAlertController(title: String(localized: "\(Settings.shared.headerTitle) wants to:\n\(question.ask.title)", comment: "Asking the person before a phone tool runs: the agent's name, then what it wants to do"),
                                          message: question.ask.detail.isEmpty ? nil : question.ask.detail, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Don't Allow"), style: .cancel) { _ in done.resume(returning: .deny) })
            alert.addAction(UIAlertAction(title: String(localized: "Allow", comment: "Lets a phone tool run this once"), style: .default) { _ in done.resume(returning: .allow) })
            if question.offersAlways, let area = question.area {
                alert.addAction(UIAlertAction(title: area.alwaysLabel, style: .default) { _ in done.resume(returning: .always) })
            }
            top.present(alert, animated: true)
        }
    }
    #else
    /// The question as an alert in front of Redde's window.
    private static func alert(_ question: Question) async -> Answer {
        let alert = NSAlert()
        alert.messageText = String(localized: "\(Settings.shared.headerTitle) wants to:\n\(question.ask.title)", comment: "Asking the person before a phone tool runs: the agent's name, then what it wants to do")
        alert.informativeText = question.ask.detail
        alert.addButton(withTitle: String(localized: "Allow", comment: "Lets a phone tool run this once"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        let always = question.offersAlways ? question.area : nil
        if let always { alert.addButton(withTitle: always.alwaysLabel) }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allow
        case .alertThirdButtonReturn: return always == nil ? .deny : .always
        default: return .deny
        }
    }
    #endif
}
