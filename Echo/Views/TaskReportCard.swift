import SwiftUI

/// A finished task's report at the end of the chat, in the words its notification showed, until
/// Hermes writes its own row for it (`TaskReports`, GitHub issue 63). Drawn as that row is
/// (`DeliveredMessage`), so the one reads as the other when it comes.
struct TaskReportCard: View {
    let report: TaskReport
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").frame(width: 20).foregroundStyle(.secondary)
                Text(report.heading).chatFont(.subheadline, weight: .semibold)
                Spacer(minLength: 8)
                Text(report.at.formatted(.relative(presentation: .named)))
                    .chatFont(.caption).foregroundStyle(.secondary)
            }
            if !report.body.isEmpty {
                MarkdownView(text: report.body, isLive: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, theme.bubbleVerticalPadding)
                    .background(RoundedRectangle(cornerRadius: theme.bubbleRadius).fill(theme.surfaceColor.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: theme.bubbleRadius).strokeBorder(.quaternary))
                    .foregroundStyle(theme.textColor)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = report.body }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(report.heading)
        .accessibilityIdentifier("taskReport")
    }
}
