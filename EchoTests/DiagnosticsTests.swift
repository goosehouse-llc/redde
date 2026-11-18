import Foundation
import Testing
@testable import Echo

@MainActor
struct DiagnosticsTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "diagnostics-\(UUID().uuidString)")! }

    @Test func aFailureIsKeptWithItsRouteStatusAndFirstWords() {
        let defaults = suite()
        let log = FailureLog(defaults: defaults)
        log.record(via: "dashboard rest", what: "DELETE api/sessions/abc?profile=sol&q=my+secret+search",
                   error: TransportError.http(status: 409, body: "cannot delete an active session\nline two"))
        let entry = try! #require(log.recent.first)
        #expect(entry.what == "DELETE api/sessions/abc", "no query: it can carry a search or a file name")
        #expect(entry.status == 409)
        #expect(entry.error == "HTTP 409 cannot delete an active session line two", "one line")
        #expect(FailureLog(defaults: defaults).recent == [entry], "kept across a relaunch")
    }

    @Test func aCancelledCallIsNothingToReport() {
        let log = FailureLog(defaults: suite())
        log.record(via: "dashboard", what: "session.create", error: CancellationError())
        log.record(via: "api", what: "GET v1/runs", error: URLError(.cancelled))
        #expect(log.recent.isEmpty)
    }

    @Test func onlyTheLastSoManyAreKept() {
        let log = FailureLog(defaults: suite())
        for n in 0 ..< FailureLog.kept + 5 { log.record(via: "api", what: "GET v1/\(n)", error: TransportError.malformed("x")) }
        #expect(log.recent.count == FailureLog.kept)
        #expect(log.recent.last?.what == "GET v1/\(FailureLog.kept + 4)")
        log.clear()
        #expect(log.recent.isEmpty)
    }

    @Test func theSameFailureAgainIsCountedNotRepeated() {
        let log = FailureLog(defaults: suite())
        for _ in 0 ..< 12 { log.record(via: "dashboard rest", what: "GET api/sessions/x/messages", error: URLError(.cannotConnectToHost)) }
        log.record(via: "api", what: "GET v1/models", error: TransportError.http(status: 401, body: "bad key"))
        #expect(log.recent.count == 2)
        #expect(log.recent.first?.times == 12)
        let report = DiagnosticsReport.text(settings: Settings(defaults: suite()), server: .init(), failures: log.recent)
        #expect(report.contains("(×12)"))
    }

    @Test func aRouteHasNoHostAndLongIdsAreCut() {
        #expect(FailureLog.route("https://hermes.my-tailnet.ts.net:9119/api/status?profile=x") == "/api/status")
        #expect(FailureLog.route("GET api/sessions/20261118_095012_a1b2c3d4e5f6a7b8c9d0/messages")
                == "GET api/sessions/20261118…/messages")
        #expect(FailureLog.words(TransportError.malformed(String(repeating: "a", count: 300))).count == 161)
    }

    @Test func theReportSaysWhatMattersAndNoAddressOrKey() {
        let settings = Settings(defaults: suite())
        settings.transport = .hermesServe
        settings.serveURL = "https://hermes.my-tailnet.ts.net:9119"
        let failures = [FailureLog.Entry(at: .now.addingTimeInterval(-300), via: "dashboard", what: "session.delete", status: nil,
                                         error: "cannot delete an active session")]
        let report = DiagnosticsReport.text(settings: settings, server: .init(hermes: "0.23.2", plugin: "1.33.0"), failures: failures)
        #expect(report.hasPrefix("Redde "))
        #expect(report.contains("Connection hermesServe"))
        #expect(report.contains(", https"))
        #expect(report.contains("Hermes 0.23.2, plugin 1.33.0"))
        #expect(report.contains("- 5 min ago · dashboard · session.delete · cannot delete an active session"))
        #expect(!report.contains("tailnet") && !report.contains("9119"), "no server address")
    }

    @Test func noFailuresSaysSo() {
        let settings = Settings(defaults: suite())
        settings.transport = .acp
        let report = DiagnosticsReport.text(settings: settings, server: .init(), failures: [])
        #expect(report.contains("Connection acp, agent"))
        #expect(!report.contains("Hermes "), "no Hermes line for an agent")
        #expect(report.hasSuffix("No failed requests kept."))
    }

    @Test func aNewIssueCarriesTheReportInItsField() throws {
        let url = try #require(DiagnosticsView.newIssue("Redde 2.6 (295)\nConnection api"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "template" }?.value == "bug_report.yml")
        #expect(items.first { $0.name == "diagnostics" }?.value == "Redde 2.6 (295)\nConnection api")
    }
}
