import Foundation
import SwiftData

// Transient streaming state for the in-flight assistant turn. Completion is not
// a case here — a finished turn is represented by a persisted assistant Message.
enum StreamingState {
    case idle
    case streaming(text: String)
    case failed(LLMClientError)
}

extension LLMClientError {
    // Same wording as the M3 Composer mapping; named distinctly so both can
    // coexist in one module until T4.2.2 removes the Composer copy.
    var userFacingMessage: String {
        switch self {
        case .http(let status):
            return "Ollama 서버가 오류를 반환했습니다 (HTTP \(status)). 잠시 후 다시 시도하세요."
        case .server(let message):
            return "Ollama 서버에서 오류가 발생했습니다: \(message)"
        case .transport:
            return "Ollama 서버에 연결할 수 없습니다. 서버가 실행 중인지 확인하세요."
        case .decoding:
            return "서버 응답을 해석하지 못했습니다. 잠시 후 다시 시도하세요."
        case .cancelled:
            return "요청이 취소되었습니다."
        case .modelNotFound(let model):
            return "모델 '\(model)'을(를) 찾을 수 없습니다. 설치된 모델인지 확인하세요."
        case .unsupported:
            return "이 모델에서 지원하지 않는 기능입니다."
        }
    }
}

@MainActor
@Observable
final class ConversationStore {
    private let modelContext: ModelContext

    // ModelContainer ownership stays in CallaiApp (Stage 4.3); the store
    // only ever receives a context.
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    func createConversation() -> Conversation {
        let conversation = Conversation()
        modelContext.insert(conversation)
        save()
        return conversation
    }

    @discardableResult
    func appendUserMessage(_ content: String, images: [String]? = nil, to conversation: Conversation) -> Message {
        let message = Message(role: .user, content: content, images: images)
        append(message, to: conversation)
        if conversation.title.isEmpty {
            conversation.title = Self.derivedTitle(from: content)
        }
        save()
        return message
    }

    @discardableResult
    func appendAssistantMessage(_ content: String, to conversation: Conversation) -> Message {
        let message = Message(role: .assistant, content: content)
        append(message, to: conversation)
        save()
        return message
    }

    // Persists the accumulated streamed text as the assistant turn once the
    // stream terminates.
    @discardableResult
    func finishAssistantStream(_ text: String, in conversation: Conversation) -> Message {
        appendAssistantMessage(text, to: conversation)
    }

    // Multi-turn builder: the full persisted history becomes the request, so
    // the model receives every prior turn (PLAN §5-2) — not a single-shot
    // request. The caller persists the new user Message before calling this.
    func makeRequest(for conversation: Conversation, model: String, systemPrompt: String? = nil) -> ChatRequest {
        var messages = conversation.orderedMessages.map {
            ChatRequest.Message(role: $0.role, content: $0.content, images: $0.images)
        }
        // M8: optional system prompt is prepended so it precedes the full
        // multi-turn history. Defaulted nil keeps prior call sites unchanged.
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.insert(ChatRequest.Message(role: .system, content: systemPrompt), at: 0)
        }
        return ChatRequest(model: model, messages: messages)
    }

    // Removes a Conversation from history (MainWindow delete action). Cascade
    // delete of its Messages is handled by the @Model relationship rule.
    func delete(_ conversation: Conversation) {
        modelContext.delete(conversation)
        save()
    }

    private func append(_ message: Message, to conversation: Conversation) {
        message.conversation = conversation
        conversation.messages.append(message)
        conversation.updatedAt = .now
    }

    private func save() {
        // Swallowing here would hide data loss; surface via fatalError in dev.
        do {
            try modelContext.save()
        } catch {
            assertionFailure("ConversationStore save failed: \(error)")
        }
    }

    private static func derivedTitle(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(60))
    }
}
