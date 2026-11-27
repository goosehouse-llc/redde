import SwiftUI

/// Over a chat: the way back from a side chat, or the side chats started from this one.
struct SideChatStrip: View {
    let conversation: Conversation
    @State private var sides = SideChats.shared

    var body: some View {
        let connection = conversation.settings.connectionKey
        if let link = conversation.sideOf ?? sides.link(of: conversation.serverSessionID, connection: connection) {
            Button {
                LaunchRouter.shared.requestSession(link.parent, title: link.title)
            } label: {
                Label {
                    Text("Side chat from “\(link.title)” · Back", comment: "Over a side chat: the chat it came from, tap to go back")
                        .lineLimit(1)
                } icon: { Image(systemName: "arrow.uturn.backward") }
                .chatFont(.caption, weight: .medium)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("side-chat-back")
        } else if case let list = sides.sides(of: conversation.serverSessionID, connection: connection), !list.isEmpty {
            Menu {
                ForEach(list, id: \.session) { side in
                    Button(side.link.about.isEmpty ? String(localized: "Side chat") : side.link.about, systemImage: "bubble.left.and.bubble.right") {
                        LaunchRouter.shared.requestSession(side.session, title: side.link.about)
                    }
                }
            } label: {
                Label {
                    Text("\(list.count) side chats", comment: "Over a chat: how many side chats were started from it; a menu of them")
                } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                .chatFont(.caption, weight: .medium)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            .accessibilityIdentifier("side-chats")
        }
    }
}
