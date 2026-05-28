import SwiftData
import SwiftUI

// WHY: @Environment(\.modelContext) is unavailable at View.init, so the outer
// view reads the scene's context and builds ConversationStore in body, mirroring
// SessionWindow. MainWindow adds a history sidebar over the same shared host:
// the sidebar's @Query is reactive, so conversations created by SessionWindow
// (same ModelContainer) and by the new-conversation host appear automatically.
struct MainWindow: View {
    private let client: LLMClient
    private let recorder: MicrophoneRecorder
    private let recognitionService: SpeechRecognitionService
    private let settings: SettingsStore
    private let permissions: PermissionsManager

    @Environment(\.modelContext) private var modelContext

    init(
        client: LLMClient,
        recorder: MicrophoneRecorder,
        recognitionService: SpeechRecognitionService,
        settings: SettingsStore,
        permissions: PermissionsManager
    ) {
        self.client = client
        self.recorder = recorder
        self.recognitionService = recognitionService
        self.settings = settings
        self.permissions = permissions
    }

    var body: some View {
        MainWindowContent(
            client: client,
            store: ConversationStore(modelContext: modelContext),
            recorder: recorder,
            recognitionService: recognitionService,
            settings: settings,
            permissions: permissions
        )
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct MainWindowContent: View {
    let client: LLMClient
    let store: ConversationStore
    let recorder: MicrophoneRecorder
    let recognitionService: SpeechRecognitionService
    let settings: SettingsStore
    let permissions: PermissionsManager

    // nil = new-conversation mode. UUID (not the @Model itself) is the selection
    // key so it survives SwiftData re-fetches and the List(selection:) binding
    // stays stable as the @Query reorders rows by updatedAt.
    @State private var selectedID: UUID?

    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    var body: some View {
        NavigationSplitView {
            HistorySidebar(
                conversations: conversations,
                selectedID: $selectedID,
                onNewConversation: { selectedID = nil },
                onDelete: delete
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detailPane
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let conversation = conversations.first(where: { $0.id == selectedID }) {
            // WHY: .id(conversation.id) recreates ConversationHostView when the
            // shown conversation changes — all host state is init-seeded, so this
            // is the documented way to rebind it (resets composer/streamingState).
            ConversationHostView(
                client: client,
                store: store,
                conversation: conversation,
                recorder: recorder,
                recognitionService: recognitionService,
                settings: settings,
                permissions: permissions
            )
            .id(conversation.id)
        } else {
            // No selection (or the selected conversation was deleted) → new-
            // conversation host. The first send lazily creates a Conversation,
            // which then surfaces in the sidebar via the reactive @Query.
            ConversationHostView(
                client: client,
                store: store,
                recorder: recorder,
                recognitionService: recognitionService,
                settings: settings,
                permissions: permissions
            )
            .id("new-conversation")
        }
    }

    private func delete(_ conversation: Conversation) {
        if conversation.id == selectedID {
            selectedID = nil
        }
        store.delete(conversation)
    }
}

private struct HistorySidebar: View {
    let conversations: [Conversation]
    @Binding var selectedID: UUID?
    let onNewConversation: () -> Void
    let onDelete: (Conversation) -> Void

    var body: some View {
        Group {
            if conversations.isEmpty {
                ContentUnavailableView(
                    "대화 없음",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("새 대화를 시작해 보세요.")
                )
            } else {
                List(selection: $selectedID) {
                    ForEach(conversations) { conversation in
                        HistoryRow(conversation: conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                Button("삭제", role: .destructive) { onDelete(conversation) }
                            }
                    }
                    .onDelete(perform: deleteRows)
                }
            }
        }
        .navigationTitle("대화")
        .toolbar {
            ToolbarItem {
                Button(action: onNewConversation) {
                    Label("새 대화", systemImage: "square.and.pencil")
                }
            }
        }
    }

    private func deleteRows(_ offsets: IndexSet) {
        for index in offsets {
            onDelete(conversations[index])
        }
    }
}

private struct HistoryRow: View {
    let conversation: Conversation

    private var displayTitle: String {
        conversation.title.isEmpty ? "새 대화" : conversation.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .lineLimit(1)
            Text(conversation.updatedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
