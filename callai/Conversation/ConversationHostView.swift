import AppKit
import SwiftUI

// Shared multi-turn host for SessionWindow / MainWindow (PLAN §5-2). Owns the
// composer, transient streaming state, the in-flight send Task, and the hosted
// Conversation. It hosts the frozen `ConversationView` once a Conversation
// exists, and draws its own empty placeholder before then.
//
// WHY: all host state is initialized from `init`, so a parent can rebind the
// host to a different conversation via `.id(conversation.id)` — recreating it
// fresh rather than mutating in place.
struct ConversationHostView: View {
    private let client: LLMClient
    private let store: ConversationStore
    private let recorder: MicrophoneRecorder
    private let recognitionService: SpeechRecognitionService
    private let settings: SettingsStore
    private let permissions: PermissionsManager
    // WHY: paired with OnboardingView's relaunch CTA — once Screen Recording
    // is freshly granted in System Settings, TCC still has the old PID
    // cached, so the user has to restart the process. Exposed on the
    // PermissionBanner button instead of forcing a trip back to onboarding.
    private let onRelaunchForPermission: () -> Void

    @State private var composer = ComposerViewModel()
    @State private var streamingState: StreamingState = .idle
    @State private var sendTask: Task<Void, Never>?

    // nil = new-conversation mode: the Conversation is created lazily on the
    // first send, so a window opened and closed without sending leaves no
    // empty Conversation in the store (M4 follow-up #1).
    @State private var conversation: Conversation?

    // WHY: incoming parameters are held as immutable view properties separate
    // from the @State below. SwiftUI keeps @State stable across body re-evals
    // (and reuses the @State `initialValue` only on the first instantiation),
    // so binding them directly via `State(initialValue:)` silently drops every
    // subsequent value the parent supplies — exactly the regression that hid
    // the screenshot preview and CaptureFailureBanner. The .onChange handlers
    // below copy new incoming values into @State so the UI reflects them.
    let incomingPendingAttachment: Data?
    let incomingScreenRecordingDenied: Bool
    let incomingCaptureFailureMessage: String?

    @State private var pendingAttachment: Data?
    @State private var showPermissionBanner: Bool
    @State private var captureFailureMessage: String?

    // V (voice) channel state: `recordingTask` owns the recognition loop so
    // .onDisappear/send-race teardown can cancel it; `voiceError` drives an
    // inline banner with a dismiss button (nil = no banner).
    @State private var recordingTask: Task<Void, Never>?
    @State private var voiceError: String?
    // WHY: when SFSpeech surfaces "Dictation disabled" the banner shows a
    // deeplink button. Held as a flag so the banner stays declarative.
    @State private var voiceErrorOffersDictationDeeplink: Bool = false

