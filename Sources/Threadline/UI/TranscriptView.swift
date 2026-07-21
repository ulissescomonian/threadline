import AppKit
import ConversationCore
import SwiftUI

struct TranscriptView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let detail = model.selectedDetail {
                conversation(detail)
            } else if model.selectedConversationID != nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening conversation…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "text.bubble",
                    description: Text("Choose a conversation to read its complete timeline.")
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 480, ideal: ThreadlineTheme.transcriptWidth)
    }

    private func conversation(_ detail: ConversationDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ConversationHeader(
                        detail: detail,
                        onToggleFavorite: { Task { await model.toggleFavorite(detail.summary) } }
                    )

                    Divider()
                        .padding(.vertical, 22)

                    if detail.events.isEmpty {
                        ContentUnavailableView(
                            "Empty Conversation",
                            systemImage: "bubble.left",
                            description: Text("No transcript events were found for this conversation.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(detail.events) { event in
                            TranscriptEventView(event: event)
                                .id(event.id)
                            if event.id != detail.events.last?.id {
                                TimelineConnector()
                            }
                        }
                    }

                    if !detail.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        NotesView(notes: detail.notes)
                            .padding(.top, 28)
                    }
                }
                .frame(maxWidth: ThreadlineTheme.transcriptWidth, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.32))
            .onChange(of: detail.id) {
                if let first = detail.events.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
        .navigationTitle(detail.summary.title)
    }
}

private struct ConversationHeader: View {
    let detail: ConversationDetail
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ProviderBadge(provider: detail.summary.provider)
                Spacer()
                Button(action: onToggleFavorite) {
                    Image(systemName: detail.summary.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(detail.summary.isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(detail.summary.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityLabel(detail.summary.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }

            Text(detail.summary.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .textSelection(.enabled)

            if !detail.summary.preview.isEmpty {
                Text(detail.summary.preview)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if let project = detail.summary.project {
                    KeyValuePill(icon: "folder", value: project.displayName)
                }
                KeyValuePill(icon: "bubble.left.and.bubble.right", value: "\(detail.summary.messageCount) events")
                KeyValuePill(icon: "arrow.triangle.branch", value: detail.branchID)
                StatusPill(availability: detail.summary.syncAvailability)
            }

            HStack(spacing: 16) {
                Label("Updated \(detail.summary.updatedAt.threadlineRelative)", systemImage: "clock")
                Label(detail.summary.status.label, systemImage: detail.summary.status == .active ? "bolt.fill" : "circle.fill")
                    .foregroundStyle(detail.summary.status.tint)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TimelineConnector: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.55))
            .frame(width: 1, height: 18)
            .padding(.leading, 17)
    }
}

private struct TranscriptEventView: View {
    let event: ConversationEvent

    var body: some View {
        switch event.kind {
        case .userMessage, .assistantMessage, .systemMessage:
            MessageEventView(event: event)
        case .command, .toolCall, .toolResult, .fileChange, .diff, .attachment, .subagent:
            CollapsibleEventView(event: event)
        case .error:
            CalloutEventView(event: event, tint: .red)
        case .compaction, .lifecycle, .unknown:
            CalloutEventView(event: event, tint: .secondary)
        }
    }
}

private struct MessageEventView: View {
    let event: ConversationEvent

    private var isUser: Bool { event.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EventIcon(kind: event.kind, tint: isUser ? ThreadlineTheme.accent : .secondary)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(event.kind.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(event.timestamp, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                RichText(text: event.text)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(15)
            .background(isUser ? ThreadlineTheme.accent.opacity(0.075) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius)
                    .strokeBorder(isUser ? ThreadlineTheme.accent.opacity(0.12) : Color.primary.opacity(0.06))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(event.kind.title), \(event.timestamp.formatted(date: .omitted, time: .shortened))")
    }
}

private struct CollapsibleEventView: View {
    let event: ConversationEvent
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EventIcon(kind: event.kind, tint: tint)

            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    EventBody(text: event.text, kind: event.kind)
                    if !event.metadata.isEmpty {
                        MetadataGrid(metadata: event.metadata)
                    }
                    HStack {
                        Text(event.timestamp, format: .dateTime.hour().minute().second())
                        Spacer()
                        CopyButton(text: event.text)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.kind.title)
                        .font(.subheadline.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(13)
            .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius)
                    .strokeBorder(tint.opacity(0.13))
            }
        }
        .accessibilityLabel("\(event.kind.title): \(summary)")
        .accessibilityHint("Expand to show details")
    }

    private var tint: Color {
        switch event.kind {
        case .diff, .fileChange: .purple
        case .command: .blue
        case .subagent: .indigo
        case .attachment: .orange
        default: .secondary
        }
    }

    private var summary: String {
        if let name = event.metadata["name"] ?? event.metadata["tool"] ?? event.metadata["path"] {
            return name
        }
        return event.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "No details"
    }
}

private struct CalloutEventView: View {
    let event: ConversationEvent
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            EventIcon(kind: event.kind, tint: tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(event.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct EventIcon: View {
    let kind: EventKind
    let tint: Color

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct EventBody: View {
    let text: String
    let kind: EventKind

    var body: some View {
        if kind == .command || kind == .diff || kind == .toolResult {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        } else {
            RichText(text: text)
                .textSelection(.enabled)
        }
    }
}

private struct MetadataGrid: View {
    let metadata: [String: String]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(metadata.keys.sorted(), id: \.self) { key in
                GridRow {
                    Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                        .foregroundStyle(.secondary)
                    Text(metadata[key, default: ""])
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RichText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

private struct NotesView: View {
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Notes", systemImage: "note.text")
                .font(.headline)
            Text(notes)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ThreadlineTheme.cornerRadius)
                .strokeBorder(.yellow.opacity(0.14))
        }
    }
}
