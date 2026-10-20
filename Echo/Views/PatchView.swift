import SwiftUI

/// One file of a unified diff: its path, what it adds and takes away, and its lines.
nonisolated struct PatchFile: Identifiable, Equatable, Sendable {
    nonisolated struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case context, added, removed, hunk }
        var kind: Kind
        var text: String
    }

    var id: Int
    var path: String
    var added: Int
    var removed: Int
    var lines: [Line]
}

/// Reading a unified diff (`git diff`'s, or Python's difflib's) into files.
nonisolated enum Patch {
    static func files(_ text: String) -> [PatchFile] {
        var files: [PatchFile] = []
        var oldPath: String?
        func start(_ path: String) {
            files.append(PatchFile(id: files.count, path: path, added: 0, removed: 0, lines: []))
        }
        func clean(_ raw: Substring) -> String {
            var path = String(raw).trimmingCharacters(in: .whitespaces)
            if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }   // difflib's dates
            if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
            return path
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                // The file's path is the new side's; headers below may still name it again.
                let parts = line.split(separator: " ")
                start(parts.count >= 4 ? clean(parts[3]) : "")
                oldPath = nil
            } else if line.hasPrefix("--- ") {
                oldPath = clean(line.dropFirst(4))
            } else if line.hasPrefix("+++ ") {
                let new = clean(line.dropFirst(4))
                let path = new == "/dev/null" ? (oldPath ?? new) : new
                if let last = files.indices.last, files[last].lines.isEmpty {
                    files[last].path = path
                } else {
                    start(path)
                }
            } else if let last = files.indices.last {
                if line.hasPrefix("@@") {
                    files[last].lines.append(.init(kind: .hunk, text: String(line)))
                } else if line.hasPrefix("+") {
                    files[last].added += 1
                    files[last].lines.append(.init(kind: .added, text: String(line)))
                } else if line.hasPrefix("-") {
                    files[last].removed += 1
                    files[last].lines.append(.init(kind: .removed, text: String(line)))
                } else if line.hasPrefix(" ") {
                    files[last].lines.append(.init(kind: .context, text: String(line)))
                }
                // (index, mode and "\ No newline" lines say nothing to a reader.)
            }
        }
        return files.filter { !$0.lines.isEmpty || !$0.path.isEmpty }
    }

    /// "2 files · +12 −3".
    static func summary(_ files: [PatchFile]) -> String {
        let added = files.reduce(0) { $0 + $1.added }, removed = files.reduce(0) { $0 + $1.removed }
        return "\(files.count) file\(files.count == 1 ? "" : "s") · +\(added) −\(removed)"
    }
}

/// A change to read: each file with what it adds and takes away, its lines in a monospaced column,
/// added ones green and removed ones red; notes left with it (Claude's steps that need a key) below.
struct PatchView: View {
    let title: String
    let patch: String
    var notes: String?
    var notesTitle = "Notes"
    @Environment(\.dismiss) private var dismiss

    /// A file this long shows its first lines, and says how many more there are.
    private static let lineCap = 1500

    var body: some View {
        let files = Patch.files(patch)
        NavigationStack {
            List {
                if files.isEmpty {
                    Text("The change has no lines to show.").foregroundStyle(.secondary)
                }
                ForEach(files) { file in
                    Section {
                        PatchFileLines(file: file, cap: Self.lineCap)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    } header: {
                        HStack {
                            Text(file.path).font(.footnote.monospaced()).textCase(nil).lineLimit(2)
                            Spacer()
                            Text("+\(file.added)").foregroundStyle(.green)
                            Text("−\(file.removed)").foregroundStyle(.red)
                        }
                        .font(.footnote.monospacedDigit())
                    }
                }
                if let notes, !notes.isEmpty {
                    Section(notesTitle) { MarkdownView(text: notes) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

}

/// A file's lines, each wrapping down the screen (a long line reads on, rather than scrolling
/// sideways), its colour across the whole row.
private struct PatchFileLines: View {
    let file: PatchFile
    let cap: Int

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(file.lines.prefix(cap).enumerated()), id: \.offset) { _, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.kind == .hunk ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.colour(line.kind))
            }
            if file.lines.count > cap {
                Text("… \(file.lines.count - cap) more lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .textSelection(.enabled)
    }

    private static func colour(_ kind: PatchFile.Line.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.16)
        case .removed: .red.opacity(0.16)
        case .hunk: .secondary.opacity(0.08)
        case .context: .clear
        }
    }
}

/// The change a kanban card carries (`KanbanClient.change(of:)`), fetched when it opens: from an
/// approval that names the card.
struct CardChangeSheet: View {
    let cardID: String
    @State private var change: KanbanClient.CardChange?
    @State private var problem: String?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let change {
            PatchView(title: change.task.title.nilIfEmpty ?? cardID, patch: change.patch, notes: change.notes, notesTitle: "Steps left with it")
        } else {
            NavigationStack {
                Group {
                    if let problem {
                        Text(problem).foregroundStyle(.secondary).padding()
                    } else if loaded {
                        Text("Card \(cardID) has no change attached.").foregroundStyle(.secondary).padding()
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Changes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .task {
                do { change = try await KanbanClient.change(of: cardID) } catch { problem = "Couldn't read card \(cardID): \(error.localizedDescription)" }
                loaded = true
            }
        }
    }
}

#if DEBUG
extension PatchView {
    /// `-echo.screen patch`: a change of the claude bot's, for screenshots.
    static let demo = """
        diff --git a/hello.py b/hello.py
        index 3b18e51..a2b3c4d 100644
        --- a/hello.py
        +++ b/hello.py
        @@ -1,4 +1,6 @@
         import os
        -print("hello")
        +
        +def greet(name: str) -> str:
        +    return f"hello, {name}"
         
        -print(os.environ.get("USER"))
        +print(greet(os.environ.get("USER", "there")))
        +LOG.info("greeted %s from %s at %s with the settings in %s", user, host, when, os.path.expanduser("~/.config/hello/settings.toml"))
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -3,3 +3,4 @@
         ## Running it
         
         python3 hello.py
        +It greets whoever runs it.
        """
    static let demoNotes = "1. Restart the demo service with its key from `.env`: `systemctl --user restart demo`."
}
#endif
