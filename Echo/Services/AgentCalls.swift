import AVFoundation
import CallKit
import Foundation
import Observation
import PushKit
import UIKit
import UserNotifications
import os

/// One agent's call: who, what it says first, where it called from.
nonisolated struct AgentCall: Equatable, Sendable {
    /// CallKit's id for it.
    var id: UUID
    /// The calling agent's profile: "default", the main agent.
    var profile: String
    /// What the phone shows and says it is called.
    var name: String
    /// What it says first when the person answers; a missed call shows it.
    var line: String
    /// The conversation it called from (a Hermes session id), when it said.
    var session: String?
    /// The note it came as, for a missed call's notification.
    var note: PushNote
    var answered = false
    /// Voice mode has been started for it.
    var begun = false
}

/// What a call's push comes to, before CallKit is told: a call to ring, or why not. Whichever, it
/// is reported to CallKit as a call (`AgentCalls.incoming`): iOS asks that of every VoIP push.
nonisolated enum AgentCallPlan: Equatable, Sendable {
    case ring(AgentCall)
    case refuse(String)

    /// A note older than this rings no more: the person has moved on. (The relay has Apple keep
    /// it a minute.)
    static let stale: TimeInterval = 120

    /// `name`: what this phone calls the agent with that profile, if it knows it.
    static func decide(_ note: PushNote?, callsOn: Bool, busy: Bool, now: Date = .now, id: UUID = UUID(),
                       name: (String) -> String?) -> AgentCallPlan {
        guard let note else { return .refuse("a call this iPhone couldn't open") }
        guard note.kind == .call else { return .refuse("not a call: \(note.k)") }
        guard callsOn else { return .refuse("calls are off") }
        guard !busy else { return .refuse("on a call already") }
        if let at = note.at, now.timeIntervalSince1970 - at > stale { return .refuse("too late to ring") }
        let profile = note.p.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let named = name(profile) ?? note.d.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Your agent", comment: "Who is calling, on the incoming call screen, when the agent's name isn't known")
        return .ring(AgentCall(id: id, profile: profile, name: named, line: note.b ?? "",
                               session: note.s.flatMap { $0.isEmpty ? nil : $0 }, note: note))
    }

    /// Whether an answered call listens now: not while Redde's own lock is on, and on a locked
    /// iPhone only with Talk While Locked (`Settings.callsWhileLocked`).
    static func listens(appLocked: Bool, phoneLocked: Bool, whileLocked: Bool) -> Bool {
        !appLocked && (whileLocked || !phoneLocked)
    }

    /// What is said after the agent's line while the microphone waits for an unlock.
    static func untilUnlocked(appLocked: Bool) -> String {
        appLocked ? "Unlock Redde to answer." : "Unlock your iPhone to answer."
    }

    /// The plugin command that says this call was picked up, so its agent may call again in a
    /// minute instead of five (hung up by mistake, 2026-10-26). Nil for a note without an id.
    static func answeredCommand(_ note: PushNote) -> String? {
        guard let id = note.i, !id.isEmpty, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "calls answered \(id)"
    }

    /// The plugin command that says which agents may call this phone (`calls.py`): for each of its
    /// pairings, the agents' profiles, or "none". Nil with no pairing to say it for.
    static func command(pairings: [String], callers: [String]) -> String? {
        guard !pairings.isEmpty else { return nil }
        let agents = callers.filter { !$0.isEmpty && !$0.contains(",") && !$0.contains(" ") }
        return "calls \(pairings.joined(separator: ",")) \(agents.isEmpty ? "none" : agents.joined(separator: ","))"
    }
}

