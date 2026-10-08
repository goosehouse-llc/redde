import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The draft on a page of its own, for a message too long for the field: the whole screen to
/// write in, Return for a new line whatever the setting, and Send or Done at the top.
struct ComposerEditor: View {
    @Binding var draft: String
    let sendLabel: String
    let send: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .accessibilityLabel("Message")
                .navigationTitle("Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(sendLabel) {
                            dismiss()
                            send()
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .onAppear { focused = true }
    }
}

/// Lets a picture on the clipboard be pasted into the composer, from the field's own Paste (or
/// ⌘V), where a text field would only take text.
///
/// The field is SwiftUI's. Its text view turns Paste down when the clipboard holds no text, and
/// nothing public changes its mind: a paste configuration is ignored, and the responders above
/// it (the window, the application) are SwiftUI's own too. So the one text view that is the
/// composer's is given a subclass of its class, made at run time, that overrides two methods and
/// passes everything else through, the way key-value observing does. While the composer has
/// the focus and the clipboard holds a picture and no text, it says yes to Paste and takes it:
/// the picture becomes an attachment and nothing goes into the text. In every other case the
/// original answers. If the field is ever backed by something that isn't a text view, nothing
/// is changed, and pasting is what it was.
final class ComposerPaste {
    static let shared = ComposerPaste()

    /// Where pasted pictures go, with anything that couldn't be read said the composer's way.
    /// Set while the composer's field has the focus, nil otherwise.
    var deliver: (([Attachment], [String]) -> Void)?

    /// Paste means a picture just now: the composer is listening, and the clipboard has one and
    /// no text. (Asking whether it has either doesn't read it, and brings up no "Allow Paste".)
    var takesPictures: Bool { deliver != nil && UIPasteboard.general.hasImages && !UIPasteboard.general.hasStrings }

    func pastePictures() {
        guard let deliver else { return }
        let providers = UIPasteboard.general.itemProviders.filter {
            Self.isPicture(types: $0.registeredContentTypes, readsAsText: $0.canLoadObject(ofClass: NSString.self))
        }
        guard !providers.isEmpty else { return }
        Task {
            let loaded = await DroppedItems.load(providers)
            deliver(loaded.attachments, loaded.problems)
        }
    }

    /// Whether a clipboard item is a picture: it has an image and isn't something to read as
    /// text (a link copied off a web page can carry its preview picture along).
    nonisolated static func isPicture(types: [UTType], readsAsText: Bool) -> Bool {
        types.contains { $0.conforms(to: .image) } && !readsAsText
    }

    /// The composer's field has just taken the focus: teach the text view behind it.
    func teachFocusedField() {
        guard deliver != nil, let field = UIResponder.currentFirstResponder, field is UITextView || field is UITextField else { return }
        PicturePasting.teach(field)
    }
}

/// The run-time subclass `ComposerPaste` describes.
nonisolated enum PicturePasting {
    private static let prefix = "ReddePicturePasting_"

    static func teach(_ field: UIResponder) {
        guard let original: AnyClass = object_getClass(field) else { return }
        let originalName = NSStringFromClass(original)
        guard !originalName.hasPrefix(prefix) else { return }   // taught already
        guard let taught = NSClassFromString(prefix + originalName) ?? make(from: original, named: prefix + originalName) else { return }
        object_setClass(field, taught)
    }

    private static func make(from original: AnyClass, named name: String) -> AnyClass? {
        let can = #selector(UIResponder.canPerformAction(_:withSender:))
        let paste = #selector(UIResponderStandardEditActions.paste(_:))
        guard let canMethod = class_getInstanceMethod(original, can), let pasteMethod = class_getInstanceMethod(original, paste),
              let made = objc_allocateClassPair(original, name, 0) else { return nil }

        typealias Can = @convention(c) (AnyObject, Selector, Selector, AnyObject?) -> Bool
        let originalCan = unsafeBitCast(method_getImplementation(canMethod), to: Can.self)
        let newCan: @convention(block) (AnyObject, Selector, AnyObject?) -> Bool = { field, action, sender in
            if action == paste, MainActor.assumeIsolated({ ComposerPaste.shared.takesPictures }) { return true }
            return originalCan(field, can, action, sender)
        }
        class_addMethod(made, can, imp_implementationWithBlock(newCan), method_getTypeEncoding(canMethod))

        typealias Paste = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let originalPaste = unsafeBitCast(method_getImplementation(pasteMethod), to: Paste.self)
        let newPaste: @convention(block) (AnyObject, AnyObject?) -> Void = { field, sender in
            if MainActor.assumeIsolated({ ComposerPaste.shared.takesPictures }) {
                MainActor.assumeIsolated { ComposerPaste.shared.pastePictures() }
            } else {
                originalPaste(field, paste, sender)
            }
        }
        class_addMethod(made, paste, imp_implementationWithBlock(newPaste), method_getTypeEncoding(pasteMethod))

        // Anyone who asks the view what it is hears its own class, as with key-value observing.
        let classSelector = NSSelectorFromString("class")
        let newClass: @convention(block) (AnyObject) -> AnyClass = { _ in original }
        if let classMethod = class_getInstanceMethod(original, classSelector) {
            class_addMethod(made, classSelector, imp_implementationWithBlock(newClass), method_getTypeEncoding(classMethod))
        }
        objc_registerClassPair(made)
        return made
    }
}

extension UIResponder {
    private static weak var found: UIResponder?

    /// The first responder, found by sending an action nobody is named for: UIKit hands it to
    /// the first responder, which notes itself.
    static var currentFirstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(noteAsFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func noteAsFirstResponder(_ sender: Any?) { UIResponder.found = self }
}

/// A ring that fills as the conversation fills the model's context window, with the share
/// beside it; tapped, it says how many tokens that is.
struct ContextRing: View {
    let used: Int
    let window: Int
    @State private var showDetail = false
    @Environment(\.theme) private var theme

    private var share: Double { window > 0 ? min(1, Double(used) / Double(window)) : 0 }
    /// Amber from three quarters, red from nine tenths: the point where a new conversation helps.
    private var tint: Color { share >= 0.9 ? .red : share >= 0.75 ? .orange : theme.accent }

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    Circle().trim(from: 0, to: share).stroke(tint, style: .init(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                Text(share, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4).padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context")
        .accessibilityValue(Self.sentence(used: used, window: window))
        .accessibilityHint("Shows how much of the model's context this conversation uses")
        .popover(isPresented: $showDetail) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Context").font(.headline)
                Text(Self.sentence(used: used, window: window)).font(.subheadline)
                ProgressView(value: share).tint(tint)
                Text("Everything said in this conversation is read again with each message. When it fills up the oldest part is summarised or dropped; a new conversation starts empty.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// "54,210 of 128,000 tokens (42%)".
    nonisolated static func sentence(used: Int, window: Int) -> String {
        let share = window > 0 ? min(1, Double(used) / Double(window)) : 0
        return "\(used.formatted()) of \(window.formatted()) tokens (\(share.formatted(.percent.precision(.fractionLength(0)))))"
    }
}
