#if DEBUG
import Foundation

/// `-echo.demoInbox`: a made-up inbox answered as the plugin would (tmp/mail-contract.md), so the
/// screens go through the same reading as the real thing. Nobody real: example.com addresses.
/// `-echo.demoInbox setup` shows nothing set up yet.
@MainActor
enum MailDemo {
    static var on: Bool { DevHooks.has("-echo.demoInbox") }
    static var empty: Bool { DevHooks.value("-echo.demoInbox") == "setup" }
    /// `-echo.demoInbox two`: a second account, Work, for All Mailboxes.
    static var two: Bool { DevHooks.value("-echo.demoInbox") == "two" }

    static let workThreads: [[String: Any]] = [
        work("w1", "Lena Fischer", "lena@work.example.com", "Q4 plan review", "Can you look over the Q4 plan before Monday?",
             "needs_reply", "Lena asks you to review the Q4 plan before Monday.", minutes: 25, unread: true),
        work("w2", "IT Desk", "it@work.example.com", "Laptop update tonight", "Your laptop will restart for updates at 10 PM…",
             "important", "Your work laptop restarts for updates at 10 PM tonight.", minutes: 200, unread: true),
    ]

    private static func work(_ id: String, _ from: String, _ address: String, _ subject: String, _ snippet: String, _ bucket: String,
                             _ summary: String, minutes: Double, unread: Bool) -> [String: Any] {
        var t = thread(id, from, address, subject, snippet, bucket, summary, minutes: minutes, unread: unread)
        t["id"] = "work:INBOX:\(id)"
        t["thread"] = "work:t:\(id)"
        return t
    }

    static func install(in center: MailCenter) {
        center.reachable = { true }
        center.plugin = { words in answer(words) }
        Task { await center.refresh(.important) }
    }

    private static let now = Date.now.timeIntervalSince1970

    static let threads: [[String: Any]] = [
        thread("d1", "Priya Nair", "priya@example.com", "Contract signed: next steps", "Signed copy attached. Can we start the 10th?",
               "important", "Priya signed the contract and asks to start on the 10th.", minutes: 12, unread: true, attachments: true),
        thread("d2", "Riverside School", "office@riverside.example.com", "Early pickup Friday", "Classes end at 12:30 this Friday for staff training…",
               "important", "School lets out at 12:30 on Friday.", minutes: 95, unread: true),
        thread("d3", "Marco Bellini", "marco@example.com", "Lunch Thursday?", "Are you free Thursday? The new place on 5th…",
               "needs_reply", "Marco asks if you're free for lunch Thursday.", minutes: 40, unread: true),
        thread("d4", "Dana Okafor", "dana@example.com", "Re: Kitchen quote", "Thanks, could you confirm the cabinet colour by Wednesday?",
               "needs_reply", "Dana needs the cabinet colour by Wednesday.", minutes: 300, unread: false),
        thread("d5", "Northwind Bank", "alerts@northwind.example.com", "Your statement is ready", "Your October statement is available…",
               "notifications", "October's statement is ready.", minutes: 600, unread: false),
        thread("d6", "Hearth Delivery", "orders@hearth.example.com", "Your order has shipped", "Order #48213 is on its way, arriving Thursday.",
               "receipts", "Your order ships, arriving Thursday.", minutes: 720, unread: true),
        thread("d7", "The Morning Read", "news@morningread.example.com", "Five things for Tuesday", "Today: rates, rain and a rocket launch…",
               "newsletters", "A daily news digest.", minutes: 180, unread: true, unsubscribe: true),
        thread("d8", "Lumen Coffee", "hello@lumen.example.com", "20% off beans this week", "Our autumn roast is back…",
               "promotions", "A coffee sale, 20% off.", minutes: 1500, unread: false, unsubscribe: true),
        thread("d9", "Shopwell", "receipts@shopwell.example.com", "Your receipt from Shopwell", "Thanks for your order. Total $42.18…",
               "receipts", "A $42.18 receipt.", minutes: 2000, unread: false, unsubscribe: false, receipt: true),
        thread("d10", "Riverside PTA", "pta@riverside.example.com", "Bake sale sign-up", "We need six more bakers for Saturday's sale…",
               "p-school", "The PTA asks for bakers for Saturday.", minutes: 260, unread: true),
        thread("d11", "Pine Lake Cabins", "stay@pinelake.example.com", "Your stay is confirmed", "Check-in Friday from 3 pm, cabin 4…",
               "receipts", "Cabin 4 booked, check-in Friday 3 pm.", minutes: 3000, unread: false),
        thread("d12", "Mesh Wi-Fi", "no-reply@mesh.example.com", "New sign-in to your account", "A new device signed in from Orlando…",
               "notifications", "A new sign-in to your Wi-Fi account.", minutes: 50, unread: true),
    ]

