import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = SessionHistoryStore.shared
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.records) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.appName).font(.headline)
                            // Show turn count badge for multi-turn conversations
                            if r.turns.count > 2 {
                                Text("\(r.turns.count / 2) turns")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.cyan.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Text(r.endedAt, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(r.transcript.isEmpty ? "(no transcript)" : r.transcript)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .tag(r.id)
                }
            }
            .frame(minWidth: 320)

            Divider()

            detailPane
                .frame(minWidth: 420)
        }
        .frame(width: 820, height: 520)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let record = store.records.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(record.appName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text(record.endReason.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(record.endedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let path = record.screenshotPath {
                    ScreenshotPreview(path: path)
                }

                // Show conversation history
                if !record.turns.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Conversation")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(record.turns.count) messages")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        ConversationView(turns: record.turns)
                    }
                } else {
                    // Fallback for legacy sessions without turns
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("You asked:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(record.transcript)
                                    .textSelection(.enabled)
                            }

                            if let response = record.aiResponse, !response.isEmpty {
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("AI response:")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(markdownAttributedString(response))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Button("Copy") { copy(record.transcript) }
                    Button("Delete") { store.remove(record.id) }
                    Spacer()
                    Button("Clear All") { store.clear() }
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("History")
                    .font(.title2.weight(.semibold))
                Text("Your recent sessions appear here. Press fn again to start a new thought—previous sessions are saved automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Convert block-level markdown to inline formatting for SwiftUI Text
    private func preprocessMarkdown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            var line = lines[i]
            // Headers → bold
            if line.hasPrefix("### ") {
                line = "**" + line.dropFirst(4) + "**"
            } else if line.hasPrefix("## ") {
                line = "**" + line.dropFirst(3) + "**"
            } else if line.hasPrefix("# ") {
                line = "**" + line.dropFirst(2) + "**"
            }
            // List items → bullet
            if line.hasPrefix("- ") {
                line = "• " + line.dropFirst(2)
            } else if line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            lines[i] = line
        }
        return lines.joined(separator: "\n")
    }

    private func markdownAttributedString(_ text: String) -> AttributedString {
        let processed = preprocessMarkdown(text)
        var result = (try? AttributedString(markdown: processed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)

        // Style links in cyan for visibility
        for run in result.runs {
            if run.link != nil {
                let range = run.range
                result[range].foregroundColor = .cyan
            }
        }

        return result
    }
}

private struct ScreenshotPreview: View {
    let path: String

    var body: some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}


