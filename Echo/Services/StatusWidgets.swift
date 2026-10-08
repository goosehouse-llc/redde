import Foundation
import WidgetKit

/// The app's hand in the two status widgets, "Needs you" and Context. What they show lives in
/// the App Group (`NeedsYou`, `ContextReading`); this writes it and has the widget drawn again,
/// only when something changed, since a widget's reloads are counted.
enum StatusWidgets {
    /// The agent stopped for something in a conversation.
    static func waiting(_ request: WaitingRequest, in defaults: UserDefaults? = NeedsYou.shared) {
        if NeedsYou.note(request, in: defaults) { reload(NeedsYou.widgetKind) }
    }

    /// A conversation waits on nothing any more: answered, expired, or its turn stopped.
    static func settled(_ id: String, in defaults: UserDefaults? = NeedsYou.shared) {
        if NeedsYou.settle(id, in: defaults) { reload(NeedsYou.widgetKind) }
    }

    /// A note from a paired Hermes that the app opened itself (the notification extension does
    /// the same for the ones it opens).
    static func heard(_ note: PushNote, in defaults: UserDefaults? = NeedsYou.shared) {
        if NeedsYou.take(note, in: defaults) { reload(NeedsYou.widgetKind) }
    }

    /// How full the context is after a reply, or in a conversation just opened.
    static func reading(_ reading: ContextReading, in defaults: UserDefaults? = NeedsYou.shared) {
        if reading.save(in: defaults) { reload(ContextReading.widgetKind) }
    }

    /// The app lock was switched: the widgets show or leave out their words from now on, and
    /// a title the Context widget was given before the lock went on is taken back.
    static func lockChanged(_ locked: Bool) {
        guard NeedsYou.hidesWords != locked else { return }
        NeedsYou.hidesWords = locked
        if locked, var reading = ContextReading.load(), reading.title != nil {
            reading.title = nil
            reading.save()
        }
        reload(NeedsYou.widgetKind)
        reload(ContextReading.widgetKind)
    }

    private static func reload(_ kind: String) { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
}