    /// The person's own piles in the demo (Email settings › Piles), changed by `piles set`.
    static var ownPiles: [[String: Any]] = [
        ["id": "p-school", "name": "School", "about": "Riverside School, the PTA and the kids' teachers", "own": true]]

    static var pileList: [[String: Any]] {
        ["important", "needs_reply", "fyi", "receipts", "notifications", "promotions", "newsletters"].map { ["id": $0, "about": "", "own": false] }
            + ownPiles
    }

    private static func thread(_ id: String, _ from: String, _ address: String, _ subject: String, _ snippet: String, _ bucket: String,
                               _ summary: String, minutes: Double, unread: Bool, attachments: Bool = false, unsubscribe: Bool = false,
                               receipt: Bool = false) -> [String: Any] {
        ["id": "main:INBOX:\(id)", "thread": "main:t:\(id)", "from": from, "address": address, "subject": subject, "snippet": snippet,
         "date": Int(now - minutes * 60), "unread": unread, "bucket": bucket, "summary": summary, "has_attachments": attachments,
         "can_unsubscribe": unsubscribe, "receipt": receipt, "flagged": false]
    }

    static var rules: [[String: Any]] = [
        ["id": "r1", "when": ["from": "receipts@shopwell.example.com"], "do": "archive", "notify": false, "made": Int(now - 86_400 * 3)],
        ["id": "r2", "when": ["from": "office@riverside.example.com"], "do": "notify", "notify": true, "made": Int(now - 86_400 * 9)],
        ["id": "paperless", "name": "Receipts with attachments → Paperless", "enabled": true, "builtin": true, "match": "all",
         "when": ["receipt": true, "attachment": "any"], "do": "label", "arg": "Paperless", "archive": false, "matches": 4],
        ["id": "t2", "when": ["domain": "riverside.example.com"], "do": "label", "arg": "School", "also": ["Kids"], "archive": false, "match": "all",
         "enabled": true, "account": "main", "matches": 2],
        ["id": "t3", "name": "Newsletters to read later", "when": ["bucket": "newsletters", "subject": "weekly"], "do": "label",
         "arg": "Reading", "archive": true, "match": "all", "enabled": false, "account": "main"],
    ]

    static var suggestions: [[String: Any]] = [
        ["id": "a1b2c3", "kind": "repeated", "why": "You archived 6 emails from deals@shopwell.example.com this month.",
         "rule": ["when": ["from": "deals@shopwell.example.com"], "do": "archive", "account": "main"]],
        ["id": "d4e5f6", "kind": "receipts", "why": "4 receipts from orders@market.example.com lately.",
         "rule": ["when": ["from": "orders@market.example.com", "receipt": true], "do": "label", "arg": "Receipts", "account": "main"]],
    ]

    /// Lumen Coffee's email as its sender laid it out: a 600-point newsletter, so the reader has
    /// to fit it, its picture made here (no network in a demo).
    static let newsletter = """
        <table width="600" align="center" cellpadding="0" cellspacing="0" style="font-family: Georgia, serif; background: #faf6f0">
        <tr><td style="background: #3b2a20; color: #f5e6d3; padding: 28px; text-align: center; font-size: 30px; letter-spacing: 3px">LUMEN COFFEE</td></tr>
        <tr><td><img width="600" height="260" alt="Autumn roast" src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='600' height='260'><defs><linearGradient id='g' x1='0' x2='1'><stop offset='0' stop-color='%23c2703d'/><stop offset='1' stop-color='%236b3e26'/></linearGradient></defs><rect width='600' height='260' fill='url(%23g)'/><circle cx='300' cy='130' r='70' fill='%23f5e6d3' opacity='.85'/><text x='300' y='142' font-size='34' text-anchor='middle' fill='%233b2a20' font-family='Georgia'>Autumn</text></svg>"></td></tr>
        <tr><td style="padding: 28px 36px; color: #3b2a20; font-size: 18px; line-height: 1.5">
        <h1 style="font-size: 28px; margin: 0 0 12px">Our autumn roast is back</h1>
        <p>Caramel, baked apple and a little smoke. Roasted Monday, at your door by Thursday.</p>
        <p style="text-align: center; margin: 28px 0"><a href="https://example.com/shop" style="background: #c2703d; color: #fff; padding: 14px 28px; border-radius: 30px; text-decoration: none; font-family: -apple-system, sans-serif; font-weight: 600">Take 20% off</a></p>
        <p style="font-size: 13px; color: #8a7565; text-align: center">You signed up at lumen.example.com · <a href="https://example.com/unsubscribe" style="color: #8a7565">Unsubscribe</a></p>
        </td></tr></table>
        """

