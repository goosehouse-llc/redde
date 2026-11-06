import SwiftUI

/// Settings › Agent › Email › an account › Gmail Labels (asked 2026-11-03: "applied to the gmail
/// account… receipts can automatically go into the paperless tag", then "allow for custom tagging
/// rules"). Redde's sorting shown in Gmail as Redde/… labels, and tagging rules that label what
/// matches, the ready-made Paperless one first. Gmail only: other providers have folders, and
/// filing there would mean copies of each email.
struct MailTaggingView: View {
    let accountID: String
    @State private var center = MailCenter.shared
    @State private var problem: String?
    @State private var busy = false
    @State private var confirmRemove: String?
    @State private var editing: MailRule?
    @State private var adding = false

    private var account: MailAccount? { center.accounts.first { $0.id == accountID } }
    private var rules: [MailRule] {
        center.rules.filter { $0.isTagging && ($0.account == nil || $0.account == accountID) }
            .sorted { $0.builtin && !$1.builtin }
    }
    private var anyTagging: Bool { rules.contains(where: \.enabled) }

    var body: some View {
        Form {
            if let account {
                Section {
                    Toggle(isOn: Binding(get: { account.groupLabels }, set: { on in run { try await center.setGroupLabels(on, account: accountID) } })) {
                        Text("Show Sorting in Gmail", comment: "Email labels: Redde's groups as Gmail labels")
                    }
                    .disabled(busy)
                    if !account.groupLabels, account.labelled > 0 {
                        Button(role: .destructive) { confirmRemove = "groups" } label: {
                            Text("Remove Redde's Sorting Labels from Gmail", comment: "Email labels: take the Redde/… labels off")
                        }
                    }
                } footer: {
                    Text("Each sorted email gets Redde/Important, Redde/Needs Reply, Redde/FYI or Redde/Newsletters in Gmail, so you see the sorting there too. Only labels are added: nothing is archived, moved or deleted for this.", comment: "Email labels: what Show Sorting in Gmail does")
                }

                Section {
                    ForEach(rules) { rule in
                        HStack(alignment: .firstTextBaseline) {
                            Button { editing = rule } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name ?? rule.conditions).foregroundStyle(.primary)
                                    Text(TagRuleText.line(rule)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Toggle(isOn: Binding(get: { rule.enabled }, set: { on in
                                var changed = rule
                                changed.enabled = on
                                run { try await center.put(changed) }
                            })) { Text(rule.name ?? rule.conditions) }
                            .labelsHidden()
                        }
                        .swipeActions {
                            if !rule.builtin {
                                Button(role: .destructive) { run { try await center.remove(rule) } } label: {
                                    Label { Text("Delete", comment: "Email tagging rule: delete it") } icon: { Image(systemName: "trash") }
                                }
                            }
                        }
                    }
                    // Ready-made (asked 11-05: "a Receipts preset so I don't have to build it"): every
                    // receipt, attachment or not, labelled Receipts. Offered until there is one.
                    if !rules.contains(where: { $0.receipt == true && $0.attachment == nil }) {
                        Button { run { try await center.add(TagRulePresets.receipts(account: accountID)) } } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add Receipts Rule", comment: "Email labels: a ready-made rule for every receipt")
                                    Text("Labels every receipt and order email Receipts", comment: "Email labels: what the ready-made receipts rule does")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "receipt") }
                        }
                        .disabled(busy)
                    }
                    Button { adding = true } label: {
                        Label { Text("Add Tagging Rule", comment: "Email labels: make a tagging rule") } icon: { Image(systemName: "plus.circle") }
                    }
                } header: {
                    Text("Tagging Rules", comment: "Email labels: section")
                } footer: {
                    Text("Rules run on your Hermes as mail arrives, without your agent, on mail from the last 30 days unless a rule says otherwise. What they do is in Agent Activity, with Undo. They never delete mail, and archive only when a rule says so. Paperless-ngx: add a mail rule for this account that takes mail with the label Paperless.", comment: "Email labels: how tagging rules run")
                }

