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

                ScrollView {
                    Text(record.transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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


