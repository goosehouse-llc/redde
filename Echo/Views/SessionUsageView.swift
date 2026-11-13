import SwiftUI

struct SessionUsageView: View {
    let session: HermesSessionsAPI.SessionSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Tokens") {
                    row(String(localized: "Input", comment: "Tokens the model read"), session.input_tokens)
                    row(String(localized: "Output", comment: "Tokens the model wrote"), session.output_tokens)
                    row(String(localized: "Reasoning", comment: "Tokens the model spent thinking"), session.reasoning_tokens)
                    row(String(localized: "Cache read", comment: "Tokens read from the provider's prompt cache"), session.cache_read_tokens)
                    row(String(localized: "Cache write", comment: "Tokens written to the provider's prompt cache"), session.cache_write_tokens)
                    LabeledContent("Total") { Text(session.totalTokens.formatted()).monospacedDigit() }
                }
                if (session.cost ?? 0) > 0 {
                    Section("Cost") {
                        LabeledContent("Estimated") { Text(money(session.estimated_cost_usd)).monospacedDigit() }
                        LabeledContent("Actual") { Text(money(session.actual_cost_usd)).monospacedDigit() }
                    }
                }
                Section("Activity") {
                    row(String(localized: "Messages"), session.message_count)
                    row(String(localized: "Tool calls"), session.tool_call_count)
                    row(String(localized: "API calls"), session.api_call_count)
                    if let model = session.model, !model.isEmpty { LabeledContent("Model", value: model) }
                    LabeledContent("Source", value: session.sourceLabel)
                }
                if (session.cost ?? 0) > 0 {
                    Section {
                        Text("Costs are the gateway's own estimate from provider pricing.")
                            .chatFont(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(session.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func row(_ label: String, _ value: Int?) -> some View {
        LabeledContent(label) { Text((value ?? 0).formatted()).monospacedDigit() }
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(value == 0 ? 0 : 4)))
    }
}


/// One project's sessions, grouped by lane (repo checkout / branch), newest first, and a new
/// conversation in it.