/// Calls from agents ("Hermes calls you"): an agent the person lets call rings this iPhone like a
/// phone call, its name on the Lock Screen, for something that shouldn't wait. The plugin's
/// `call_user` (`companion/hermes-plugin/redde-push/calls.py`) seals a note, the relay sends it to
/// Apple as a VoIP push to the address PushKit gave this phone (`PushService` hands the relay that
/// while calls are on), and iOS wakes Redde here, which has CallKit ring.
///
/// Answered: voice mode in that agent's chat, hands-free as on a call, the agent's line said first
/// in its voice (a live call opens saying it, where the agent's chat has one), and what the person
/// says next goes to the agent with a note that it answers its call (`CallNote`). Hanging up on
/// either side ends both. Not answered in 30 seconds, or declined: a notification with the line,
/// which opens the chat.
///
/// iOS ends an app that is handed a VoIP push and reports no call, and after a few stops sending
/// them: so every push is reported, and one that shouldn't ring (calls off here, a call already
/// on, a note this phone can't open) ends at once. Who may call is the plugin's to enforce, told
/// by `publish`, so that such pushes aren't sent.
@MainActor
@Observable
final class AgentCalls: NSObject {
    static let shared = AgentCalls()

    /// What the plugin said when last told who may call.
    enum Status: Equatable {
        case unknown, ready, noPairing, noDashboard, oldPlugin, noPlugin
        case failed(String)
    }

    /// The call ringing or on, if any.
    private(set) var current: AgentCall?
    private(set) var status: Status = .unknown

    /// How long a call rings before it is a missed one.
    static let ringFor: Duration = .seconds(30)

