import Foundation
import SwiftUI
#if canImport(UIKit)
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#else
import AppKit
#endif

/// Writes a conversation as a Markdown file for sharing. Reasoning is kept in a collapsed
/// details block so it doesn't dominate; tool calls become a one-line note.
nonisolated enum TranscriptExporter {
    static func markdown(title: String, messages: [Message], assistantName: String = "Redde") -> String {
        var out = "# \(title.isEmpty ? String(localized: "Conversation", comment: "Title of an exported conversation that has none") : title)\n\n"
        let stamp = messages.first?.createdAt ?? .now
        out += "_" + String(localized: "Exported from Redde · \(stamp.formatted(date: .abbreviated, time: .shortened))") + "_\n\n"
        for m in messages {
            switch m.role {
            case .user:
                out += "## " + (m.isSteer ? String(localized: "You (steer)", comment: "Exported conversation: a message added to a reply under way")
                                          : String(localized: "You", comment: "Exported conversation: who wrote a message")) + "\n\n"
                if !m.text.isEmpty { out += m.text + "\n\n" }
                if !m.attachments.isEmpty {
                    out += m.attachments.map { "- 📎 \($0.filename)" }.joined(separator: "\n") + "\n\n"
                }
            case .assistant:
                out += "## \(assistantName)\n\n"
                if !m.reasoning.isEmpty {
                    out += "<details><summary>" + String(localized: "Thinking", comment: "Exported conversation: the agent's reasoning") + "</summary>\n\n" + m.reasoning.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n</details>\n\n"
                }
                if !m.tools.isEmpty {
                    let tools = m.tools.map { $0.status == .failed ? String(localized: "\($0.name) (failed)", comment: "Exported conversation: a tool call that failed") : $0.name }
                    out += "_" + String(localized: "Tools: \(tools.joined(separator: ", "))", comment: "Exported conversation") + "_\n\n"
                }
                if !m.subagents.isEmpty {
                    for s in m.subagents {
                        out += "- **" + String(localized: "Subagent:", comment: "Exported conversation: a task handed to another agent") + "** \(s.goal)" + (s.summary.map { " — \($0)" } ?? "") + "\n"
                    }
                    out += "\n"
                }
                if !m.text.isEmpty { out += m.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
                if let e = m.error, !e.isEmpty { out += "> ⚠️ \(e)\n\n" }
            }
        }
        return out
    }

    /// Writes the Markdown to a temp file named after the title; returns its URL.
    static func file(title: String, messages: [Message], assistantName: String = "Redde") throws -> URL {
        let safe = title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").prefix(48)
        let name = (safe.isEmpty ? "conversation" : String(safe)) + ".md"
        let url = FileManager.default.temporaryDirectory.appending(path: "export", directoryHint: .isDirectory).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown(title: title, messages: messages, assistantName: assistantName).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `file` off the calling actor: a long transcript renders and writes on a background thread.
    static func export(title: String, messages: [Message], assistantName: String = "Redde") async throws -> URL {
        try await Task.detached(priority: .userInitiated) { try file(title: title, messages: messages, assistantName: assistantName) }.value
    }
}

#if canImport(UIKit)
/// UIKit share sheet, for exporting from places where a ShareLink can't be built ahead of time.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
/// The Mac's: the file a sheet away from sharing or showing in Finder.
struct ShareSheet: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss
    private var urls: [URL] { items.compactMap { $0 as? URL } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(urls, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "doc.text")
            }
            HStack {
                if let url = urls.first {
                    ShareLink(item: url)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
#endif

/// Identifiable wrapper so a URL can drive `.sheet(item:)`.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
