import Foundation

@MainActor
@Observable
final class ComposerViewModel {
    var text: String = ""
    var model: String = "gemma4:latest"
    var isSending: Bool = false

    // M8: per-request model picker source. Host seeds this from
    // `client.listModels()` (fail-soft → empty). Empty list keeps the active
    // `model` selectable on its own in PromptComposerView.
    var availableModels: [String] = []

    // M8: image-only fallback prompt. Host overrides from settings.visionPrompt;
    // defaults to the frozen template so an unconfigured settings store still
    // produces a valid vision turn.
    var visionPromptFallback: String = PromptTemplate.defaultVisionPromptFallback

    // Screenshot (S) channel arrives in M6 — this stage adds attachedImage +
    // capability gating. V seam (microphone) arrives in M7. Multi-turn history
    // assembly stays with ConversationStore (PLAN §5-2).

    // PNG raw bytes; nil = no attachment. Host writes via setAttachedImage().
    var attachedImage: Data?

    // nil = capabilities not yet fetched (don't block), [] = none, contains
    // "vision" = vision-capable. Host writes via setModelCapabilities() after
    // calling LLMClient.capabilities(of:).
    var modelCapabilities: [String]?

    // V seam (M7): nil = no STT data received, non-nil = partial accumulating
    // during recording or the final transcript just after stop. Host writes via
    // setPartialTranscript(); cleared back to nil after makeUserMessage() folds
    // it into the sent turn (ConversationStore handles the clear).
    var partialTranscript: String?

    // V seam (M7): UI mirror of the active recording state. Host flips this
    // via setIsRecording() around the AudioRecorder lifecycle so the 🎙 button
    // can show the recording affordance independent of partialTranscript
    // (which lags behind first audio frames).
    var isRecording: Bool = false

    // V seam (M7): nil = mic available, non-nil = disabled reason (denied
    // permission, no input device, STT model missing). PromptComposerView
    // surfaces this as a tooltip and disables the 🎙 button.
    var voiceInputUnavailableReason: String?

    // WHY: only fire the disallowed signal once capabilities are known to be
    // non-vision — if capabilities is nil (unknown) we optimistically allow
    // send, matching PROGRESS done-when for image-only flow.
    var attachedImageDisallowed: Bool {
        guard attachedImage != nil, let caps = modelCapabilities else { return false }
        return !caps.contains(visionCapability)
    }

    // WHY: V-only sends (시나리오 2-7) must enable canSend even with empty
    // text — partialTranscript counts as user content. effectiveText combines
    // both trimmed channels so the legacy "hasText" check stays true whenever
    // any of (text, partial) is non-empty.
    var canSend: Bool {
        guard !isSending else { return false }
        guard !attachedImageDisallowed else { return false }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPartial = (partialTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !trimmedText.isEmpty || !trimmedPartial.isEmpty
        let hasImage = attachedImage != nil
        return hasContent || hasImage
    }

    func setAttachedImage(_ data: Data?) {
        attachedImage = data
    }

    func setModelCapabilities(_ caps: [String]?) {
        modelCapabilities = caps
    }

    func setPartialTranscript(_ text: String?) {
        partialTranscript = text
    }

    func setIsRecording(_ flag: Bool) {
        isRecording = flag
    }

    func setVoiceInputUnavailableReason(_ reason: String?) {
        voiceInputUnavailableReason = reason
    }

    func setAvailableModels(_ models: [String]) {
        availableModels = models
    }

    // WHY: ComposerViewModel owns only the new user turn; multi-turn
    // ChatRequest assembly (full history) is ConversationStore's job (PLAN §5-2).
    // Merge order is text-first then partial separated by a single space — the
    // typed prefix sets context for the spoken tail, matching the
    // "type-then-speak" UX. Image-only fallback to defaultVisionPrompt is
    // preserved from M6 when both channels are empty.
    func makeUserMessage() -> ChatRequest.Message {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPartial = (partialTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let merged: String
        switch (trimmedText.isEmpty, trimmedPartial.isEmpty) {
        case (false, false): merged = trimmedText + " " + trimmedPartial
        case (false, true):  merged = trimmedText
        case (true,  false): merged = trimmedPartial
        case (true,  true):  merged = ""
        }

        if let image = attachedImage {
            // Ollama spec: base64 PNG, no `data:` prefix.
            let base64 = image.base64EncodedString()
            let content = merged.isEmpty ? visionPromptFallback : merged
            return ChatRequest.Message(role: .user, content: content, images: [base64])
        }
        return ChatRequest.Message(role: .user, content: merged)
    }

    private let visionCapability = "vision"
}
