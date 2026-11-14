import SwiftUI

/// Settings › Agent › Email: the accounts on the Hermes, adding one, the sorting and the rules.
struct MailSettingsView: View {
    @State private var center = MailCenter.shared
    @State private var adding = false
    /// Asked to remove, waiting on his yes.
    @State private var removing: MailAccount?
    @State private var removingNow: String?
    /// Just removed: where its app password can be revoked too.
    @State private var removed: (name: String, provider: MailProvider)?

    var body: some View {
        Form {
            Section {
                if center.accounts.isEmpty {
                    Text("No email connected yet.", comment: "Email settings: nothing set up").foregroundStyle(.secondary)
                }
                ForEach(center.accounts) { account in
                    // One row an account, as in Settings › Mail (11-06: the row had grown labels,
                    // a test and a remove crammed under it); all of that is on its own page now.
                    NavigationLink {
                        MailAccountView(accountID: account.id, remove: { await remove($0) })
                    } label: {
                        accountRow(account)
                    }
                    .disabled(removingNow == account.id)
                    .swipeActions {
                        if MailCenter.removable(account) {
                            Button(role: .destructive) { removing = account } label: {
                                Label { Text("Remove", comment: "Email settings: swipe to remove an account") } icon: { Image(systemName: "trash") }
                            }
                        }
                    }
                }
                Button { adding = true } label: {
                    Label { Text("Add Email Account", comment: "Email settings: add an account") } icon: { Image(systemName: "plus.circle") }
                }
            } header: {
                Text("Accounts", comment: "Email settings: section")
            } footer: {
                Text("Your mail stays between your Hermes and your mail provider. Redde asks your Hermes when you open the Inbox; nothing goes through Redde's or anyone else's servers.", comment: "Email settings: where the mail goes")
            }

            if center.isSetUp {
                Section {
                    NavigationLink { InboxView() } label: {
                        Label { Text("Inbox", comment: "Email settings: open the inbox") } icon: { Image(systemName: "tray") }
                    }
                    NavigationLink { MailRulesView() } label: {
                        Label { Text("Rules", comment: "Email settings: the rules page") } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    }
                    if center.status?.hasPiles == true {
                        NavigationLink { MailPilesView() } label: {
                            Label { Text("Piles", comment: "Email piles page: title") } icon: { Image(systemName: "square.stack") }
                        }
                    }
                    if center.accounts.count > 1 {
                        // What the Inbox opens on, kept until changed here or in its menu (11-06).
                        Picker(selection: Binding(get: { center.inbox?.id ?? "" }, set: { center.accountID = $0 })) {
                            MailboxChoices()
                        } label: {
                            Label { Text("Inbox Shows", comment: "Email settings: which account the Inbox shows") } icon: { Image(systemName: "tray.2") }
                        }
                    }
                    Toggle(isOn: Binding(get: { center.status?.triage != "off" }, set: { on in Task { await center.setTriage(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sort New Mail", comment: "Email settings: the agent sorts the inbox")
                            Text(center.status?.hasPiles == true
                                 ? String(localized: "Your agent reads the sender, subject and first lines of each new email, never the whole of it, and puts it in one of the piles: yours, or Important, Needs Reply, FYI and the rest. Off, Redde sorts by the email's headers and your provider's categories only.", comment: "Email settings: what sorting does, with the piles of plugin 1.31.0")
                                 : String(localized: "Your agent reads the sender, subject and first lines of each new email, never the whole of it, and files it as Important, Needs Reply, FYI or Newsletters. Off, Redde sorts by your provider's own categories only.", comment: "Email settings: what sorting does"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let removed, let page = removed.provider.revokePage {
                Section {
                    Link(destination: page) {
                        Label { Text("Revoke the App Password at \(removed.provider.label)", comment: "Email settings: after removing an account") } icon: { Image(systemName: "arrow.up.forward.square") }
                    }
                } footer: {
                    Text("\(removed.name) is out of Redde and your Hermes. The app password still exists at \(removed.provider.label) until you revoke it there.", comment: "Email settings: after removing an account")
                }
            }

            if let problem = center.problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(Text("Email", comment: "Settings › Agent › Email: title"))
        .confirmationDialog(Text("Remove \(removing?.name ?? "")?", comment: "Email settings: confirm removing an account"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible,
                            presenting: removing) { account in
            Button(role: .destructive) { Task { await remove(account) } } label: {
                Text("Remove Account", comment: "Email settings: confirm removing an account")
            }
            Button(role: .cancel) { removing = nil } label: { Text("Cancel") }
        } message: { account in
            Text(Self.removalMessage(account))
        }
        .sheet(isPresented: $adding) { MailAccountSetup(done: { Task { await center.refreshStatus() } }) }
        .task { await center.refreshStatus() }
        .refreshable { await center.refreshStatus() }
    }

    private func accountRow(_ account: MailAccount) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                Text(account.address).font(.caption).foregroundStyle(.secondary)
                if let problem = account.problem {
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: MailProvider(rawValue: account.provider)?.symbol ?? "envelope")
        }
        .badge(Text(Self.state(account)))
    }

    /// "Working" as an account that works: its own key, since "Working" is also the chat list's
    /// busy mark, and that one's translations say busy.
    static var working: String { String(localized: "mail.working", defaultValue: "Working", comment: "Email settings: an account whose login works (not \"busy\")") }

    /// The word at a row's end: Working, or what's wrong in one word.
    static func state(_ account: MailAccount) -> String {
        if account.via == "nous" { return String(localized: "Not usable", comment: "Email settings: an account Redde can't read") }
        return account.usable ? working
                              : String(localized: "Not working", comment: "Email settings: an account that fails")
    }

    static func via(_ account: MailAccount) -> String {
        switch account.via {
        case "gmail_api": String(localized: "Connected through your Hermes's Google sign-in", comment: "Email account: how it's reached")
        case "nous": String(localized: "Your Hermes has Nous's Gmail connector, which Redde's Inbox can't use. Add the account here with an app password instead.", comment: "Email account: Nous's connector")
        default: (MailProvider(rawValue: account.provider)?.label ?? account.provider) + " · IMAP"
        }
    }

    /// What removing takes away, and what it leaves.
    static func removalMessage(_ account: MailAccount) -> String {
        let provider = MailProvider(rawValue: account.provider)
        let name = provider?.label ?? account.provider
        var text = String(localized: "Removes \(account.name) from Redde and your Hermes: its password, cached mail and rules. Your mail itself stays with \(name).",
                          comment: "Email settings: what removing an account does")
        if provider?.revokePage != nil {
            text += " " + String(localized: "You can also revoke its app password at \(name) afterwards.", comment: "Email settings: removing an account")
        }
        return text
    }

    private func remove(_ account: MailAccount) async {
        removing = nil
        removingNow = account.id
        defer { removingNow = nil }
        do {
            try await center.removeAccount(account.id)
            removed = MailProvider(rawValue: account.provider).map { (account.name, $0) }
        } catch {
            center.problem = error.localizedDescription
        }
    }

}

/// One email account's page: how it's reached and whether it works, a test of the login, its
/// Gmail labels, and removing it. Removing goes back to the list, which tells where the app
/// password can be revoked.
struct MailAccountView: View {
    let accountID: String
    let remove: (MailAccount) async -> Void
    @State private var center = MailCenter.shared
    @State private var checking = false
    @State private var result: MailCheck?
    @State private var problem: String?
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let account = center.accounts.first(where: { $0.id == accountID }) {
            form(account)
        } else {
            ContentUnavailableView { Label { Text("Account Removed", comment: "Email account page: gone") } icon: { Image(systemName: "envelope") } }
        }
    }

    private func form(_ account: MailAccount) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: MailProvider(rawValue: account.provider)?.symbol ?? "envelope")
                        .font(.title2).foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).font(.headline)
                        Text(account.address).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text(MailSettingsView.via(account))
            }

            if account.via != "nous" {
                Section {
                    LabeledContent {
                        status(account.usable && result.map(\.ok) != false)
                    } label: {
                        Text("Status", comment: "Email account page: does it work")
                    }
                    if let result, account.via == "imap" {
                        LabeledContent { status(result.imap == "ok") } label: {
                            Text("Receiving", comment: "Email account page: the IMAP login")
                        }
                        if result.smtp != "skipped" {
                            LabeledContent { status(result.smtp == "ok") } label: {
                                Text("Sending", comment: "Email account page: the SMTP login")
                            }
                        }
                    }
                    if let lastSync = account.lastSync {
                        LabeledContent {
                            Text(lastSync, format: .relative(presentation: .named))
                        } label: {
                            Text("Last Checked", comment: "Email account page: when the Hermes last read the mailbox")
                        }
                    }
                    Button { Task { await check() } } label: {
                        HStack {
                            Text("Test Connection", comment: "Email settings: try the login")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    .disabled(checking)
                } header: {
                    Text("Connection", comment: "Email account page: section")
                } footer: {
                    if let text = result?.problem ?? account.problem ?? problem {
                        Text(text).foregroundStyle(.red)
                    }
                }
            }

            if account.canLabel {
                Section {
                    // Gmail: the sorting as labels, and tagging rules (11-03).
                    NavigationLink { MailTaggingView(accountID: account.id) } label: {
                        Label { Text("Gmail Labels and Tagging Rules", comment: "Email settings: an account's labels page") } icon: { Image(systemName: "tag") }
                    }
                }
            }

            if MailCenter.removable(account) {
                Section {
                    Button(role: .destructive) { confirming = true } label: {
                        Text("Remove Account…", comment: "Email settings: take an account out of Redde")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: account.name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(Text("Remove \(account.name)?", comment: "Email settings: confirm removing an account"),
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(role: .destructive) {
                dismiss()
                Task { await remove(account) }
            } label: {
                Text("Remove Account", comment: "Email settings: confirm removing an account")
            }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text(MailSettingsView.removalMessage(account))
        }
    }

    private func status(_ ok: Bool) -> some View {
        Label {
            ok ? Text(verbatim: MailSettingsView.working)
               : Text("Not working", comment: "Email settings: an account that fails")
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
    }

    private func check() async {
        checking = true
        problem = nil
        defer { checking = false }
        do {
            result = try await center.check(accountID)
            await center.refreshStatus()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Adding an account: the provider, the address, an app password, sealed straight into the main
/// profile's .env (Keys Asked For), then a test of the login.
struct MailAccountSetup: View {
    let done: () -> Void
    @State private var center = MailCenter.shared
    @State private var provider: MailProvider?
    @State private var name = ""
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var saving = false
    @State private var step = 0
    @State private var stepsTotal = 0
    @State private var problem: String?
    @State private var result: MailCheck?
    @State private var askedAgent = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Hermes's own Google sign-in is there already: Gmail needs nothing more.
    private var googleConnected: Bool { center.accounts.contains { $0.via == "gmail_api" && $0.usable } }
    private var hasMain: Bool { center.accounts.contains { $0.id == "main" } }

    var body: some View {
        NavigationStack {
            Form {
                if let provider {
                    details(provider)
                } else {
                    Section {
                        ForEach(MailProvider.allCases) { p in
                            Button { pick(p) } label: {
                                Label { Text(p.label).foregroundStyle(.primary) } icon: { Image(systemName: p.symbol) }
                            }
                        }
                    } header: {
                        Text("Your Email", comment: "Email setup: choose the provider")
                    } footer: {
                        Text("Redde works with any account that offers IMAP and an app password: a password made just for Redde, which you can take back at any time without changing your own.", comment: "Email setup: what it needs")
                    }
                }
            }
            .navigationTitle(Text(provider?.label ?? String(localized: "Add Email", comment: "Email setup: title")))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if provider != nil, result?.ok != true {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await save() } } label: { Text("Connect", comment: "Email setup: save and test") }
                            .disabled(!ready || saving)
                    }
                }
            }
        }
    }

    private func pick(_ p: MailProvider) {
        provider = p
        if name.isEmpty { name = hasMain ? String(localized: "Work", comment: "Default name of a second email account") : String(localized: "Home", comment: "Default name of the first email account") }
        smtpPort = p == .icloud || p == .outlook ? "587" : "465"
    }

    private var ready: Bool {
        guard let provider, address.contains("@"), !password.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if provider == .other { return !imapHost.isEmpty && !smtpHost.isEmpty && Int(imapPort) != nil && Int(smtpPort) != nil }
        return true
    }

    @ViewBuilder
    private func details(_ p: MailProvider) -> some View {
        if p == .gmail, googleConnected {
            Section {
                Label { Text("Gmail is connected through your Hermes's Google sign-in. Nothing more to set up.", comment: "Email setup: Gmail already there") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        if !p.appPasswordsWork {
            Section { Label(p.howTo, systemImage: "exclamationmark.triangle").font(.footnote) }
        }
        Section {
            TextField(String(localized: "Name, like Home or Work", comment: "Email setup: the account's name"), text: $name)
            TextField(String(localized: "Email address", comment: "Email setup: the address"), text: $address)
                #if os(iOS)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        } header: {
            Text("Account", comment: "Email setup: section")
        }
        if p == .other {
            Section {
                TextField(String(localized: "IMAP server", comment: "Email setup: incoming server"), text: $imapHost).autocorrectionDisabled()
                TextField(String(localized: "IMAP port", comment: "Email setup"), text: $imapPort)
                TextField(String(localized: "SMTP server", comment: "Email setup: outgoing server"), text: $smtpHost).autocorrectionDisabled()
                TextField(String(localized: "SMTP port", comment: "Email setup"), text: $smtpPort)
                TextField(String(localized: "Sign in as (if not the address)", comment: "Email setup: user name"), text: $user).autocorrectionDisabled()
            } header: {
                Text("Servers", comment: "Email setup: section")
            }
        }
        if p.appPasswordsWork {
            Section {
                Text(p.howTo).font(.footnote)
                if let page = p.appPasswordPage {
                    Button { openURL(page) } label: {
                        Label { Text("Make an App Password", comment: "Email setup: open the provider's page") } icon: { Image(systemName: "arrow.up.right.square") }
                    }
                }
                SecureField(String(localized: "App password", comment: "Email setup: the password field"), text: $password)
                    .autocorrectionDisabled()
            } header: {
                Text("App Password", comment: "Email setup: section")
            } footer: {
                Text("It's sealed on this device and opened only by your Hermes, which keeps it in its .env. It isn't kept in Redde, a chat, a log or a notification.", comment: "Email setup: where the password goes")
            }
        }
        if saving {
            Section {
                ProgressView(value: Double(step), total: Double(max(stepsTotal, 1))) {
                    Text("Sending to your Hermes…", comment: "Email setup: progress")
                }
            }
        }
        if let result {
            Section {
                if result.ok {
                    Label { Text("Connected. Your inbox is sorted on your Hermes in the next few minutes.", comment: "Email setup: it works") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button { done(); dismiss() } label: { Text("Done") }
                } else {
                    Label(result.problem ?? String(localized: "The login didn't work.", comment: "Email setup: it failed"), systemImage: "xmark.octagon").foregroundStyle(.red)
                    Button { Task { await test() } } label: {
                        Text("Test Again", comment: "Email setup: try the login again")
                    }
                }
            }
        }
        if let problem {
            Section {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote)
                if !askedAgent {
                    Button { askAgent(p) } label: { Text("Or Ask My Agent to Set It Up", comment: "Email setup, after a problem: the agent asks for each setting with key cards instead") }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    /// The first account's names are REDDE_MAIL_*; another's carry its key and join REDDE_MAIL_ACCOUNTS.
    private var key: String? { hasMain ? MailSecrets.key(for: name) : nil }

    private var setup: MailSetup? {
        guard let provider else { return nil }
        let address = address.trimmingCharacters(in: .whitespaces)
        return MailSetup(provider: provider, address: address, password: password.trimmingCharacters(in: .whitespaces),
                         name: name.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                         imap: Int(imapPort).map { (imapHost.trimmingCharacters(in: .whitespaces), $0) },
                         smtp: Int(smtpPort).map { (smtpHost.trimmingCharacters(in: .whitespaces), $0) }, key: key,
                         others: center.accounts.filter { $0.id != "main" && $0.via == "imap" }.map { $0.id.uppercased() })
    }

    private func save() async {
        guard let setup else { return }
        saving = true
        problem = nil
        result = nil
        defer { saving = false; password = "" }
        do {
            try await center.setUp(setup) { done, total in step = done; stepsTotal = total }
            await test()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func test() async {
        do {
            result = try await center.check(MailSecrets.accountID(key: key))
            await center.refreshStatus()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Without the plugin's `keys ask`: the main agent asks for each setting with `request_secret`,
    /// so each comes as a key card to paste into.
    private func askAgent(_ p: MailProvider) {
        askedAgent = true
        let names = setup?.values.map(\.name) ?? []
        dismiss()
        center.close(then: { LaunchRouter.shared.requestGoalChat(profile: "default", message: MailCenter.setupAsk(names: names, provider: p)) })
    }
}

/// The rules he made: each in a line, what it did lately, and an Undo for each thing done.
struct MailRulesView: View {
    @State private var center = MailCenter.shared
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                if center.rules.isEmpty {
                    Text("No rules yet. Make one from an email's menu, or here.", comment: "Email rules: none").foregroundStyle(.secondary)
                }
                ForEach(center.rules) { rule in
                    Label { Text(rule.described).font(.subheadline) } icon: { Image(systemName: rule.action.symbol) }
                        .swipeActions {
                            Button(role: .destructive) { Task { await remove(rule) } } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                Button { adding = true } label: {
                    Label { Text("Add Rule", comment: "Email rules: make a new one") } icon: { Image(systemName: "plus.circle") }
                }
            } footer: {
                Text("Rules run on your Hermes by themselves as mail arrives, without your agent, and everything they do is listed below and in Agent Activity. Rules never delete mail.", comment: "Email rules: how they run")
            }
            ForEach(center.accounts.filter(\.usable)) { account in MailSuggestionsSection(account: account) }
            let done = center.log.filter { $0.by == "rule" }
            if !done.isEmpty {
                Section {
                    ForEach(done) { entry in MailLogRow(entry: entry) }
                } header: {
                    Text("Lately", comment: "Email rules: what they did recently")
                }
            }
            if let problem = problem ?? center.problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(Text("Rules", comment: "Email rules page: title"))
        .sheet(isPresented: $adding) { NewMailRule() }
        .task {
            await center.loadRules()
            await center.loadLog()
        }
        .refreshable {
            await center.loadRules()
            await center.loadLog()
        }
    }

    private func remove(_ rule: MailRule) async {
        do { try await center.remove(rule) } catch { problem = error.localizedDescription }
    }
}

/// One thing a rule (or a tap, or the agent) did to the mail, with its Undo.
struct MailLogRow: View {
    let entry: MailLogEntry
    @State private var center = MailCenter.shared
    @State private var undone = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.subheadline)
                Text(entry.at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.undone || undone {
                Text("Undone", comment: "Email log: this was undone").font(.caption).foregroundStyle(.secondary)
            } else if entry.undoable {
                Button { Task { if (try? await center.undo(log: entry)) != nil { undone = true } } } label: {
                    Text("Undo", comment: "Email log: undo what a rule did")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}

/// A rule from scratch: who it's from (or what the subject has), and what to do.
struct NewMailRule: View {
    @State private var center = MailCenter.shared
    @State private var from = ""
    @State private var subject = ""
    @State private var action: MailRule.Action = .archive
    @State private var name = ""
    @State private var pile: MailBucket = .important
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    /// Putting mail in a pile needs plugin 1.31.0.
    private var actions: [MailRule.Action] { MailRule.Action.allCases.filter { $0 != .group || center.status?.hasPiles == true } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "From (a name, an address or a domain)", comment: "Email rule: the sender"), text: $from).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField(String(localized: "Subject has (optional)", comment: "Email rule: words in the subject"), text: $subject)
                } header: {
                    Text("When an Email Is", comment: "Email rule: its condition")
                }
                Section {
                    Picker(selection: $action) {
                        ForEach(actions) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    } label: { Text("Do", comment: "Email rule: what it does") }
                    if action == .group {
                        Picker(selection: $pile) {
                            ForEach(MailBucket.shown) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        } label: { Text("Pile", comment: "Inbox: which pile of email is shown") }
                    }
                    if action.takesName {
                        TextField(action == .label ? String(localized: "Label", comment: "Email rule: label name") : String(localized: "Folder", comment: "Email rule: folder name"), text: $name)
                    }
                }
                if let problem { Section { Text(problem).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(Text("New Rule", comment: "Email: new rule sheet's title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty && subject.trimmingCharacters(in: .whitespaces).isEmpty
                                  || action.takesName && name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        let rule = MailRule(id: "r\(Int(Date.now.timeIntervalSince1970))", from: from.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                            subject: subject.trimmingCharacters(in: .whitespaces).nilIfEmpty, action: action,
                            arg: action.takesName ? name.trimmingCharacters(in: .whitespaces) : action == .group ? pile.rawValue : nil)
        do {
            try await center.add(rule)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
