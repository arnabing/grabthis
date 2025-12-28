import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = SessionHistoryStore.shared
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            // Sidebar: Session list
            List(selection: $selection) {
                ForEach(store.records) { record in
                    SessionRow(record: record)
                        .tag(record.id)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            // Detail: iMessage-style chat
            if let record = store.records.first(where: { $0.id == selection }) {
                ChatDetailView(record: record, store: store)
            } else {
                EmptyStateView()
            }
        }
        .frame(width: 820, height: 560)
    }
}

// MARK: - Session Row (Sidebar)

private struct SessionRow: View {
    let record: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.appName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(record.endedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(record.transcript.isEmpty ? "No transcript" : record.transcript)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if record.turns.count > 2 {
                Text("\(record.turns.count / 2) exchanges")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chat Detail View

private struct ChatDetailView: View {
    let record: SessionRecord
    let store: SessionHistoryStore
    @State private var showingExpandedScreenshot = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            ChatHeader(record: record)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Screenshot at top if available (small thumbnail, tappable)
                        if let path = record.screenshotPath {
                            ScreenshotBubble(path: path, onTap: { showingExpandedScreenshot = true })
                                .padding(.bottom, 8)
                        }

                        // Chat messages
                        if !record.turns.isEmpty {
                            ForEach(Array(record.turns.enumerated()), id: \.offset) { index, turn in
                                MessageBubble(
                                    role: turn.role,
                                    content: turn.content,
                                    isFirst: isFirstInGroup(at: index),
                                    isLast: isLastInGroup(at: index)
                                )
                                .id(index)
                            }
                        } else {
                            // Legacy fallback
                            LegacyMessageView(record: record)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }

            Divider()

            // Footer actions
            ChatFooter(record: record, store: store)
        }
        .sheet(isPresented: $showingExpandedScreenshot) {
            if let path = record.screenshotPath, let nsImage = NSImage(contentsOfFile: path) {
                ExpandedScreenshotSheet(image: nsImage) {
                    showingExpandedScreenshot = false
                }
            }
        }
    }

    private func isFirstInGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return record.turns[index].role != record.turns[index - 1].role
    }

    private func isLastInGroup(at index: Int) -> Bool {
        guard index < record.turns.count - 1 else { return true }
        return record.turns[index].role != record.turns[index + 1].role
    }
}

// MARK: - Chat Header

private struct ChatHeader: View {
    let record: SessionRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.appName)
                    .font(.headline)
                Text(record.endedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.endReason.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.fill.tertiary)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Chat Footer

