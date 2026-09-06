import BridgeCore
import SwiftUI

/// Live view of what Claude Desktop asked for and what the backend said.
struct LogView: View {
    @Bindable var state: AppState
    @State private var selection: LogEntry.ID?
    @State private var failuresOnly = false

    private var visible: [LogEntry] {
        failuresOnly ? state.entries.filter(\.outcome.isFailure) : state.entries
    }

    var body: some View {
        VSplitView {
            Table(visible, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(78)

                TableColumn("") { entry in
                    Image(systemName: entry.outcome.isFailure ? "xmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(entry.outcome.isFailure ? Color.red : Color.green)
                }
                .width(20)

                TableColumn("Status") { entry in
                    Text(entry.statusText).monospacedDigit()
                }
                .width(48)

                TableColumn("Path") { entry in Text(entry.path) }
                    .width(min: 110, ideal: 150)

                TableColumn("Model") { entry in
                    Text(entry.upstreamModel ?? "—")
                }
                .width(min: 120, ideal: 180)

                TableColumn("Profile") { entry in
                    Text(entry.profileName).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 120)

                TableColumn("Tokens") { entry in
                    Text(tokenSummary(entry))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(96)

                TableColumn("Time") { entry in
                    Text(entry.duration.map { "\(Int($0 * 1000)) ms" } ?? "…")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(70)
            }
            .frame(minHeight: 180)

            detail
                .frame(minHeight: 140)
        }
        .safeAreaInset(edge: .top) { toolbar }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Toggle("Failures only", isOn: $failuresOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("Capture bodies", isOn: $state.captureBodies)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Records full request and response bodies for new requests. Kept in memory only.")
            Spacer()
            Text("\(visible.count) request\(visible.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Clear") {
                selection = nil
                state.clearLog()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, let entry = state.entries.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if case .failed(_, let message) = entry.outcome {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    LabeledContent("Upstream", value: entry.upstreamURL ?? "—")
                    LabeledContent("Streamed", value: entry.streamed ? "Yes" : "No")

                    if let body = entry.requestBody {
                        CodeBlock(title: "Request", text: body)
                    }
                    if let body = entry.responseBody {
                        CodeBlock(title: "Response", text: body)
                    }
                    if entry.requestBody == nil && entry.responseBody == nil {
                        Text("Turn on “Capture bodies” to record the full exchange for new requests.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No Request Selected",
                systemImage: "list.bullet.rectangle",
                description: Text("Pick a request above to see its details.")
            )
        }
    }

    private func tokenSummary(_ entry: LogEntry) -> String {
        guard let input = entry.inputTokens, let output = entry.outputTokens else { return "—" }
        return "\(input) → \(output)"
    }
}

private struct CodeBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
