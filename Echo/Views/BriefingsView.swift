import SwiftUI

/// The briefings on this phone (`AgentBriefing`), for the chat list: read again when Redde comes to
/// the front and when one arrives with it open; opened from a briefing's notification.
@MainActor
@Observable
final class BriefingsInbox {
    static let shared = BriefingsInbox()
    private(set) var briefings: [AgentBriefing] = []
    /// The one open over the chat list, or all of them (`showingAll`).
    var open: AgentBriefing?
    var showingAll = false

    init() {
        #if DEBUG
        // `-echo.demoBriefings`: a wrap-up and a heads-up, for screenshots.
        if DevHooks.has("-echo.demoBriefings") {
            briefings = [
                AgentBriefing(id: "demo/1", title: "Heads-up: Dentist", agent: "Sol",
                              text: "At Dr. Lee's on Main St in 30 minutes. Bring your insurance card; parking is behind the building.",
                              at: .now.addingTimeInterval(-300), failed: false),
                AgentBriefing(id: "demo/0", title: "Evening wrap-up", agent: "Sol",
                              text: "**Done:** the vet booked for Thursday, the PR merged.\n\n**Waiting on you:** one approval from Coder.\n\n**Tomorrow:** call the plumber; it comes back as an idea at 9.",
                              at: .now.addingTimeInterval(-3600 * 14), failed: false)]
            return
        }
        #endif
        briefings = AgentBriefing.all()
    }

    var unread: [AgentBriefing] { briefings.filter { !$0.read } }

    func reload() {
        #if DEBUG
        if DevHooks.has("-echo.demoBriefings") { return }
        #endif
        let now = AgentBriefing.all()
        if now != briefings { briefings = now }
    }

    func show(_ briefing: AgentBriefing) {
        AgentBriefing.markRead(briefing.id)
        reload()
        open = briefings.first { $0.id == briefing.id } ?? briefing
    }

    /// A briefing's notification, tapped: the newest one, opened.
    func showNewest() {
        reload()
        if let newest = briefings.first { show(newest) } else { showingAll = true }
    }

    func markRead(_ briefing: AgentBriefing) {
        AgentBriefing.markRead(briefing.id)
        reload()
    }

    func remove(_ briefing: AgentBriefing) {
        AgentBriefing.remove(briefing.id)
        reload()
    }
}

extension AgentBriefing {
    var symbol: String {
        if isHeadsUp { return "bell.badge" }
        if title == EveningWrapUp.title { return "moon.stars" }
        return "doc.text"
    }
}

/// "Briefings", at the top of the chat list under the ideas: the ones not read yet, a few lines
/// each; a tap opens the whole of one. Read, they leave the list and stay in All Briefings.
struct BriefingsSection: View {
    @State private var inbox = BriefingsInbox.shared
    private static let shown = 2

    var body: some View {
        if !inbox.unread.isEmpty {
            Section {
                ForEach(inbox.unread.prefix(Self.shown)) { briefing in
                    Button { inbox.show(briefing) } label: { BriefingRow(briefing: briefing, lines: 3) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Done", systemImage: "checkmark") { inbox.markRead(briefing) }.tint(.blue)
                        }
                }
                if inbox.unread.count > Self.shown || inbox.briefings.count > inbox.unread.count {
                    Button("All Briefings") { inbox.showingAll = true }.font(.subheadline)
                }
            } header: {
                Text("Briefings")
            }
        }
    }
}

struct BriefingRow: View {
    let briefing: AgentBriefing
    var lines = 3

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: briefing.symbol)
                .font(.title3)
                .foregroundStyle(briefing.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(briefing.heading).font(.body.weight(briefing.read ? .regular : .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(briefing.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(PlainText.display(briefing.text)).font(.subheadline).foregroundStyle(.secondary).lineLimit(lines)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// One briefing, whole.
struct BriefingSheet: View {
    let briefing: AgentBriefing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        let when = briefing.at.formatted(.dateTime.weekday().hour().minute())
                        Text(briefing.agent.isEmpty ? when : "\(briefing.agent) · \(when)")
                    } icon: {
                        Image(systemName: briefing.symbol)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    MarkdownView(text: briefing.text, selectable: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(briefing.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = briefing.text }
                }
            }
        }
    }
}

/// All the briefings on this phone, the last week's: in a sheet over the chat list, or in Settings.
struct BriefingsListView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BriefingsList()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct BriefingsList: View {
    @State private var inbox = BriefingsInbox.shared
    @State private var open: AgentBriefing?

    var body: some View {
            List {
                if inbox.briefings.isEmpty {
                    Text("Your agent's briefings come here: the Evening Wrap-up, heads-ups before events, and any daily brief you ask it for. Set them up in Settings, Agent.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(inbox.briefings) { briefing in
                    Button { inbox.markRead(briefing); open = briefing } label: { BriefingRow(briefing: briefing, lines: 2) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { inbox.remove(briefing) } }
                }
            }
            .navigationTitle("Briefings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $open) { BriefingSheet(briefing: $0) }
            .onAppear { inbox.reload() }
    }
}

/// The briefing sheets over the chat list.
struct BriefingSheets: ViewModifier {
    @State private var inbox = BriefingsInbox.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { inbox.showingAll ? nil : inbox.open }, set: { inbox.open = $0 })) { BriefingSheet(briefing: $0) }
            .sheet(isPresented: $inbox.showingAll) { BriefingsListView() }
    }
}