private struct ChatFooter: View {
    let record: SessionRecord
    let store: SessionHistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.transcript, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                store.remove(record.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            // Continue conversation button
            Button {
                NotificationCenter.default.post(name: .continueSession, object: record)
                // Close the History window
                NSApp.keyWindow?.close()
            } label: {
                Label("Continue", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button(role: .destructive) {
                store.clear()
            } label: {
                Text("Clear All")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Screenshot Bubble

private struct ScreenshotBubble: View {
    let path: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack {
            Spacer(minLength: 100)

            if let nsImage = NSImage(contentsOfFile: path) {
                Button(action: { onTap?() }) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 120, maxHeight: 80)  // Small thumbnail like overlay
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            // Expand icon hint
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .help("Click to expand screenshot")
            }
        }
    }
}

// MARK: - Expanded Screenshot Sheet

private struct ExpandedScreenshotSheet: View {
    let image: NSImage
    let onDismiss: () -> Void

    // Calculate ideal size based on image aspect ratio and screen
    private var idealSize: CGSize {
        guard let screen = NSScreen.main else {
            return CGSize(width: 1200, height: 800)
        }
        let screenSize = screen.visibleFrame.size
        let maxWidth = min(screenSize.width * 0.85, 1600)
        let maxHeight = min(screenSize.height * 0.85, 1200)

        let imageAspect = image.size.width / image.size.height
        let frameAspect = maxWidth / maxHeight

        if imageAspect > frameAspect {
            // Image is wider - constrain by width
            return CGSize(width: maxWidth, height: maxWidth / imageAspect)
        } else {
            // Image is taller - constrain by height
            return CGSize(width: maxHeight * imageAspect, height: maxHeight)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Screenshot")
                    .font(.headline)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Image with padding
            GeometryReader { geometry in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
        .frame(width: idealSize.width, height: idealSize.height + 60)  // +60 for header
        .background(.regularMaterial)
    }
}

// MARK: - Message Bubble (iMessage Style)

private struct MessageBubble: View {
    let role: ConversationTurn.Role
    let content: String
    let isFirst: Bool
    let isLast: Bool

    private var isUser: Bool { role == .user }

    // iMessage colors
    private var bubbleColor: Color {
        isUser ? Color.blue : Color(nsColor: .systemGray).opacity(0.25)
    }

    private var textColor: Color {
        isUser ? .white : .primary
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text(processedContent)
                    .font(.body)
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleColor)
                    .clipShape(ChatBubbleShape(isUser: isUser, isFirst: isFirst, isLast: isLast))
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.vertical, isLast ? 4 : 1)
    }

    private var processedContent: AttributedString {
        if isUser {
            return AttributedString(content)
        }
        // Render markdown for AI responses
        return markdownAttributedString(content)
    }

    private func preprocessMarkdown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for i in lines.indices {
            var line = lines[i]
            if line.hasPrefix("### ") {
                line = "**" + line.dropFirst(4) + "**"
            } else if line.hasPrefix("## ") {
                line = "**" + line.dropFirst(3) + "**"
            } else if line.hasPrefix("# ") {
                line = "**" + line.dropFirst(2) + "**"
            }
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

        for run in result.runs {
            if run.link != nil {
                let range = run.range
                result[range].foregroundColor = .cyan
            }
        }

        return result
    }
}

// MARK: - Chat Bubble Shape (with tail)

private struct ChatBubbleShape: Shape {
    let isUser: Bool
    let isFirst: Bool
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let tailSize: CGFloat = 6

        var path = Path()

        if isLast {
            // Bubble with tail
            if isUser {
                // User bubble: tail on right
                let bubbleRect = CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height)
                path.addRoundedRect(in: bubbleRect, cornerRadii: RectangleCornerRadii(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: 4,
                    topTrailing: isFirst ? radius : 4
                ))
                // Tail
                path.move(to: CGPoint(x: rect.width - tailSize, y: rect.height - 8))
                path.addQuadCurve(
                    to: CGPoint(x: rect.width, y: rect.height),
                    control: CGPoint(x: rect.width - 2, y: rect.height - 2)
                )
                path.addLine(to: CGPoint(x: rect.width - tailSize, y: rect.height))
            } else {
                // AI bubble: tail on left
                let bubbleRect = CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height)
                path.addRoundedRect(in: bubbleRect, cornerRadii: RectangleCornerRadii(
                    topLeading: isFirst ? radius : 4,
                    bottomLeading: 4,
                    bottomTrailing: radius,
                    topTrailing: radius
                ))
                // Tail
                path.move(to: CGPoint(x: tailSize, y: rect.height - 8))
                path.addQuadCurve(
                    to: CGPoint(x: 0, y: rect.height),
                    control: CGPoint(x: 2, y: rect.height - 2)
                )
                path.addLine(to: CGPoint(x: tailSize, y: rect.height))
            }
        } else {
            // Regular bubble without tail
            if isUser {
                path.addRoundedRect(in: rect, cornerRadii: RectangleCornerRadii(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: 4,
                    topTrailing: isFirst ? radius : 4
                ))
            } else {
                path.addRoundedRect(in: rect, cornerRadii: RectangleCornerRadii(
                    topLeading: isFirst ? radius : 4,
                    bottomLeading: 4,
                    bottomTrailing: radius,
                    topTrailing: radius
                ))
            }
        }

        return path
    }
}

// MARK: - Legacy Message View

private struct LegacyMessageView: View {
    let record: SessionRecord

    var body: some View {
        VStack(spacing: 8) {
            if !record.transcript.isEmpty {
                MessageBubble(
                    role: .user,
                    content: record.transcript,
                    isFirst: true,
                    isLast: record.aiResponse == nil
                )
            }

            if let response = record.aiResponse, !response.isEmpty {
                MessageBubble(
                    role: .assistant,
                    content: response,
                    isFirst: true,
                    isLast: true
                )
            }
        }
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text("No Conversation Selected")
                    .font(.title3.weight(.medium))
                Text("Select a session from the sidebar to view the conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
