import XCTest

/// Searching inside messages, with the real app and a real Hermes: a conversation whose made-up
/// word is in neither its title nor its first message turns up under "In messages" when the word
/// is typed in the search field, and opening it opens Find on that word, at the match.
///
/// Needs the lab (`scripts/hermes-lab/lab.sh up <tag> approval`: the Hermes API on 18642, the
/// Dashboard on 19119 with lab / labpass-labpass, which a simulator shares with the Mac). Skips
/// without it.
@MainActor
final class MessageSearchUITests: XCTestCase {
    private let dashboard = "http://127.0.0.1:19119"
    private let api = "http://127.0.0.1:18642"

    private func keep(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One request to the lab, synchronously: the test sets the stage before the app opens.
    private func call(_ method: String, _ url: String, _ body: [String: String]? = nil, key: String? = nil) -> Data? {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) { answer = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 70)
        return answer
    }

    func testAWordSaidLaterInAConversationIsFoundAndOpensFind() throws {
        continueAfterFailure = false
        try XCTSkipUnless(call("GET", dashboard + "/api/status") != nil, "No lab on 127.0.0.1:19119 (scripts/hermes-lab/lab.sh up <tag> approval)")

        // A conversation over the Hermes API: a title and a first message without the word,
        // the word in the second.
        let key = "labkey-labkey-labkey"
        let word = "zeph" + String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(6))
        let title = "Lab trip notes \(UUID().uuidString.prefix(4))"
        let created = try XCTUnwrap(call("POST", api + "/api/sessions", ["title": title], key: key), "the lab's Hermes API refused a session")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: created) as? [String: Any])
        let id = try XCTUnwrap((object["session"] as? [String: Any])?["id"] as? String)
        XCTAssertNotNil(call("POST", api + "/api/sessions/\(id)/chat/stream", ["input": "Plan a short trip for me."], key: key))
        XCTAssertNotNil(call("POST", api + "/api/sessions/\(id)/chat/stream", ["input": "Also remember \(word) for later."], key: key))

        // Redde on the Dashboard connection, signed in, on the conversation list.
        let app = XCUIApplication()
        app.launchArguments = XCUIApplication.straightToChat
            + ["-echo.screen", "sessions", "-transport", "hermesServe", "-serveURL", dashboard, "-serveUsername", "lab"]
        app.launchEnvironment["ECHO_TEST_SERVE_PASSWORD"] = "labpass-labpass"
        app.launch()

        let field = app.searchFields["Search conversations"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the conversation list didn't open")
        field.tap()
        field.typeText(word)

        // Not in the title or the first message, so only the search inside messages finds it.
        let hit = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 20), "no \"In messages\" result for \(word)")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "In messages")).firstMatch.exists
                      || app.staticTexts["IN MESSAGES"].exists, "the result isn't under In messages")
        XCTAssertTrue(hit.label.contains(word), "the result's snippet doesn't show the word: \(hit.label)")
        keep(app.screenshot(), as: "search-in-messages")

        // Opened: Find is open on the word, with its match.
        hit.tap()
        let find = app.textFields["Find in conversation"]
        XCTAssertTrue(find.waitForExistence(timeout: 20), "Find didn't open")
        XCTAssertEqual(find.value as? String, word)
        XCTAssertTrue(app.staticTexts["Match 1 of 1"].waitForExistence(timeout: 10), "Find doesn't show the one match")
        keep(app.screenshot(), as: "search-opened-at-match")
    }
}
