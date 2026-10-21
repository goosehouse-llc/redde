import XCTest

/// What the UI tests share: the launch arguments nearly all of them start from, finding a piece
/// of text on screen, and the conversation list's rows.
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

extension XCUIElementQuery {
    /// The first match that can be tapped, once there is one. A conversation's title is also the
    /// header of the open conversation, pushed off screen behind the iPhone's list, and a row's
    /// Delete is also a swipe action laid out off screen: the one wanted is the one on screen.
    func hittable(within seconds: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = (0 ..< count).map({ element(boundBy: $0) }).first(where: \.isHittable) { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }
}

extension XCUIApplication {
    /// Deletes a conversation through its row's menu in the list (open already). A swipe to the
    /// left on the iPhone closes the list instead. False when there was no such row.
    @discardableResult
    func deleteConversation(titled title: String) -> Bool {
        let rows = staticTexts.matching(identifier: title)
        guard let row = rows.hittable(within: 10) else { return false }
        let before = rows.count
        row.press(forDuration: 1.0)
        guard let delete = buttons.matching(NSPredicate(format: "label == %@", "Delete")).hittable(within: 5) else { return false }
        delete.tap()
        let deadline = Date().addingTimeInterval(5)
        while rows.count >= before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return rows.count < before
    }
}

extension XCUIApplication {
    /// Opens one of Settings' pages (Appearance, Writing, Voice, Siri, Agent) from its first
    /// screen, which is open already.
    func openSettingsPage(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        for _ in 0 ..< 6 where !(row.exists && row.isHittable) { swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable, "No \(title) in Settings", file: file, line: line)
        row.tap()
        XCTAssertTrue(navigationBars[title].waitForExistence(timeout: 5), "Settings → \(title) didn't open", file: file, line: line)
    }
}
