// Settings → About → Report a Problem: the diagnostics report, shown in full, to copy into a bug report.
import SwiftUI

struct DiagnosticsView: View {
    @State private var report: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                if let report {
                    Text(verbatim: report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("diagnostics.report")
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Asking your server…", comment: "Report a Problem: while Hermes is asked for its version")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Nothing is sent from here. The report has no messages, keys, passwords or server addresses: your device, Redde's settings that matter, and the last requests that failed. Read it before you share it.",
                     comment: "Report a Problem: under the report")
            }

            Section {
                Button {
                    guard let report else { return }
                    UIPasteboard.general.string = Self.wrapped(report)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy Report", comment: "Report a Problem: a button"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(report == nil)
                if let report, let url = Self.newIssue(report) {
                    Link(destination: url) {
                        Label(String(localized: "Report on GitHub", comment: "Report a Problem: opens a new GitHub issue with the report filled in"),
                              systemImage: "exclamationmark.bubble")
                    }
                }
            }

            Section {
                Button(String(localized: "Forget Failed Requests", comment: "Report a Problem: clears the kept list of failed requests"), role: .destructive) {
                    FailureLog.shared.clear()
                    Task { await load() }
                }
            }
        }
        .navigationTitle(String(localized: "Report a Problem", comment: "Settings → About: a page with a diagnostics report for bug reports"))
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let server = await DiagnosticsReport.askServer()
        report = DiagnosticsReport.text(server: server)
    }

    /// As pasted into an issue: a fenced block, so GitHub keeps its lines.
    static func wrapped(_ report: String) -> String { "```\n\(report)\n```" }

    /// A new issue on Redde's repository from its bug form, the report in its Diagnostics field.
    static func newIssue(_ report: String) -> URL? {
        var comps = URLComponents(string: "https://github.com/goosehouse-llc/redde/issues/new")
        comps?.queryItems = [URLQueryItem(name: "template", value: "bug_report.yml"),
                             URLQueryItem(name: "diagnostics", value: report)]
        return comps?.url
    }
}
