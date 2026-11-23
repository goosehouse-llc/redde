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
    }

    var mail = true
    var orders = true
    var arrivals = true
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
                        due: (row["due"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
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
                           Text("What you said you'd send, questions waiting on an answer, mail you owe a reply.", comment: "Follow-Through: under the mail switch"),
                           symbol: "envelope.badge")
                    toggle(\.orders, "orders", Text("Orders & Trials", comment: "Follow-Through: the orders switch"),
                           Text("Deliveries running late, return windows closing, trials about to charge.", comment: "Follow-Through: under the orders switch"),
                           symbol: "shippingbox")
                    toggle(\.arrivals, "arrivals", Text("New to Watch", comment: "Follow-Through: the arrivals switch"),
                           Text("A film on your watch list new on Jellyfin, a new season of a series you finished.", comment: "Follow-Through: under the arrivals switch"),
                           symbol: "sparkles.tv")
                } footer: {
                    if shown.jellyfinFound, let profile = shown.jellyfin {
                        Text("Jellyfin is reached with the keys in \(profile == "default" ? String(localized: "your main agent", comment: "Follow-Through: Jellyfin found in the main profile") : profile)'s settings.", comment: "Follow-Through: where Jellyfin's address and key were found")
                    } else {
                        Text("No Jellyfin found: new seasons still come from your watch lists. To add Jellyfin, ask your agent to request JELLYFIN_URL and JELLYFIN_API_KEY.", comment: "Follow-Through: Jellyfin isn't set up")
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
                    Text("Your Hermes can't say. Follow-Through takes the Redde plugin 1.39: update it in Settings › Redde Plugin.", comment: "Follow-Through: the plugin is too old")
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
