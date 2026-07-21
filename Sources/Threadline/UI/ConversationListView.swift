import ConversationCore
import AppKit
import SwiftUI

struct ConversationListView: View {
    @Bindable var model: AppModel
    @State private var sortOrder: SortOrder = .recent

    enum SortOrder: String, CaseIterable, Identifiable {
        case recent = "Most Recent"
        case oldest = "Oldest First"
        case title = "Title"
        var id: String { rawValue }
    }

    private var visibleConversations: [ConversationSummary] {
        let scoped = model.conversations.filter { conversation in
            switch model.sidebarSelection {
            case .attention:
                conversation.status == .divergent || conversation.syncAvailability == .blocked || conversation.syncAvailability == .divergent
            default:
                conversation.status != .archived
            }
        }

        switch sortOrder {
        case .recent:
            // SQLite already returns updated_at DESC, id ASC. Avoid sorting the
            // full library again whenever import progress updates the banner.
            return scoped
        case .oldest:
            return Array(scoped.reversed())
        case .title:
            return scoped.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        Group {
            if model.sidebarSelection == .attention {
                attentionContent
            } else if model.isLoading && model.conversations.isEmpty {
                LoadingLibraryView()
            } else if shouldShowCenteredImport {
                InitialImportView(
                    presentation: model.ingestionPresentation
                )
            } else if shouldShowUpdatingEmptyFilter {
                UpdatingEmptyFilterView(
                    filterName: selectedFilterName,
                    presentation: model.ingestionPresentation
                )
            } else if visibleConversations.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isImporting && !shouldShowCenteredImport && !shouldShowUpdatingEmptyFilter {
                ImportProgressBanner(
                    presentation: model.ingestionPresentation
                )
            }
        }
        .frame(minWidth: 300)
        .navigationTitle(sectionTitle)
        .navigationSplitViewColumnWidth(min: 300, ideal: ThreadlineTheme.listWidth, max: 420)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search conversations")
        .task(id: model.searchText) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.reloadCurrentView()
            } catch {}
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Label("Sort conversations", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort conversations")
            }
        }
    }

    private var conversationList: some View {
        List(selection: $model.selectedConversationID) {
            ForEach(visibleConversations) { conversation in
                ConversationRow(
                    conversation: conversation,
                    onToggleFavorite: { Task { await model.toggleFavorite(conversation) } }
                )
                .tag(conversation.id)
            }
        }
        .listStyle(.inset)
        .onChange(of: model.selectedConversationID) {
            Task { await model.selectConversation(model.selectedConversationID) }
        }
        .accessibilityLabel("Conversations")
    }

    @ViewBuilder
    private var attentionContent: some View {
        let issues = model.health.actionableIssues
        let automaticError = model.automaticReconciliationError
        if issues.isEmpty && automaticError == nil {
            ContentUnavailableView {
                Label("Nothing Needs Attention", systemImage: "checkmark.circle")
            } description: {
                Text(attentionEmptyDescription)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(attentionSummary(hasAutomaticError: automaticError != nil))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)

                    if let automaticError {
                        AutomaticReconciliationAttentionCard(message: automaticError)
                    }

                    ForEach(issues) { issue in
                        DiagnosticIssueCard(issue: issue, compact: true)
                    }

                    HStack {
                        Button("Refresh Library") {
                            Task { await model.refresh() }
                        }
                        .disabled(model.isReconciliationBusy)
                        Spacer()
                        Button("Sync Now") {
                            Task { await model.syncNow() }
                        }
                        .disabled(model.isReconciliationBusy)
                        .help("Sync Now runs as soon as possible")
                    }
                    .padding(.top, 4)
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySymbol)
            } description: {
                Text(emptyDescription)
            } actions: {
                Button("Refresh Library") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isReconciliationBusy)
            }
        }
    }

    private var sectionTitle: String {
        return switch model.sidebarSelection {
        case .all: "All Conversations"
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .favorites: "Favorites"
        case .attention: "Needs Attention"
        }
    }

    private var emptyTitle: String {
        switch model.sidebarSelection {
        case .codex: "No Codex Conversations Yet"
        case .claude: "No Claude Code Conversations Yet"
        case .favorites: "No Favorites"
        case .attention: "Nothing Needs Attention"
        default: "No Conversations Yet"
        }
    }

    private var emptySymbol: String {
        switch model.sidebarSelection {
        case .favorites: "star"
        case .attention: "checkmark.circle"
        default: "bubble.left.and.bubble.right"
        }
    }

    private var emptyDescription: String {
        switch model.sidebarSelection {
        case .codex: "No Codex conversations are available in this filter yet."
        case .claude: "No Claude Code conversations are available in this filter yet."
        case .favorites: "Mark an important conversation with a star to keep it close."
        case .attention: attentionEmptyDescription
        default: "Threadline will add your Codex and Claude Code conversations automatically."
        }
    }

    private var shouldShowCenteredImport: Bool {
        guard model.isImporting,
              model.conversations.isEmpty,
              model.searchText.isEmpty else { return false }

        return switch model.sidebarSelection {
        case .all:
            true
        case .codex, .claude, .favorites, .attention:
            false
        }
    }

    private var shouldShowUpdatingEmptyFilter: Bool {
        model.isImporting
            && visibleConversations.isEmpty
            && model.searchText.isEmpty
            && model.sidebarSelection != .attention
            && !shouldShowCenteredImport
    }

    private var selectedFilterName: String {
        switch model.sidebarSelection {
        case .all: "All Conversations"
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .favorites: "Favorites"
        case .attention: "Needs Attention"
        }
    }

    private var attentionEmptyDescription: String {
        if model.health.pendingObjectCount > 0 {
            "Nothing requires intervention. Automatic sync is enabled for queued items."
        } else {
            "Your library has no diagnostics that require intervention."
        }
    }

    private func attentionSummary(hasAutomaticError: Bool) -> String {
        if hasAutomaticError {
            return "These diagnostics need attention. Threadline will retry automatically."
        }
        return "These diagnostics include a recovery step you can take."
    }
}

private struct AutomaticReconciliationAttentionCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Automatic reconciliation needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Threadline will retry automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProviderBadge(provider: conversation.provider, showName: false)
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(conversation.updatedAt, format: .relative(presentation: .numeric))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !conversation.preview.isEmpty {
                Text(conversation.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let project = conversation.project {
                    Label(project.displayName, systemImage: "folder")
                        .lineLimit(1)
                }
                if conversation.messageCount > 0 {
                    Label("\(conversation.messageCount)", systemImage: "bubble.left")
                }
                Spacer(minLength: 0)
                StatusPill(availability: conversation.syncAvailability)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button(conversation.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: conversation.isFavorite ? "star.slash" : "star") {
                onToggleFavorite()
            }
            Divider()
            Button("Copy Session ID", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.providerSessionID, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title), \(conversation.provider.displayName), updated \(conversation.updatedAt.threadlineRelative)")
    }
}

private struct LoadingLibraryView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Opening your library…")
                .font(.headline)
            Text("Preparing your local conversation index")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct InitialImportView: View {
    let presentation: IngestionPresentation

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill((presentation.provider?.tint ?? ThreadlineTheme.accent).opacity(0.1))
                    .frame(width: 64, height: 64)
                ProgressView()
                    .controlSize(.large)
                    .tint(presentation.provider?.tint ?? ThreadlineTheme.accent)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(countDescription)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("The first import may take a little while. You can continue using Threadline while it finishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(countDescription). You can continue using Threadline while the import finishes.")
    }

    private var title: String {
        if let provider = presentation.provider {
            return "Importing \(provider.displayName)…"
        }
        return "Finding conversations…"
    }

    private var countDescription: String {
        switch presentation.processedConversationCount {
        case 0: "Scanning your conversation history"
        case 1: "1 conversation processed"
        default: "\(presentation.processedConversationCount) conversations processed"
        }
    }
}

private struct UpdatingEmptyFilterView: View {
    let filterName: String
    let presentation: IngestionPresentation

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(ThreadlineTheme.accent.opacity(0.09))
                    .frame(width: 62, height: 62)
                ProgressView()
                    .controlSize(.large)
            }

            VStack(spacing: 7) {
                Text("Updating your library…")
                    .font(.title3.weight(.semibold))
                Text("The \(filterName) view is still empty while Threadline rebuilds its index.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: 8) {
                if let ingestionProvider = presentation.provider {
                    ProviderBadge(provider: ingestionProvider)
                    Text("is being processed")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scanning Codex and Claude Code")
                        .foregroundStyle(.secondary)
                }

                if presentation.processedConversationCount > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(presentation.processedConversationCount) processed")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatus)
    }

    private var accessibilityStatus: String {
        var status = "Updating your library. The \(filterName) view is still empty while Threadline rebuilds its index."
        if let ingestionProvider = presentation.provider {
            status += " \(ingestionProvider.displayName) is being processed."
        }
        if presentation.processedConversationCount > 0 {
            status += " \(presentation.processedConversationCount) conversations processed."
        }
        return status
    }
}

private struct ImportProgressBanner: View {
    let presentation: IngestionPresentation

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(presentation.provider?.tint ?? ThreadlineTheme.accent)

            Text(statusText)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            if presentation.processedConversationCount > 0 {
                Text("\(presentation.processedConversationCount) processed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatus)
    }

    private var statusText: String {
        if let provider = presentation.provider {
            return "Updating from \(provider.displayName)…"
        }
        return "Updating your library…"
    }

    private var accessibilityStatus: String {
        guard presentation.processedConversationCount > 0 else { return statusText }
        return "\(statusText) \(presentation.processedConversationCount) conversations processed."
    }
}