    /// The reader's email, for its screenshot.
    static var readerThread: MailThread {
        MailThread(json: (try? JSONValue.parse(JSONSerialization.data(withJSONObject: threads[2]))) ?? .null)
            ?? MailThread(id: "main:INBOX:d3", from: "Marco Bellini", address: "marco@example.com", subject: "Lunch Thursday?", date: .now, unread: true,
                          bucket: .needsReply, summary: nil)
    }

    /// An inbox card and a drafted reply, as the plugin's agent would show them.
    static var cards: [ReplyCard] {
        let inbox: [String: Any] = ["type": "inbox", "account": "main", "title": "Your inbox this morning", "buckets": [
            ["bucket": "important", "count": 2, "threads": Array(threads[0...1])],
            ["bucket": "needs_reply", "count": 2, "threads": Array(threads[2...3])],
            ["bucket": "newsletters", "count": 3, "threads": Array(threads[6...7])]]]
        let draft: [String: Any] = ["type": "review", "kind": "email", "title": "Reply to Marco", "draft": [
            "id": "dr1", "to": ["marco@example.com"], "cc": [], "subject": "Re: Lunch Thursday?",
            "body": "Thursday works. 12:30 at the new place on 5th?\n\nSee you then", "reply_to": "main:INBOX:d3", "account": "main", "hash": "9f2c"]]
        let json = (try? JSONValue.parse(JSONSerialization.data(withJSONObject: ["cards": [inbox, draft]]))) ?? .null
        return ReplyCards.parse(json)
    }

    private static var workAccount: [String: Any] {
        var counts: [String: Int] = [:]
        for t in workThreads { counts[t["bucket"] as! String, default: 0] += 1 }
        return ["id": "work", "name": "Work", "address": "me@work.example.com", "provider": "fastmail", "via": "imap",
                "usable": true, "problem": NSNull(), "last_sync": Int(now - 300),
                "unread": workThreads.filter { $0["unread"] as! Bool }.count, "buckets": counts]
    }

    static var brief: [String: Any] {
        ["accounts": [["id": "main", "name": "Home", "unread": 6, "important": 2, "needs_reply": 2, "newsletters": 3, "as_of": Int(now - 600),
                       "top": [threads[2], threads[3], threads[0], threads[1]]]]]
    }

