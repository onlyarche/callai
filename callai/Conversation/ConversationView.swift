import AppKit
import SwiftUI

// Shared transcript component for SessionWindow / MainWindow (PLAN §3).
// Display-only: the LLM call, stream consumption, and persistence are owned by
// the host (SessionWindow) — this view renders an injected `Conversation` plus
// the transient `StreamingState` and delegates sends via `onSend`.
struct ConversationView: View {
    private let conversation: Conversation
    private let streamingState: StreamingState
    private let composer: ComposerViewModel
    private let onSend: () -> Void
    private let onCancel: (() -> Void)?
    private let settings: SettingsStore
    private let onVoiceStart: () -> Void
    private let onVoiceStop: () -> Void
    private let onVoiceUnavailableTap: (() -> Void)?

    init(
        conversation: Conversation,
        streamingState: StreamingState,
        composer: ComposerViewModel,
        onSend: @escaping () -> Void,
        onCancel: (() -> Void)? = nil,
        settings: SettingsStore,
        onVoiceStart: @escaping () -> Void,
        onVoiceStop: @escaping () -> Void,
        onVoiceUnavailableTap: (() -> Void)? = nil
    ) {
        self.conversation = conversation
        self.streamingState = streamingState
        self.composer = composer
        self.onSend = onSend
        self.onCancel = onCancel
        self.settings = settings
        self.onVoiceStart = onVoiceStart
        self.onVoiceStop = onVoiceStop
        self.onVoiceUnavailableTap = onVoiceUnavailableTap
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            PromptComposerView(
                viewModel: composer,
                settings: settings,
                onSend: onSend,
                onVoiceStart: onVoiceStart,
                onVoiceStop: onVoiceStop,
                onVoiceUnavailableTap: onVoiceUnavailableTap
            )
        }
    }

    @ViewBuilder
    private var transcript: some View {
        let messages = conversation.orderedMessages

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty, !isStreaming, !isFailed {
                        ContentUnavailableView("질문을 입력해 대화를 시작하세요", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ForEach(messages) { message in
                            MessageBubble(
                                role: message.role,
                                text: message.content,
                                images: message.images
                            )
                            .id(message.id)
                        }
                    }

                    if case .streaming(let text) = streamingState {
                        StreamingBubble(text: text, onCancel: onCancel)
                            .id(Self.streamingAnchor)
                    }

                    if case .failed(let error) = streamingState {
                        ErrorBanner(message: error.userFacingMessage)
                            .id(Self.streamingAnchor)
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) { _, _ in
                if let lastID = messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: streamingText) { _, _ in
                proxy.scrollTo(Self.streamingAnchor, anchor: .bottom)
            }
        }
    }

    private static let streamingAnchor = "conversation-streaming-anchor"

    private var isStreaming: Bool {
        if case .streaming = streamingState { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = streamingState { return true }
        return false
    }

    // Drives the scroll-to-bottom hop as streamed tokens accumulate.
    private var streamingText: String {
        if case .streaming(let text) = streamingState { return text }
        return ""
    }
}

private struct MessageBubble: View {
    let role: ChatRequest.Role
    let text: String
    // WHY: Message.images stores base64 PNGs as persisted on the user turn
    // (see Conversation/Message.swift + ConversationStore.appendUserMessage).
    // Without rendering them here the screenshot the user attached vanishes
    // from the transcript even though it was sent to Ollama — exactly the
    // "history can't show the image" symptom. Decoded lazily on appear so
    // long transcripts don't pay the cost up-front.
    let images: [String]?

    private var isUser: Bool { role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 8) {
                if let images, !images.isEmpty {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, base64 in
                        AttachedImageThumb(base64: base64)
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(
                isUser ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.background.secondary),
                in: RoundedRectangle(cornerRadius: 10)
            )

            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// WHY: base64 → NSImage on first render, then SwiftUI Image. Capped width so
// a 3000×1500 desktop capture doesn't overflow the bubble; aspect ratio is
// preserved. Failure to decode falls back to a small placeholder so a corrupt
// row never breaks the whole transcript.
private struct AttachedImageThumb: View {
    let base64: String
    private static let maxWidth: CGFloat = 360

    var body: some View {
        if let image = decoded {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Self.maxWidth)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Label("이미지를 표시할 수 없습니다", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var decoded: NSImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}

private struct StreamingBubble: View {
    let text: String
    let onCancel: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("응답 생성 중…").foregroundStyle(.secondary)
                    Spacer()
                    if let onCancel {
                        Button("취소", role: .cancel, action: onCancel)
                            .controlSize(.small)
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            Spacer(minLength: 40)
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
