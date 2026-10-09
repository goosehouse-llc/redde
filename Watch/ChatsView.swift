import SwiftUI

/// The server's recent conversations, to carry one on from the wrist, and a way to start a new
/// one. Offered when the watch talks to the Hermes API itself.
struct ChatsView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                store.newChat()
                dismiss()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            switch store.chatsState {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            case let .failed(why):
                Text(why).font(.footnote).foregroundStyle(.secondary)
                Button("Try again", systemImage: "arrow.clockwise") { Task { await store.loadChats() } }
            case .idle:
                if store.chats.isEmpty {
                    Text("No conversations on this server yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(store.chats) { chat in
                Button {
                    store.open(chat)
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title).lineLimit(2)
                            if let when = chat.when() {
                                Text(when).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if chat.id == store.sessionID {
                            Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                .accessibilityLabel("The one you're in")
                        }
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .task { await store.loadChats() }
    }
}

#if DEBUG
/// The complication in each of its sizes, side by side (`-echo.complications`): for looking at it
/// in the simulator, where a face can't be set up from a script.
struct ComplicationGallery: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                AskComplicationView(family: .accessoryCircular).frame(width: 50, height: 50)
                AskComplicationView(family: .accessoryCorner).frame(width: 44, height: 44)
                AskComplicationView(family: .accessoryRectangular).frame(height: 50).padding(.horizontal, 8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                AskComplicationView(family: .accessoryInline).font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
