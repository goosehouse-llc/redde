import SwiftUI

/// Follow-through (plugin 1.39, `followthrough.py` and `arrivals.py`; 2026-11-23, after plans that
/// happen: "What are some other proactive actions we can incorporate?", then "All 3"). What the
/// person's mail says will happen is kept on their Hermes and checked when it should have:
/// promises they wrote, questions waiting on an answer, replies they owe, deliveries, return
/// windows and trials. And what they mean to watch, when it can be: a watch-list title new on
/// Jellyfin, a finished series' next season. Only what didn't happen comes back, as an idea card.
struct FollowThrough: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let kind: String
        var name: String?
        var subject: String?
        var said: String?
        var shop: String?
        var what: String?
        var day: Date?
        var price: String?
        var due: Date?
        // 1.40: bills, expiries, trips, meetings
        var amount: String?
        var thing: String?
        var place: String?
        var flight: String?
        var back: Date?
        var meetingTitle: String?
        var start: Date?
        // 1.55: a follow-up's draft waiting ("mailbox" or "redde"), a security card's notices
        var draft: String?
        var count: Int?
    }

    var mail = true
    var orders = true
    var trips = true
    var arrivals = true
    var habits = true
    var outings = true
    /// Appointments that come round again (plugin 1.54, `Appointments`).
    var appointments = true
    /// Security notices from the mail, "Was this you?" (plugin 1.55, `mailwatch.py`).
    var security = true
    /// The profile whose .env has Paperless's address and key; nil when none has.
    var paperless: String?
    var items: [Item] = []
    /// The profile whose .env has Jellyfin's address and key; nil when none has.
    var jellyfin: String?
    var jellyfinFound = false

    static func parse(_ reply: String) -> FollowThrough? {
        let prefix = "redde-push follow "
        let rest = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.hasPrefix(prefix), let data = rest.dropFirst(prefix.count).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var made = FollowThrough()
        let switches = root["switches"] as? [String: Bool] ?? [:]
        made.mail = switches["mail"] ?? true
        made.orders = switches["orders"] ?? true
        made.arrivals = switches["arrivals"] ?? true
        made.trips = switches["trips"] ?? true
        made.habits = switches["habits"] ?? true
        made.outings = switches["outings"] ?? true
        made.appointments = switches["appointments"] ?? true
        made.security = switches["security"] ?? true
        if let found = root["paperless"] as? [String: Any], found["found"] as? Bool == true {
            made.paperless = found["profile"] as? String
        }
        if let found = root["jellyfin"] as? [String: Any] {
            made.jellyfinFound = found["found"] as? Bool ?? false
            made.jellyfin = found["profile"] as? String
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        made.items = (root["items"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, let kind = row["kind"] as? String else { return nil }
            return Item(id: id, kind: kind, name: row["name"] as? String, subject: row["subject"] as? String,
                        said: row["said"] as? String, shop: row["shop"] as? String, what: row["what"] as? String,
                        day: (row["day"] as? String).flatMap(day.date(from:)), price: row["price"] as? String,
                        due: (row["due"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                        amount: row["amount"] as? String, thing: row["thing"] as? String, place: row["place"] as? String,
                        flight: row["flight"] as? String, back: (row["back"] as? String).flatMap(day.date(from:)),
                        meetingTitle: row["title"] as? String,
                        start: (row["start"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                        draft: row["draft"] as? String, count: (row["count"] as? NSNumber)?.intValue)
        }
        return made
    }

    @MainActor
    static func run(_ line: String) async -> FollowThrough? {
        guard let reply = try? await PushService.command(over: .shared)(line) else { return nil }
        return parse(reply)
    }
}

extension FollowThrough.Item {
    var symbol: String {
        switch kind {
        case "promise": "arrow.uturn.right.circle"
        case "waiting": "hourglass"
        case "owed": "arrowshape.turn.up.left"
        case "delivery": "shippingbox"
        case "return": "arrow.uturn.backward.circle"
        case "trial": "creditcard"
        case "bill": "doc.text"
        case "expiry": "calendar.badge.exclamationmark"
        case "trip": "airplane"
        case "meeting": "person.2"
        case "planned": "list.bullet.clipboard"
        case "security": "lock.shield"
        case "bounce": "envelope.arrow.triangle.branch"
        case "followup": "hand.wave"
        default: "circle"
        }
    }

    private var first: String { (name ?? "").split(separator: " ").first.map(String.init) ?? (name ?? "") }

    var title: String {
        switch kind {
        case "promise": String(localized: "Send \(first) what you promised", comment: "Follow-Through: a promise in mail they sent")
        case "waiting": String(localized: "Waiting on \(first)", comment: "Follow-Through: a question they sent, not yet answered")
        case "owed": String(localized: "Reply to \(first)", comment: "Follow-Through: mail they owe a reply")
        case "delivery": what ?? String(localized: "An order", comment: "Follow-Through: a delivery with no name")
        case "return": String(localized: "Return \(what ?? "")", comment: "Follow-Through: a return window, with what was bought")
        case "trial": String(localized: "\(shop ?? "") renews", comment: "Follow-Through: a trial or subscription about to charge")
        case "bill": String(localized: "\(shop ?? "") bill", comment: "Follow-Through: a bill to pay, with who it's from")
        case "expiry": what ?? thing ?? ""
        case "trip": place.map { String(localized: "Trip to \($0)", comment: "Follow-Through: a trip, with where to") }
            ?? String(localized: "A trip", comment: "Follow-Through: a trip with no place known")
        case "meeting", "planned": meetingTitle ?? ""
        case "security": String(localized: "Was this you?", comment: "Follow-Through: security notices from the mail, asking if it was them")
        case "bounce": String(localized: "Bounced: \(first)", comment: "Follow-Through: mail that didn't arrive, with who it was to")
        case "followup": String(localized: "\(first) is following up", comment: "Follow-Through: someone writing again with no reply yet")
        default: subject ?? ""
        }
    }

    var detail: String {
        let date = day?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? ""
        switch kind {
        case "promise": return said ?? subject ?? ""
        case "waiting", "owed": return subject ?? ""
        case "delivery": return String(localized: "From \(shop ?? ""), due \(date)", comment: "Follow-Through: a delivery's shop and day")
        case "return": return String(localized: "\(shop ?? ""), by \(date)", comment: "Follow-Through: where it goes back to, and the last day")
        case "trial":
            let then = price.map { " · " + $0 } ?? ""
            return date + then
        case "bill":
            let owed = amount.map { $0 + " · " } ?? ""
            return owed + String(localized: "due \(date)", comment: "Follow-Through: a bill's day due")
        case "expiry": return String(localized: "Expires \(date)", comment: "Follow-Through: when something runs out")
        case "trip":
            let home = back.map { " – " + $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
            return [flight, date + home].compactMap { $0 }.joined(separator: " · ")
        case "planned":
            let at = due?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) ?? date
            return what.map { String(localized: "For \($0) · \(at)", comment: "Follow-Through: a plan's action for later, with the plan and when") } ?? at
        case "meeting":
            return start?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) ?? date
        case "security": return shop ?? ""
        case "bounce": return subject ?? ""
        case "followup":
            let waiting = draft == nil ? nil : String(localized: "Draft waiting", comment: "Follow-Through: a draft reply to them hasn't been sent")
            return [subject, waiting].compactMap { $0 }.joined(separator: " · ")
        default: return ""
        }
    }
}

struct FollowThroughView: View {
    @State private var shown: FollowThrough?
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        Form {
            if let shown {
                Section {
                    toggle(\.mail, "mail", Text("Promises & Replies", comment: "Follow-Through: the mail switch"),
                           Text("What you said you'd send, questions waiting on an answer, mail you owe a reply or that's being followed up, mail that bounced, and what's open with the people you're about to meet.", comment: "Follow-Through: under the mail switch"),
                           symbol: "envelope.badge")
                    // (plugin 1.55.0; an older one has no such switch, and its answer leaves it on)
                    toggle(\.security, "security", Text("Security Notices", comment: "Follow-Through: the security switch"),
                           Text("A new sign-in, a password or two-step change, a phone number taken off an account: one card for the ones that come together, asking if it was you. Say it was, and that device's sign-ins go quiet.", comment: "Follow-Through: under the security switch"),
                           symbol: "lock.shield")
                    toggle(\.orders, "orders", Text("Orders, Bills & Renewals", comment: "Follow-Through: the orders switch"),
                           Text("Deliveries running late, return windows closing, trials about to charge, bills before they're due and paid after, and what runs out: a passport, a policy, a warranty.", comment: "Follow-Through: under the orders switch"),
                           symbol: "shippingbox")
                    toggle(\.trips, "trips", Text("Trips", comment: "Follow-Through: the trips switch"),
                           Text("Packing three days before a flight or a stay, check-in the day before, the receipts once you're home.", comment: "Follow-Through: under the trips switch"),
                           symbol: "airplane")
                    toggle(\.habits, "habits", Text("Usual Buys", comment: "Follow-Through: the habits switch"),
                           Text("What you tick off a shopping list every so often, offered back when it's about due.", comment: "Follow-Through: under the habits switch"),
                           symbol: "cart.badge.plus")
                    // (plugin 1.48.0: an older one has no such switch, and its answer leaves it on)
                    toggle(\.outings, "outings", Text("Days Out", comment: "Follow-Through: the outings switch"),
                           Text("When you say you're off somewhere today, the photos from it afterwards, the best few ready to share. Needs Photos in Phone Tools.", comment: "Follow-Through: under the outings switch"),
                           symbol: "figure.walk.motion")
                    // (plugin 1.54.0; the phone sends what it found of them, `Appointments.send`)
                    toggle(\.appointments, "appointments", Text("Appointments", comment: "Follow-Through: the appointments switch"),
                           Text("A haircut, the dentist or the vet about due by your usual gap with nothing booked, and after a doctor's visit, what to follow up. Needs full access to your calendars.", comment: "Follow-Through: under the appointments switch"),
                           symbol: "calendar.badge.clock")
                    toggle(\.arrivals, "arrivals", Text("New to Watch", comment: "Follow-Through: the arrivals switch"),
                           Text("A film on your watch list new on Jellyfin, a new season of a series you finished.", comment: "Follow-Through: under the arrivals switch"),
                           symbol: "sparkles.tv")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                    if let profile = shown.paperless {
                        Text("Paperless is read with the keys in \(profile == "default" ? String(localized: "your main agent", comment: "Follow-Through: Jellyfin found in the main profile") : profile)'s settings: new documents are checked for bills and what runs out.", comment: "Follow-Through: where Paperless's address and key were found")
                    }
                    if shown.jellyfinFound, let profile = shown.jellyfin {
                        Text("Jellyfin is reached with the keys in \(profile == "default" ? String(localized: "your main agent", comment: "Follow-Through: Jellyfin found in the main profile") : profile)'s settings.", comment: "Follow-Through: where Jellyfin's address and key were found")
                    } else {
                        Text("No Jellyfin found: new seasons still come from your watch lists. To add Jellyfin, ask your agent to request JELLYFIN_URL and JELLYFIN_API_KEY.", comment: "Follow-Through: Jellyfin isn't set up")
                    }
                    }
                }

                Section {
                    if shown.items.isEmpty {
                        Text("Nothing yet. As mail comes and goes, what needs following shows here.", comment: "Follow-Through: nothing being followed")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown.items) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.title).lineLimit(2)
                                if !item.detail.isEmpty {
                                    Text(verbatim: item.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        } icon: { Image(systemName: item.symbol) }
                        .accessibilityIdentifier("follow-\(item.kind)")
                    }
                    .onDelete { rows in
                        for id in rows.compactMap({ shown.items.indices.contains($0) ? shown.items[$0].id : nil }) { drop(id) }
                    }
                } header: {
                    Text("Following Now", comment: "Follow-Through: what's being followed")
                } footer: {
                    Text("Read from your mail on your Hermes, in English, with no model. Only what didn't happen comes back, as an idea card, in the day and at most hourly. Swipe one away to stop following it.", comment: "Follow-Through: footer of the list")
                }
            } else if loaded {
                Section {
                    Text("Your Hermes can't say. Follow-Through takes the Redde plugin 1.40: update it in Settings › Redde Plugin.", comment: "Follow-Through: the plugin is too old")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(.red) } }
        }
        .navigationTitle(Text("Follow-Through", comment: "Settings › Your Day: what the agent follows up on from mail and watch lists"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    private func toggle(_ key: WritableKeyPath<FollowThrough, Bool>, _ name: String, _ title: Text, _ detail: Text, symbol: String) -> some View {
        Toggle(isOn: Binding(get: { shown?[keyPath: key] ?? true }, set: { on in
            shown?[keyPath: key] = on
            Task { await set(name, on) }
        })) {
            Label { VStack(alignment: .leading, spacing: 2) { title; detail.font(.footnote).foregroundStyle(.secondary) } } icon: { Image(systemName: symbol) }
        }
        .accessibilityIdentifier("follow-switch-\(name)")
    }

    private func load() async {
        if let got = await FollowThrough.run("follow list") { shown = got }
        loaded = true
    }

    private func set(_ name: String, _ on: Bool) async {
        problem = nil
        guard await FollowThrough.run("follow set \(name) \(on ? "on" : "off")") != nil else {
            problem = String(localized: "Couldn't reach your Hermes. Try again in a moment.", comment: "A goal's step couldn't be ticked: the server didn't answer")
            await load()
            return
        }
    }

    private func drop(_ id: String) {
        shown?.items.removeAll { $0.id == id }
        Task {
            if let got = await FollowThrough.run("follow drop \(id)") { shown?.items = got.items }
        }
    }
}
