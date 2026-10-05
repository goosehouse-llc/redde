import Foundation

/// How much of a conversation the transcript lays out at once.
///
/// The transcript is a plain stack, not a lazy one (see `TranscriptView`), so everything in the
/// page is laid out and kept: each screen-height of it holds about a screen of bitmap, and every
/// update while a reply streams walks all of it. A page of sixty long replies came to well over a
/// gigabyte and twice the work per update of a short thread. So the page is sized by how much it
/// holds, not by how many messages: the newest messages that fit `budget`, with earlier ones a
/// tap away.
nonisolated enum TranscriptPage {
    /// Characters of text, roughly ten screens of it.
    static let standardBudget = 30_000
    /// The last couple of exchanges show whatever their length.
    static let minimumMessages = 4
    static let maximumMessages = 60

    static var budget: Int {
        #if DEBUG
        // `-echo.pageBudget <characters>` for measuring; 0 means no limit but the message count.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-echo.pageBudget"), i + 1 < args.count, let override = Int(args[i + 1]) {
            return override > 0 ? override : .max
        }
        #endif
        return standardBudget
    }

    /// What a message costs the page: its text, and something for the row itself and for each
    /// thing in it that takes room without being text. Thinking is folded away and not counted.
    static func weight(of message: Message) -> Int {
        message.text.utf8.count + 250 + message.attachments.count * 1_500 + message.subagents.count * 300 + (message.tools.isEmpty ? 0 : 150)
    }

    /// How many of the newest messages make a page: as many as fit the budget, never fewer than
    /// `minimumMessages` and never more than `maximumMessages`. A page doesn't open on a reply
    /// with its question left above the fold: the question comes along.
    static func count(_ messages: some BidirectionalCollection<Message>, budget: Int = TranscriptPage.budget) -> Int {
        var total = 0, count = 0
        for message in messages.reversed() {
            guard count < maximumMessages else { break }
            total += weight(of: message)
            if count >= minimumMessages, total > budget { break }
            count += 1
        }
        if count > 0, count < messages.count {
            let first = messages.index(messages.endIndex, offsetBy: -count)
            let before = messages[messages.index(before: first)]
            if messages[first].role == .assistant, before.role == .user { count += 1 }
        }
        return count
    }
}

extension TranscriptPage {
    /// Which messages the transcript shows: everything from where the page starts.
    ///
    /// Kept as how many messages come before the page, not as how long the page is. A message
    /// added at the end then leaves every row above it in place. Counted from the end, the page
    /// shrank from the top for the one pass before it was resized: the oldest rows were dropped
    /// and built again on every send and every reply, and lost what they held (an open fold, a
    /// loaded picture, a drawn diagram).
    struct Window: Equatable, Sendable {
        /// Messages before the page; nil until it is first settled.
        private(set) var hidden: Int?
        /// The reader loaded earlier messages, or a search took them there: the page starts where
        /// they put it until they send again or open another conversation.
        private(set) var held = false

        func hiddenCount(in messages: [Message], budget: Int = TranscriptPage.budget) -> Int {
            min(hidden ?? messages.count - TranscriptPage.count(messages, budget: budget), messages.count)
        }

        /// Sizes the page for the conversation as it is now. A page the reader is holding stays
        /// as it is; `release` lets go of what they loaded.
        mutating func settle(_ messages: [Message], release: Bool = false, budget: Int = TranscriptPage.budget) {
            if release { held = false }
            guard !held else { return }
            hidden = messages.count - TranscriptPage.count(messages, budget: budget)
        }

        /// How many messages one more page of what comes before would add.
        func earlierCount(in messages: [Message], budget: Int = TranscriptPage.budget) -> Int {
            let before = hiddenCount(in: messages, budget: budget)
            return before == 0 ? 0 : max(1, TranscriptPage.count(messages.prefix(before), budget: budget))
        }

        mutating func showEarlier(_ messages: [Message], budget: Int = TranscriptPage.budget) {
            hidden = hiddenCount(in: messages, budget: budget) - earlierCount(in: messages, budget: budget)
            held = true
        }

        /// Brings the message at `index` onto the page, with a little before it.
        mutating func reveal(_ index: Int, in messages: [Message], budget: Int = TranscriptPage.budget) {
            guard index < hiddenCount(in: messages, budget: budget) else { return }
            hidden = max(0, index - 2)
            held = true
        }
    }
}