                Section {
                    if let job = account.backfill, job.busy {
                        HStack {
                            ProgressView()
                            Text(job.total > 0 ? String(localized: "Labelling older mail: \(job.done) of \(job.total)", comment: "Email labels: backfill progress")
                                 : String(localized: "Looking at the last 30 days…", comment: "Email labels: backfill starting"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Button { run { try await center.backfillLabels(account: accountID) } } label: {
                            Text("Apply to the Last 30 Days", comment: "Email labels: label older mail once")
                        }
                        .disabled(busy || !(account.groupLabels || anyTagging))
                        if let job = account.backfill, job.state == "done" {
                            Text("Done: \(job.total) emails looked at.", comment: "Email labels: backfill finished").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if account.labelled > 0 {
                        Button(role: .destructive) { confirmRemove = "all" } label: {
                            Text("Remove All of Redde's Labels from Gmail", comment: "Email labels: take every label Redde added off")
                        }
                        .disabled(account.unlabel?.busy == true)
                    }
                } header: {
                    Text("Older Mail", comment: "Email labels: section")
                } footer: {
                    Text("New mail is labelled as it arrives. Older mail is labelled once, when you ask: up to 2,000 emails, a few at a time. Removing takes off only labels Redde added itself; a label you put on stays.", comment: "Email labels: backfill and removal")
                }

                if let problem = problem ?? account.labelsProblem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(Text("Gmail Labels", comment: "Email labels page: title"))
        .confirmationDialog(Text("Remove Redde's labels?", comment: "Email labels: confirm removing"),
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button(role: .destructive) {
                let which = confirmRemove ?? "groups"
                confirmRemove = nil
                run { try await center.removeLabels(account: accountID, which: which) }
            } label: { Text("Remove Labels", comment: "Email labels: confirm removing") }
            Button(role: .cancel) { confirmRemove = nil } label: { Text("Cancel") }
        } message: {
            Text("Your emails stay where they are. Only the labels Redde added come off.", comment: "Email labels: what removing does")
        }
        .sheet(item: $editing) { rule in TagRuleEditor(accountID: accountID, rule: rule) }

        .sheet(isPresented: $adding) { TagRuleEditor(accountID: accountID) }
        .task {
            await center.refreshStatus()
            await center.loadRules()
        }
        .refreshable {
            await center.refreshStatus()
            await center.loadRules()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

/// Tagging rules ready-made.
nonisolated enum TagRulePresets {
    /// Every receipt (the plugin's receipt spotting: subject and sender), labelled Receipts, on mail
    /// from the last 30 days; nothing archived.
    static func receipts(account: String, now: Date = .now) -> MailRule {
        var rule = MailRule(id: "receipts-\(Int(now.timeIntervalSince1970))", action: .label,
                            arg: String(localized: "Receipts", comment: "The ready-made receipts rule's Gmail label"), made: now)
        rule.name = String(localized: "Receipts", comment: "The ready-made receipts rule's name")
        rule.receipt = true
        rule.newerThanDays = 30
        rule.account = account
        return rule
    }
}

/// A tagging rule's second line: "Label Paperless · 4 in 30 days".
nonisolated enum TagRuleText {
    static func line(_ rule: MailRule) -> String {
        var parts = [String(localized: "Label \(rule.labels.joined(separator: ", "))", comment: "An email tagging rule: the labels it adds")]
        if rule.name != nil { parts.insert(rule.conditions, at: 0) }
        if rule.archive { parts.append(String(localized: "and archive", comment: "An email tagging rule that also archives")) }
        if rule.matches > 0 { parts.append(String(localized: "\(rule.matches) in 30 days", comment: "An email tagging rule: how many emails it labelled lately")) }
        if !rule.enabled { parts.append(String(localized: "Off", comment: "An email tagging rule that's turned off")) }
        return parts.joined(separator: " · ")
    }

    /// "shop.example.com" from "orders@shop.example.com".
    static func domain(of address: String) -> String? {
        let host = address.split(separator: "@").last.map(String.init)?.lowercased()
        return host?.contains(".") == true ? host : nil
    }
}

/// Making or changing a tagging rule: its conditions (all of them or any one), its labels (ones the
/// account has, or new ones; up to five, asked 11-06), and whether it also archives (off unless set).
struct TagRuleEditor: View {
    let accountID: String
    var rule: MailRule?
    /// From an email's menu: its sender's domain and its subject.
    var prefillDomain: String?
    var prefillSubject: String?
    /// A suggestion being changed before it's accepted: saving accepts it as changed.
    var accepting: ((MailRule) async throws -> Void)?
    /// Gmail: labels can be added. Elsewhere a rule archives or tells.
    var canLabel = true
    @State private var center = MailCenter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var matchAny = false
    @State private var from = ""
    @State private var domain = ""
    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var text = ""
    @State private var attachment: MailRule.Attachment?
    @State private var bucket: MailBucket?
    @State private var receipt = false
    @State private var days = 30
    @State private var label = ""
    /// Labels after the first.
    @State private var more: [ExtraLabel] = []
    @State private var action: MailRule.Action = .label
    @State private var archive = false
    @State private var enabled = true
    @State private var labels: [String] = []
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name (optional)", comment: "Email tagging rule: its name"), text: $name)
                }
                Section {
                    Picker(selection: $matchAny) {
                        Text("All of These", comment: "Email tagging rule: every condition").tag(false)
                        Text("Any of These", comment: "Email tagging rule: one condition is enough").tag(true)
                    } label: { Text("Match", comment: "Email tagging rule: all or any") }
                    field(String(localized: "From (name or address)", comment: "Email tagging rule: sender"), $from)
                    field(String(localized: "From domain (shop.example.com)", comment: "Email tagging rule: sender's domain"), $domain)
                    field(String(localized: "To", comment: "Email tagging rule: recipient"), $to)
                    field(String(localized: "Cc", comment: "Email tagging rule: copied"), $cc)
                    TextField(String(localized: "Subject has", comment: "Email tagging rule: words in the subject"), text: $subject)
                    TextField(String(localized: "Text has (first lines)", comment: "Email tagging rule: words in the email"), text: $text)
                    Picker(selection: $attachment) {
                        Text("Doesn't Matter", comment: "Email tagging rule: no attachment condition").tag(MailRule.Attachment?.none)
                        ForEach(MailRule.Attachment.allCases) { Text($0.label).tag(Optional($0)) }
                    } label: { Text("Attachment", comment: "Email tagging rule: attachment") }
                    Picker(selection: $bucket) {
                        Text("Doesn't Matter", comment: "Email tagging rule: no group condition").tag(MailBucket?.none)
                        ForEach(MailBucket.shown) { Text($0.label).tag(Optional($0)) }
                    } label: { Text("Group", comment: "Email tagging rule: Redde's group") }
                    Toggle(isOn: $receipt) { Text("Is a Receipt", comment: "Email tagging rule: receipts and orders") }
                    Picker(selection: $days) {
                        Text("Last 7 Days", comment: "Email tagging rule: age").tag(7)
                        Text("Last 30 Days", comment: "Email tagging rule: age").tag(30)
                        Text("Last 90 Days", comment: "Email tagging rule: age").tag(90)
                        Text("Last Year", comment: "Email tagging rule: age").tag(365)
                        Text("Any Age", comment: "Email tagging rule: age").tag(0)
                    } label: { Text("Mail From", comment: "Email tagging rule: how old mail it looks at") }
                } header: {
                    Text("When an Email Is", comment: "Email tagging rule: conditions")
                }
                Section {
                    Picker(selection: $action) {
                        if canLabel { Text("Label It", comment: "Email rule: add a label").tag(MailRule.Action.label) }
                        Text("Archive It", comment: "Email rule: archive").tag(MailRule.Action.archive)
                        Text("Tell Me", comment: "Email rule: a notification").tag(MailRule.Action.notify)
                    } label: { Text("Do", comment: "Email rule: what it does") }
                }
                if action == .label { Section {
                    LabelChoice(name: $label, labels: labels) { Text("Label", comment: "Email tagging rule: the label") }
                    ForEach($more) { $extra in
                        LabelChoice(name: $extra.name, labels: labels, remove: { more.removeAll { $0.id == extra.id } }) {
                            Text("Another Label", comment: "Email tagging rule: a second or later label it adds")
                        }
                    }
                    if more.count < 4 {
                        Button { more.append(ExtraLabel()) } label: {
                            Label { Text("Add Another Label", comment: "Email tagging rule: add a second label") } icon: { Image(systemName: "plus.circle") }
                        }
                    }
                    Toggle(isOn: $archive) { Text("Also Archive", comment: "Email tagging rule: take it out of the inbox too") }
                } header: {
                    Text("Then", comment: "Email tagging rule: what it does")
                } footer: {
                    Text(archive ? String(localized: "Matching emails get every label here and leave the inbox (they stay in All Mail). Undo puts them back.", comment: "Email tagging rule: also archive")
                         : String(localized: "Matching emails get every label here and stay in your inbox.", comment: "Email tagging rule: label only"))
                } }
                Section { Toggle(isOn: $enabled) { Text("On", comment: "Email tagging rule: turned on") } }
                if let problem { Section { Text(problem).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(rule == nil ? Text("New Tagging Rule", comment: "Email tagging rule sheet: title")
                             : Text("Tagging Rule", comment: "Email tagging rule sheet: title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave || saving)
                }
            }
            .task { fill(); if canLabel { labels = (try? await center.labelNames(account: accountID)) ?? [] } }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 680)
        #endif
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            #endif
    }

    private var trimmed: [String] { [from, domain, to, cc, subject, text].map { $0.trimmingCharacters(in: .whitespaces) } }
    private var canSave: Bool {
        (trimmed.contains { !$0.isEmpty } || attachment != nil || bucket != nil || receipt)
            && (action != .label || !label.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func fill() {
        if let rule {
            name = rule.name ?? ""; matchAny = rule.matchAny
            from = rule.from ?? ""; domain = rule.domain ?? ""; to = rule.to ?? ""; cc = rule.cc ?? ""
            subject = rule.subject ?? ""; text = rule.body ?? ""; attachment = rule.attachment
            bucket = rule.bucket.flatMap(MailBucket.init(rawValue:)); receipt = rule.receipt == true
            days = rule.newerThanDays ?? 30; label = rule.arg ?? ""; more = rule.also.map { ExtraLabel(name: $0) }; archive = rule.archive; enabled = rule.enabled
            action = [.label, .archive, .notify].contains(rule.action) ? rule.action : .label
        }
        if rule == nil {
            domain = prefillDomain ?? ""; subject = prefillSubject ?? ""
        }
        if !canLabel && action == .label { action = .archive }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var made = rule ?? MailRule(id: "t\(Int(Date.now.timeIntervalSince1970))", action: .label)
        let t = trimmed
        made.action = action
        made.name = name.trimmingCharacters(in: .whitespaces).nilIfEmpty
        made.matchAny = matchAny
        made.from = t[0].nilIfEmpty; made.domain = t[1].nilIfEmpty?.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        made.to = t[2].nilIfEmpty; made.cc = t[3].nilIfEmpty; made.subject = t[4].nilIfEmpty; made.body = t[5].nilIfEmpty
        made.attachment = attachment; made.bucket = bucket?.rawValue; made.receipt = receipt ? true : nil
        made.newerThanDays = days == 30 ? nil : days
        var names: [String] = []
        for name in ([label] + more.map(\.name)).map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        made.arg = action == .label ? names.first : nil
        made.also = action == .label ? Array(names.dropFirst()) : []
        made.archive = action == .label && archive; made.enabled = enabled
        made.notify = action == .notify
        made.account = made.builtin ? made.account : accountID
        do {
            if let accepting { try await accepting(made) } else { try await center.put(made) }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A label after a rule's first, as the editor keeps it (named for `ForEach`).
private struct ExtraLabel: Identifiable {
    let id = UUID()
    var name = ""
}

/// One of a rule's labels: picked from the account's, or typed new. An extra one can be taken off.
private struct LabelChoice<Title: View>: View {
    @Binding var name: String
    let labels: [String]
    var remove: (() -> Void)?
    @ViewBuilder var title: Title

    var body: some View {
        if !labels.isEmpty {
            HStack {
                removeButton
                Picker(selection: $name) {
                    Text("New Label…", comment: "Email tagging rule: type a new label").tag("")
                    ForEach(labels, id: \.self) { Text($0).tag($0) }
                } label: { title }
            }
        }
        if labels.isEmpty || !labels.contains(name) {
            HStack {
                if labels.isEmpty { removeButton }
                TextField(String(localized: "Label name", comment: "Email tagging rule: a new label"), text: $name)
            }
        }
    }

    @ViewBuilder private var removeButton: some View {
        if let remove {
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove Label", comment: "Email tagging rule: take this label off the rule"))
        }
    }
}

/// Suggested rules for one account, every provider (11-03): the switch and the open suggestions,
/// each with Accept, Edit… and Dismiss. Nothing runs a suggestion until it's accepted. Where there
/// are no labels (not Gmail), only archive and tell-me rules are suggested.
struct MailSuggestionsSection: View {
    let account: MailAccount
    @State private var center = MailCenter.shared
    @State private var suggestions: [MailSuggestion] = []
    @State private var editing: MailSuggestion?
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { account.suggest }, set: { on in
                Task {
                    do {
                        try await center.setSuggest(on, account: account.id)
                        suggestions = on ? try await center.suggestions(account: account.id, refresh: true) : []
                        problem = nil
                    } catch { problem = error.localizedDescription }
                }
            })) {
                Text("Suggest Rules", comment: "Email: Redde proposes rules from patterns")
            }
            ForEach(suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 6) {
                    Text(suggestion.rule.described).font(.subheadline)
                    Text(suggestion.why).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Button { act { try await center.accept(suggestion, account: account.id) }; drop(suggestion) } label: {
                            Text("Accept", comment: "Email: make a suggested rule real")
                        }
                        Button { editing = suggestion } label: { Text("Edit…", comment: "Email: change a suggested rule, then accept it") }
                        Button(role: .destructive) { act { try await center.dismiss(suggestion, account: account.id) }; drop(suggestion) } label: {
                            Text("Dismiss", comment: "Email: never suggest this again")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Suggested for \(account.name)", comment: "Email: suggested rules for one account")
        } footer: {
            Text("Redde looks for patterns in what you already do, like the same sender archived again and again or newsletters left unread, at most once a day, without your agent. Nothing is labelled, archived or sent to you because of a suggestion until you accept it. Dismissed ones aren't suggested again.", comment: "Email: what Suggest Rules does")
        }
        .sheet(item: $editing) { suggestion in
            TagRuleEditor(accountID: account.id, rule: suggestion.rule, accepting: { edited in
                try await center.accept(suggestion, account: account.id, edited: edited)
                drop(suggestion)
            }, canLabel: account.canLabel)
        }
        .task(id: account.id) { suggestions = (try? await center.suggestions(account: account.id)) ?? [] }
    }

    private func drop(_ suggestion: MailSuggestion) { suggestions.removeAll { $0.id == suggestion.id } }

    private func act(_ work: @escaping () async throws -> Void) {
        Task { do { try await work(); problem = nil } catch { problem = error.localizedDescription } }
    }
}
