import SwiftUI

/// Licences for the bundled web libraries (KaTeX, its fonts, mermaid), read from Resources/Web/LICENSES.
struct AcknowledgementsView: View {
    /// Read once on appear, not from disk on every body pass.
    @State private var licences: [(String, String)] = []

    private static func loadLicences() -> [(String, String)] {
        let dir = Bundle.main.resourceURL?.appending(path: "Web/LICENSES")
        let names = ["KaTeX-MIT", "KaTeX-fonts-OFL", "mermaid-MIT"]
        return names.compactMap { name in
            guard let url = dir?.appending(path: name + ".txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (name.replacingOccurrences(of: "-", with: " "), text)
        }
    }

    var body: some View {
        List {
            Section {
                Text("Redde renders diagrams with mermaid and math with KaTeX. Both are bundled unmodified in function and used under their licences below.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(licences, id: \.0) { name, text in
                Section(name) {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .task { licences = Self.loadLicences() }
    }
}
