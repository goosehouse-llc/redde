import SwiftUI

/// A bot's earlier chats, from its menu (asked 2026-10-29): the ones put aside with Start Fresh,
/// newest first, with their messages still on the server. Tap one to read it (or carry on in it);
/// hold or swipe it to make it the bot's chat again, the one it has now put aside in its place.
struct EarlierChatsView: View {
    let bot: HermesBot
    let mainName: String
    /// One tapped: opened, the sheet and the chat list closed.
    let read: (HermesSessionsAPI.SessionSummary) -> Void
    /// One made the bot's chat again.
    let bringBack: (HermesSessionsAPI.SessionSummary) -> Void
    @Environment(Conversation.self) private var conversation
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [HermesSessionsAPI.SessionSummary]?
    @State private var problem: String?

    private var name: String { bot.label(mainName: mainName) }

    var body: some View {
        NavigationStack {
            List {
                if let chats {
                    if chats.isEmpty {
                        Text("Chats you put aside with Start Fresh show here, with their messages.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(chats) { chat in
                        Button { read(chat) } label: { row(chat) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Make It the Chat", systemImage: "arrow.uturn.backward") { bringBack(chat) }.tint(.accentColor)
                            }
                            .contextMenu {
                                Button(String(localized: "action.read", defaultValue: "Read", comment: "Button and swipe stamp: opens a briefing (or an earlier chat) to read it. A verb, not 'has been read'."), systemImage: "text.bubble") { read(chat) }
                                Button("Make It \(name)'s Chat", systemImage: "arrow.uturn.backward") { bringBack(chat) }
                            }
                    }
                } else if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if bot.viaAPI {
                    Section {} footer: {
                        Text("Over the Hermes API, only the chats put aside from this iPhone show here.")
                    }
                }
            }
            .navigationTitle("Earlier Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func row(_ chat: HermesSessionsAPI.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(started(chat)).font(.body.weight(.medium))
                Spacer(minLength: 6)
                if let count = chat.message_count, count > 0 {
                    Text("\(count) messages").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let last = chat.lastActiveDate {
                Text("Last message \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            if let preview = chat.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                Text(PlainText.display(preview)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    /// When it began: "Oct 26, 9:01 PM".
    private func started(_ chat: HermesSessionsAPI.SessionSummary) -> String {
        guard let at = chat.started_at else { return String(localized: "An earlier chat") }
        return Date(timeIntervalSince1970: at).formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func load() async {
        do {
            chats = try await conversation.earlierChats(of: bot, mainName: mainName)
            problem = nil
        } catch {
            if chats == nil { problem = String(localized: "Couldn't read \(name)'s earlier chats: \(error.localizedDescription)") }
        }
    }
}
