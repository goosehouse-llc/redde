import XCTest

/// What the UI tests share: the launch arguments nearly all of them start from, and finding a
/// piece of text on screen.
extension XCUIApplication {
    /// A launch that lands on the chat: setup done, no voice mode at launch, no app lock.
    static let straightToChat = ["-setupDone", "YES", "-openToVoiceScreen", "NO", "-listenOnOpen", "NO", "-requireBiometrics", "NO"]
    /// The conversation list on Chats; without it, it reopens on whichever section was used last.
    static let chatsSection = ["-conversations.section", "sessions"]

    /// The first text on screen that contains `fragment`.
    func text(containing fragment: String) -> XCUIElement {
        staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }
}