    static func answer(_ words: String) -> String {
        let parts = words.split(separator: " ", maxSplits: 3).map(String.init)
        func reply(_ object: Any) -> String { "redde-push mail " + MailWire.json(object) }
        if words.hasPrefix("keys ask") { return "redde-push keys {\"error\":\"demo\"}" }
        guard parts.first == "mail", parts.count > 1 else { return "" }
        switch parts[1] {
        case "status":
            if empty { return reply(["accounts": [], "triage": "auto", "sync_minutes": 3]) }
            var counts: [String: Int] = [:]
            for t in threads { counts[t["bucket"] as! String, default: 0] += 1 }
            return reply(["accounts": [["id": "main", "name": "Home", "address": "me@example.com", "provider": "gmail", "via": "imap",
                                        "usable": true, "problem": NSNull(), "last_sync": Int(now - 120),
                                        "can_label": true, "labels": ["groups": true], "labelled": 46,
                                        "backfill": ["state": "running", "done": 300, "total": 840],
                                        "suggest": true, "suggestions": suggestions.map { ["id": $0["id"]!, "why": $0["why"]!] },
                                        "unread": threads.filter { $0["unread"] as! Bool }.count, "buckets": counts, "piles": counts]]
                          + (two ? [workAccount] : []),
                          "triage": "auto", "sync_minutes": 3, "setup": ["command": true], "brief": brief, "piles": pileList])
        case "brief":
            return reply(["brief": brief])
        case "setup":
            return reply(["written": ["REDDE_MAIL_ADDRESS", "REDDE_MAIL_PROVIDER"], "status": ["accounts": [], "setup": ["command": true]]])
        case "list":
            let bucket = parts.count > 2 ? parts[2].split(separator: " ").first.map(String.init) ?? "all" : "all"
            let account = words.contains(" work") ? "work" : "main"
            let listed = (account == "work" ? workThreads : threads).filter { bucket == "all" || $0["bucket"] as! String == bucket }
            return reply(["account": account, "bucket": bucket, "page": 0, "more": false, "threads": listed])
        case "read":
            let id = parts.count > 2 ? parts[2] : ""
            guard let t = threads.first(where: { $0["id"] as! String == id }) else { return reply(["error": "unknown_id", "message": "No such email."]) }
            return reply(["id": id, "from": t["from"]!, "address": t["address"]!, "to": ["me@example.com"], "cc": [], "subject": t["subject"]!,
                          "date": t["date"]!, "text": "\(t["snippet"]!)\n\nIf Thursday doesn't work, Friday at 1 is fine too. The menu is at the link below.\n\nSee you soon,\n\(t["from"]!)",
                          "links": [["text": "Menu", "url": "https://example.com/menu"]],
                          "attachments": (t["has_attachments"] as! Bool) ? [["name": "contract-signed.pdf", "size": 182_344]] : [],
                          "can_unsubscribe": t["can_unsubscribe"]!, "unsubscribe": (t["can_unsubscribe"] as! Bool) ? "one_click" : NSNull(),
                          "html": id == "main:INBOX:d8" ? newsletter as Any : NSNull()])
        case "act":
            let ids = parts.count > 3 ? parts[3].split(separator: " ").first.map { $0.split(separator: ",").map(String.init) } ?? [] : []
            return reply(["done": ids, "failed": [], "log": "m\(Int(now))-1"])
        case "rules":
            // A plain list, as the app sends it since 11-05 (or {"rules": […]}, as before).
            if parts.count > 2, parts[2].hasPrefix("set"), let json = try? JSONValue.parse(Data(words.drop { $0 != "[" && $0 != "{" }.utf8)) {
                rules = (json.array ?? json["rules"]?.array ?? []).compactMap { r in try? JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any] }
            }
            return reply(["rules": rules])
        case "log":
            return reply(["log": [
                ["id": "m1", "at": Int(now - 3_000), "rule": "r1", "action": "archive", "account": "main", "ids": ["main:INBOX:x1"],
                 "title": "Archived a receipt from Shopwell", "undone": false, "by": "rule"],
                ["id": "m2", "at": Int(now - 7_200), "rule": "r2", "action": "notify", "account": "main", "ids": ["main:INBOX:d2"],
                 "title": "Told you: Riverside School wrote", "undone": false, "by": "rule"]]])
        case "setup-check":
            return reply(["account": "main", "imap": "ok", "smtp": "ok", "problem": NSNull()])
        case "draft-edit":
            return reply(["id": "dr1", "to": ["marco@example.com"], "cc": [], "subject": "Re: Lunch Thursday?", "body": "", "hash": "edited"])
        case "draft-send":
            return reply(["sent": true, "id": "dr1"])
        case "settings":
            return reply(["triage": "auto", "sync_minutes": 3])
        case "piles":
            if parts.count > 2, parts[2].hasPrefix("set"), let json = try? JSONValue.parse(Data(words.drop { $0 != "[" }.utf8)) {
                ownPiles = (json.array ?? []).enumerated().map { n, p in
                    let name = p["name"]?.string ?? "Pile"
                    return ["id": p["id"]?.string ?? "p-" + name.lowercased().filter { $0.isLetter || $0.isNumber }, "name": name,
                            "about": p["about"]?.string ?? "", "own": true]
                }
            }
            return reply(["piles": pileList])
        case "suggest":
            if parts.count > 2, parts[2].hasPrefix("dismiss") || parts[2].hasPrefix("accept") {
                let id = parts[2].split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
                suggestions.removeAll { $0["id"] as? String == id }
            }
            return reply(["account": "main", "on": true, "suggestions": suggestions])
        case "labels":
            return reply(["account": "main", "labels": ["Family", "Paperless", "Receipts", "School", "Travel"], "redde": ["Redde/Important"]])
        default:
            return reply(["error": "bad_args", "message": "Not in the demo."])
        }
    }
}
#endif