    init(
        client: LLMClient,
        store: ConversationStore,
        conversation: Conversation? = nil,
        pendingAttachment: Data? = nil,
        screenRecordingDenied: Bool = false,
        captureFailureMessage: String? = nil,
        recorder: MicrophoneRecorder,
        recognitionService: SpeechRecognitionService,
        settings: SettingsStore,
        permissions: PermissionsManager,
        onRelaunchForPermission: @escaping () -> Void = {}
    ) {
        self.client = client
        self.store = store
        self.recorder = recorder
        self.recognitionService = recognitionService
        self.settings = settings
        self.permissions = permissions
        self.onRelaunchForPermission = onRelaunchForPermission
        self.incomingPendingAttachment = pendingAttachment
        self.incomingScreenRecordingDenied = screenRecordingDenied
        self.incomingCaptureFailureMessage = captureFailureMessage
        _conversation = State(initialValue: conversation)
        _pendingAttachment = State(initialValue: pendingAttachment)
        _showPermissionBanner = State(initialValue: screenRecordingDenied)
        _captureFailureMessage = State(initialValue: captureFailureMessage)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let voiceError {
                VoiceErrorBanner(
                    message: voiceError,
                    onOpenDictationSettings: voiceErrorOffersDictationDeeplink ? openDictationSettings : nil,
                    onDismiss: {
                        self.voiceError = nil
                        self.voiceErrorOffersDictationDeeplink = false
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            // WHY: PermissionBanner outranks CaptureFailureBanner — when
            // Screen Recording is denied, ANY capture failure is downstream of
            // that root cause. Stacking both produces noisy double-banners that
            // give contradictory CTAs ("열어 시스템 설정" vs a transient retry
            // hint). Show only one at a time, capture-failure deferred until
            // the permission banner is dismissed.
            if showPermissionBanner {
                PermissionBanner(
                    onOpenSettings: openScreenRecordingSettings,
                    onRelaunch: onRelaunchForPermission,
                    onDismiss: { showPermissionBanner = false }
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
            } else if let captureFailureMessage {
                CaptureFailureBanner(
                    message: captureFailureMessage,
                    onDismiss: { self.captureFailureMessage = nil }
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            Group {
                if let conversation {
                    ConversationView(
                        conversation: conversation,
                        streamingState: streamingState,
                        composer: composer,
                        onSend: send,
                        onCancel: cancel,
                        settings: settings,
                        onVoiceStart: startVoiceInput,
                        onVoiceStop: stopVoiceInput,
                        onVoiceUnavailableTap: handleVoiceUnavailableTap
                    )
                } else {
                    emptyPlaceholder
                }
            }
        }
        .onAppear {
            drainIncomingAttachment()
            adoptIncomingBanners()
            // M8: seed the composer's model + vision fallback from settings so
            // the per-request Picker starts on the configured default and the
            // image-only fallback honors a user-customized vision prompt.
            composer.model = settings.defaultModel
            composer.visionPromptFallback = settings.visionPrompt.isEmpty
                ? PromptTemplate.defaultVisionPromptFallback
                : settings.visionPrompt
            refreshVoicePermissionGate()
        }
        // WHY: a SwiftUI Window reuses the same view tree when openWindow is
        // called repeatedly with the same id, so the parent (SessionScene) can
        // push fresh values without our @State noticing them. These onChange
        // handlers copy incoming-parameter updates into @State on each visit.
        .onChange(of: incomingPendingAttachment) { _, _ in drainIncomingAttachment() }
        .onChange(of: incomingScreenRecordingDenied) { _, _ in adoptIncomingBanners() }
        .onChange(of: incomingCaptureFailureMessage) { _, _ in adoptIncomingBanners() }
        .onChange(of: permissions.microphone) { _, _ in refreshVoicePermissionGate() }
        .onChange(of: permissions.speechRecognition) { _, _ in refreshVoicePermissionGate() }
        .task(id: composer.model) {
            await refreshModelCapabilities()
        }
        .task {
            await refreshAvailableModels()
        }
        .onDisappear {
            sendTask?.cancel()
            cancelVoiceInput()
        }
    }

    // Host-drawn empty state for new-conversation mode: keeps the composer
    // always available so the user can type and trigger lazy creation, without
    // teaching ConversationView an optional Conversation path (frozen, T4.2.1).
    private var emptyPlaceholder: some View {
        VStack(spacing: 0) {
            ContentUnavailableView("질문을 입력해 대화를 시작하세요", systemImage: "text.bubble")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PromptComposerView(
                viewModel: composer,
                settings: settings,
                onSend: send,
                onVoiceStart: startVoiceInput,
                onVoiceStop: stopVoiceInput,
                onVoiceUnavailableTap: handleVoiceUnavailableTap
            )
        }
    }

    // WHY: drain the latest incoming attachment into the composer, then
    // clear our copy so re-renders are harmless. Called from both .onAppear
    // (initial drain) and .onChange (parent supplied a new screenshot via
    // SessionScene without recreating the view tree).
    private func drainIncomingAttachment() {
        guard let data = incomingPendingAttachment else { return }
        composer.setAttachedImage(data)
        pendingAttachment = nil
    }

    // WHY: copy fresh permission/capture-failure flags into @State so the
    // banners actually render when the parent updates them mid-window-life.
    private func adoptIncomingBanners() {
        if incomingScreenRecordingDenied {
            showPermissionBanner = true
        }
        if let msg = incomingCaptureFailureMessage {
            captureFailureMessage = msg
        }
    }

    // WHY: nil-reset before the await keeps stale capabilities from gating
    // sends across a model change — fail-soft (decision 7); if the lookup
    // fails the value stays nil and `attachedImageDisallowed` returns false.
    private func refreshModelCapabilities() async {
        composer.setModelCapabilities(nil)
        let caps = try? await client.capabilities(of: composer.model)
        composer.setModelCapabilities(caps)
    }

    // WHY: fail-soft — a listModels() failure leaves availableModels empty, and
    // the Picker still offers the active model on its own (modelOptions).
    private func refreshAvailableModels() async {
        let models = (try? await client.listModels()) ?? []
        composer.setAvailableModels(models)
    }

    private func send() {
        // WHY: race handling (decision 9) — if the user fires send while a
        // voice recording is in flight, stop the recorder first so the final
        // STT text lands in the composer before makeUserMessage() reads it.
        if composer.isRecording {
            stopVoiceInput()
        }

        guard composer.canSend else { return }

        // Lazy creation: the first send both creates and persists exactly one
        // Conversation. The user Message is appended (and persisted) before
        // makeRequest so the request carries the full multi-turn history.
        let conversation = self.conversation ?? store.createConversation()
        self.conversation = conversation

        let userMsg = composer.makeUserMessage()
        store.appendUserMessage(userMsg.content, images: userMsg.images, to: conversation)
        composer.text = ""
        // WHY: attachment is single-shot — clear so follow-up turns in the
        // same conversation are text-only unless the user re-attaches.
        composer.setAttachedImage(nil)
        // WHY: STT partial was already merged into the user message via
        // makeUserMessage(); clear it so the next turn starts clean.
        composer.setPartialTranscript(nil)

        let request = store.makeRequest(
            for: conversation,
            model: composer.model,
            systemPrompt: settings.systemPrompt.isEmpty ? nil : settings.systemPrompt
        )
        composer.isSending = true
        streamingState = .streaming(text: "")

        sendTask?.cancel()
        sendTask = Task {
            var accumulated = ""
            do {
                for try await chunk in client.send(request) {
                    if case .text(let token) = chunk {
                        accumulated += token
                        streamingState = .streaming(text: accumulated)
                    }
                }
                store.finishAssistantStream(accumulated, in: conversation)
                // M8: auto-copy only on successful completion — the cancel/error
                // branches below never reach here, so partial/failed responses
                // are never written to the pasteboard.
                if settings.autoCopyResponse, !accumulated.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(accumulated, forType: .string)
                }
                streamingState = .idle
            } catch is CancellationError {
                streamingState = .idle
            } catch let error as LLMClientError {
                streamingState = error == .cancelled ? .idle : .failed(error)
            } catch {
                streamingState = .failed(.transport(message: error.localizedDescription))
            }
            composer.isSending = false
        }
    }

    private func cancel() {
        sendTask?.cancel()
        sendTask = nil
        composer.isSending = false
        streamingState = .idle
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // WHY: macOS 26 keeps Dictation under Keyboard settings; the Dictation
    // anchor opens the right sub-pane in one click. We deliberately don't
    // route through the Siri pane — the user can enable Dictation without
    // enabling Siri, which matches the PLAN privacy posture.
    private func openDictationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshVoicePermissionGate() {
        let mic = permissions.microphone
        let sr = permissions.speechRecognition
        let reason: String?
        if mic == .granted && sr == .granted {
            reason = nil
        } else if mic == .denied || sr == .denied {
            reason = "마이크/음성 인식 권한이 거부되어 있습니다. 시스템 설정에서 권한을 부여하세요."
        } else {
            reason = "마이크/음성 인식 권한이 필요합니다. 🎙을 눌러 권한을 요청하세요."
        }
        composer.setVoiceInputUnavailableReason(reason)
    }

    private func startVoiceInput() {
        voiceError = nil
        // Defensive: cancel any prior task before kicking off a new one so a
        // bouncy push-to-talk hold can't leak two recognition loops.
        recordingTask?.cancel()
        recordingTask = Task { @MainActor in
            do {
                let buffers = try await recorder.start()
                let events = recognitionService.recognize(
                    audio: buffers,
                    locale: Locale(identifier: settings.sttLanguage)
                )
                composer.setIsRecording(true)
                composer.setPartialTranscript("")
                for try await event in events {
                    composer.setPartialTranscript(Self.text(of: event))
                }
                composer.setIsRecording(false)
            } catch let error as MicrophoneRecorderError {
                voiceError = error.userFacingMessage
                cancelVoiceInput()
            } catch let error as SpeechRecognitionError {
                voiceError = error.userFacingMessage
                voiceErrorOffersDictationDeeplink = error.canOpenDictationSettings
                cancelVoiceInput()
            } catch is CancellationError {
                // Normal teardown path — no banner.
            } catch {
                voiceError = "음성 입력 실패: \(error.localizedDescription)"
                cancelVoiceInput()
            }
        }
    }

    private static func text(of event: SpeechRecognitionEvent) -> String {
        switch event {
        case .partial(let t): return t
        case .final(let t):   return t
        }
    }

    // Stops the mic; the recognition stream then yields its final event and
    // closes, leaving the final transcript in `composer.partialTranscript`
    // for makeUserMessage()/send() to merge.
    private func stopVoiceInput() {
        recorder.stop()
        composer.setIsRecording(false)
    }

    private func cancelVoiceInput() {
        recordingTask?.cancel()
        recordingTask = nil
        recorder.stop()
        composer.setPartialTranscript(nil)
        composer.setIsRecording(false)
    }

    private func handleVoiceUnavailableTap() {
        Task { @MainActor in
            if permissions.microphone == .notDetermined {
                _ = await permissions.requestMicrophone()
            }
            if permissions.speechRecognition == .notDetermined {
                _ = await permissions.requestSpeechRecognition()
            }
            if permissions.microphone == .denied || permissions.speechRecognition == .denied {
                openSpeechRecognitionSettings()
            }
            refreshVoicePermissionGate()
        }
    }

    // WHY: Speech Recognition lives under Privacy & Security in System
    // Settings; the deep-link pane covers both mic and STT grants since the
    // user is being routed there for either denial.
    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct VoiceErrorBanner: View {
    let message: String
    // WHY: only populated when SpeechRecognitionError.canOpenDictationSettings
    // is true. The button is hidden otherwise so non-Dictation errors don't get
    // an irrelevant CTA.
    let onOpenDictationSettings: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onOpenDictationSettings {
                    Button("받아쓰기 설정 열기", action: onOpenDictationSettings)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("배너 닫기")
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CaptureFailureBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("배너 닫기")
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PermissionBanner: View {
    let onOpenSettings: () -> Void
    let onRelaunch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("화면 녹화 권한이 필요합니다. 영역 캡쳐를 사용하려면 시스템 설정에서 권한을 부여하고 앱을 재시작하세요.")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("시스템 설정 열기", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("재시작", action: onRelaunch)
                        .controlSize(.small)
                        .help("권한이 새로 부여된 후 현재 인스턴스에 적용하려면 앱을 재시작해야 합니다.")
                }
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("배너 닫기")
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