    @ObservationIgnored private let log = Logger(subsystem: "com.goosehouse.echo", category: "calls")
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var registry: PKPushRegistry?
    @ObservationIgnored private var provider: CXProvider?
    @ObservationIgnored private let controller = CXCallController()
    @ObservationIgnored private var ringing: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// What each server's plugin was last told, so it is told again only when it changes.
    @ObservationIgnored private var said: [String: String] = [:]

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init()
    }

    /// What happens to calls, in the system log, and in a development build also in
    /// Library/Caches/calls.log, read off the phone after a try (`devicectl device copy from`).
    private func note(_ line: String) {
        log.notice("\(line, privacy: .public)")
        #if DEBUG
        LiveMeasure.write(line, to: "calls.log")
        #endif
    }

    // MARK: - Set up

    /// At launch, before any scene: a call's push can be what started the app, and PushKit hands
    /// it over only once the registry is made. Only with calls on.
    func start() {
        guard settings.agentCalls else { return }
        listen()
    }

    private func listen() {
        if provider == nil { provider = makeProvider() }
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    /// Calls turned on or off here, or the agents that may call changed: PushKit asked (or no
    /// longer), the relay given the address (or told to forget it), the plugin told who may call.
    func settingsChanged() {
        if settings.agentCalls {
            listen()
        } else if let registry {
            registry.desiredPushTypes = []
            self.registry = nil
        }
        PushService.shared.callsChanged()
        publish()
    }

    private func makeProvider() -> CXProvider {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        // An agent's call isn't one to call back from the Phone app.
        configuration.includesCallsInRecents = false
        if let icon = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)) {
            configuration.iconTemplateImageData = icon.pngData()
        }
        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)   // (the main queue)
        return provider
    }

    private func received(voip token: String?) {
        note(token == nil ? "PushKit took the address for calls back" : "PushKit gave the address for calls")
        PushService.shared.voipChanged(token)
    }

    // MARK: - Who may call

    /// Tells the plugin on the Hermes in use which agents may call this phone (`calls.py`): over
    /// the Dashboard, the plugin's own command, for each pairing of this phone. "none" when calls
    /// are off. Again when they change, and each time Redde comes forward (the server may have
    /// been restarted, or the plugin updated, meanwhile).
    func publish() {
        // Calls never turned on for this server: nothing to tell it.
        guard settings.agentCalls || !settings.callersHere.isEmpty else { status = .unknown; return }
        guard settings.serveBaseURL != nil else { status = .noDashboard; return }
        let ids = PushService.shared.pairings.filter(\.isPaired).map(\.id)
        guard let command = AgentCallPlan.command(pairings: ids, callers: settings.agentCalls ? settings.callersHere : []) else {
            status = .noPairing
            return
        }
        let server = settings.connectionKey
        guard said[server] != command else { return }
        said[server] = command
        Task { [weak self] in
            do {
                let reply = try await PushService.command(over: .shared)(command)
                guard let self else { return }
                note("told the plugin \(command.split(separator: " ").last ?? ""): \(reply)")
                if reply.hasPrefix("redde-push calls ") {
                    // "calls 0": none of this phone's pairings is with this Hermes.
                    status = (Int(reply.split(separator: " ").last ?? "") ?? 0) > 0 ? .ready : .noPairing
                } else {
                    status = .oldPlugin   // its usage line: a plugin from before 1.8.0
                }
            } catch PushError.noPlugin {
                self?.note("no plugin to tell who may call")
                self?.status = .noPlugin
            } catch {
                self?.said[server] = nil   // said next time
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    /// What this phone calls the agent with that profile: the main agent by its name in Redde, a
    /// bot by its own.
    static func name(of profile: String, settings: Settings = .shared) -> String? {
        if profile == "default" { return settings.headerTitle }
        return BotDirectory.shared.bots(for: settings.connectionKey).first { $0.name == profile }?.label(mainName: settings.headerTitle)
    }

    // MARK: - A call comes in

    private func incoming(_ sealed: String?, done: @escaping () -> Void) {
        incoming(note: sealed.flatMap { PushSeal.note(from: $0, pairings: PushVault.load())?.note }, done: done)
    }

    #if DEBUG
    /// `-echo.ringMe <profile> <seconds>`: a call from that agent as if its push had come, for
    /// trying CallKit without the plugin and the relay (the simulator; a phone before the relay
    /// is deployed). With calls off here it is refused, as a push would be.
    func ring(from profile: String, saying line: String) {
        let note = PushNote(k: PushNote.Kind.call.rawValue, s: nil, b: line, d: Self.name(of: profile, settings: settings) ?? profile,
                            n: "test", at: Date.now.timeIntervalSince1970, p: profile, i: UUID().uuidString.prefix(16).lowercased())
        incoming(note: note) {}
    }
    #endif

    private func incoming(note: PushNote?, done: @escaping () -> Void) {
        listen()   // (the provider, when this push is what started the app)
        guard let provider else { done(); return }
        let plan = AgentCallPlan.decide(note, callsOn: settings.agentCalls, busy: current != nil) { [settings] in
            Self.name(of: $0, settings: settings)
        }
        let update = CXCallUpdate()
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        switch plan {
        case .ring(let call):
            self.note("\(call.profile) is calling")
            update.localizedCallerName = call.name
            update.remoteHandle = CXHandle(type: .generic, value: call.name)
            current = call
            provider.reportNewIncomingCall(with: call.id, update: update, completion: Self.reported(call.id, rings: true, done: done))
            ringing = Task { [weak self] in
                try? await Task.sleep(for: Self.ringFor)
                guard !Task.isCancelled else { return }
                self?.unanswered(call.id)
            }
        case .refuse(let why):
            // Reported, as iOS has every VoIP push be, and over at once.
            self.note("a call's push not rung: \(why)")
            let id = UUID()
            update.localizedCallerName = "Redde"
            provider.reportNewIncomingCall(with: id, update: update, completion: Self.reported(id, rings: false, done: done))
        }
    }

    /// CallKit's word on a call reported: PushKit's completion is called once it has it. Built
    /// outside the main actor: CallKit calls it on a queue of its own.
    nonisolated private static func reported(_ id: UUID, rings: Bool, done: @escaping () -> Void) -> @Sendable (Error?) -> Void {
        nonisolated(unsafe) let done = done
        return { error in
            let code = (error as? CXErrorCodeIncomingCallError)?.code
            let reason = error?.localizedDescription
            Task { @MainActor in AgentCalls.shared.reported(id, rings: rings, code: code, error: reason) }
            done()
        }
    }

    private func reported(_ id: UUID, rings: Bool, code: CXErrorCodeIncomingCallError.Code?, error: String?) {
        guard rings else {
            provider?.reportCall(with: id, endedAt: nil, reason: .failed)
            return
        }
        guard let error else { return }
        // Do Not Disturb or a Focus kept it from ringing: it is a missed call.
        note("the call wasn't rung: \(error)")
        ringing?.cancel()
        guard let call = current, call.id == id else { return }
        current = nil
        if code == .filteredByDoNotDisturb || code == .filteredByBlockList { missed(call) }
    }

    private func unanswered(_ id: UUID) {
        guard let call = current, call.id == id, !call.answered else { return }
        note("not answered: a missed call")
        provider?.reportCall(with: id, endedAt: .now, reason: .unanswered)
        current = nil
        missed(call)
    }

    /// A call not answered: a notification with what the agent called about, which opens its
    /// chat. Declined: the same, as a call the person saw.
    private func missed(_ call: AgentCall, declined: Bool = false) {
        let content = UNMutableNotificationContent()
        guard call.note.fill(content) else { return }
        content.title = declined ? String(localized: "Call from \(call.name)", comment: "Notification title: a call from an agent that was declined") : String(localized: "Missed call from \(call.name)", comment: "Notification title: an agent's call nobody answered")
        if call.line.isEmpty { content.body = String(localized: "Open Redde to see what it was about.") }
        content.sound = settings.notificationSound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "redde.call.\(call.note.i ?? call.id.uuidString)",
                                                                     content: content, trigger: nil))
    }

    // MARK: - Answered

    private func answer(_ action: CXAnswerCallAction) {
        guard var call = current, call.id == action.callUUID else { action.fail(); return }
        note("answered")
        ringing?.cancel()
        call.answered = true
        current = call
        // CallKit turns the audio on (`didActivate`); it is set up for voice before then, and Redde
        // leaves it on until the call ends.
        AudioSessionController.shared.heldByCall = true
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        action.fulfill()
        if settings.serveBaseURL != nil, let command = AgentCallPlan.answeredCommand(call.note) {
            Task { [weak self] in
                let reply = (try? await PushService.command(over: .shared)(command)) ?? "couldn't be told"
                self?.note("told the plugin it was answered: \(reply)")
            }
        }
        starting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))   // in case CallKit's word on the audio never comes
            guard !Task.isCancelled else { return }
            self?.begin()
        }
    }

    private func audioActivated() {
        note("CallKit turned the audio on")
        guard current?.answered == true else { return }
        begin()
    }

    /// Voice mode in the agent's chat: its line said, then the person heard.
    private func begin() {
        starting?.cancel()
        starting = nil
        guard var call = current, call.answered, !call.begun else { return }
        call.begun = true
        current = call
        guard let conversation = Conversation.current, let voice = VoiceSession.current else {
            note("answered with no conversation to take it")
            hangUp(call.id)
            return
        }
        let id = call.id
        Task { [weak self] in
            guard let self else { return }
            await open(call, in: conversation)
            guard current?.id == id else { return }
            let appLocked = AppLock.shared.isLocked
            let listens = AgentCallPlan.listens(appLocked: appLocked, phoneLocked: phoneLocked, whileLocked: settings.callsWhileLocked)
            note("voice mode in \(conversation.bot?.profile ?? "a conversation"), listening: \(listens)")
            conversation.answeringCall = (call.line, .now)
            voice.answerCall(saying: call.line, listen: listens, untilThen: AgentCallPlan.untilUnlocked(appLocked: appLocked)) { [weak self] in
                self?.hangUp(id)
            }
            LaunchRouter.shared.requestCallScreen()
        }
    }

    /// The agent's chat: a bot's own; for the main agent, the conversation it called from when
    /// this phone has it, else its bot chat, else a new conversation. A bot that isn't on the
    /// server in use: a new conversation, the call going on there.
    private func open(_ call: AgentCall, in conversation: Conversation) async {
        let main = settings.headerTitle
        do {
            if call.profile != "default" {
                if try await conversation.goToBot(call.profile, mainName: main) { return }
                note("no bot \(call.profile) on this server: the call goes on in a new conversation")
            } else if let session = call.session, ConversationStore.shared.summaries.contains(where: { $0.serverSessionID == session }) {
                try await conversation.open(serverSession: session)
                return
            } else if try await conversation.goToBot("default", mainName: main) {
                return
            }
        } catch {
            note("couldn't open the caller's chat: \(error.localizedDescription)")
        }
        if conversation.bot != nil || !conversation.messages.isEmpty { conversation.reset() }
    }

    /// The iPhone is locked: its protected files can't be read (with a passcode set, from about
    /// ten seconds after it locks).
    private var phoneLocked: Bool { !UIApplication.shared.isProtectedDataAvailable }

    /// The call was answered locked: the line was said, and the microphone opens once the iPhone
    /// (`PushDelegate`) and Redde (`ContentView`) are unlocked.
    func unlocked() {
        guard current?.answered == true, let voice = VoiceSession.current, voice.callEnded != nil, voice.phase == .idle, !voice.isLive,
              AgentCallPlan.listens(appLocked: AppLock.shared.isLocked, phoneLocked: phoneLocked, whileLocked: settings.callsWhileLocked)
        else { return }
        note("unlocked: listening")
        voice.beginListening()
    }

    // MARK: - Over

    /// Voice mode ended (`VoiceSession.callEnded`), or there was none to take the call: the
    /// phone call ends too.
    private func hangUp(_ id: UUID) {
        guard current?.id == id else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: id)), completion: Self.logged("ending the call"))
    }

    nonisolated private static func logged(_ what: String) -> @Sendable (Error?) -> Void {
        { error in
            guard let error else { return }
            Logger(subsystem: "com.goosehouse.echo", category: "calls").error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func end(_ action: CXEndCallAction) {
        defer { action.fulfill() }
        guard let call = current, call.id == action.callUUID else { return }
        note("the call ended, \(call.answered ? "answered" : "not answered")")
        AudioSessionController.shared.heldByCall = false
        ringing?.cancel()
        starting?.cancel()
        starting = nil
        current = nil
        if call.answered {
            // Hung up on the call's screen: voice mode ends with it. (Ended from voice mode, its
            // hook is spent.)
            if let voice = VoiceSession.current, voice.callEnded != nil {
                voice.callEnded = nil
                voice.cancel()
            }
        } else {
            missed(call, declined: true)
        }
    }

    private func setMuted(_ action: CXSetMutedCallAction) {
        if let voice = VoiceSession.current, current?.answered == true {
            if action.isMuted { voice.mute() } else { voice.unmute() }
        }
        action.fulfill()
    }

    private func reset() {
        AudioSessionController.shared.heldByCall = false
        ringing?.cancel()
        starting?.cancel()
        starting = nil
        current = nil
        if let voice = VoiceSession.current, voice.callEnded != nil {
            voice.callEnded = nil
            voice.cancel()
        }
    }
}

// The registry and the provider call on the main queue (`PKPushRegistry(queue: .main)`,
// `setDelegate(_:queue: nil)`), so each callback is on the main actor already.

extension AgentCalls: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = PushSeal.hex(pushCredentials.token)
        MainActor.assumeIsolated { received(voip: token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated { received(voip: nil) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                                  completion: @escaping () -> Void) {
        let sealed = payload.dictionaryPayload[PushNote.sealedKey] as? String
        nonisolated(unsafe) let done = completion
        MainActor.assumeIsolated { incoming(sealed, done: done) }
    }
}

extension AgentCalls: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { reset() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated { answer(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated { end(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        nonisolated(unsafe) let action = action
        MainActor.assumeIsolated { setMuted(action) }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { audioActivated() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
