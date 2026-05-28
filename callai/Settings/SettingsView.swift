import SwiftUI
import KeyboardShortcuts
import Speech

struct SettingsView: View {
    @Bindable private var settings: SettingsStore
    private let client: LLMClient
    private let hotkeys: HotkeyRegistry
    private let onOpenOnboarding: () -> Void
    private let onboardingComplete: Bool

    @State private var models: [String] = []
    @State private var modelLoadFailed = false

    // WHY: SettingsStore.sttLanguage getter substitutes Locale.current.identifier
    // for an empty raw value, so binding a control directly to it can never show
    // the "use system default" (empty) state. We keep a raw editing buffer seeded
    // from the underlying stored value so empty stays empty in the UI.
    @State private var sttLanguageRaw: String

    init(
        settings: SettingsStore,
        client: LLMClient,
        hotkeys: HotkeyRegistry,
        onOpenOnboarding: @escaping () -> Void,
        onboardingComplete: Bool
    ) {
        self.settings = settings
        self.client = client
        self.hotkeys = hotkeys
        self.onOpenOnboarding = onOpenOnboarding
        self.onboardingComplete = onboardingComplete
        _sttLanguageRaw = State(initialValue: UserDefaults.standard.string(forKey: "sttLanguage") ?? "")
    }

    var body: some View {
        Form {
            connectionSection
            modelSection
            promptSection
            hotkeysSection
            voiceSection
            miscSection
            onboardingSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .task { await loadModels() }
    }

    private var connectionSection: some View {
        Section("연결") {
            TextField("http://localhost:11434", text: $settings.ollamaBaseURL)
                .textFieldStyle(.roundedBorder)
            if showInvalidURLWarning {
                Text("유효한 URL이 아닙니다 — localhost로 대체됩니다.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("비워두면 http://localhost:11434 로 연결합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelSection: some View {
        Section("모델") {
            Picker("기본 모델", selection: $settings.defaultModel) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            if modelLoadFailed {
                Text("모델 목록을 불러오지 못했습니다 (Ollama 연결 확인)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var promptSection: some View {
        Section("시스템 프롬프트") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 60)
                    .font(.body)
                Text("비워두면 시스템 프롬프트를 사용하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Vision 프롬프트") {
                    Button("기본값으로") {
                        settings.visionPrompt = PromptTemplate.defaultVisionPromptFallback
                    }
                    .controlSize(.small)
                }
                TextEditor(text: $settings.visionPrompt)
                    .frame(minHeight: 60)
                    .font(.body)
                Text("이미지만 보낼 때 사용할 기본 프롬프트.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hotkeysSection: some View {
        Section("단축키") {
            LabeledContent("Composer 열기") {
                KeyboardShortcuts.Recorder(for: .openComposer) { _ in
                    hotkeys.refreshAssignmentState()
                }
            }
            LabeledContent("영역 선택 + Composer") {
                KeyboardShortcuts.Recorder(for: .regionThenComposer) { _ in
                    hotkeys.refreshAssignmentState()
                }
            }
        }
    }

    private var voiceSection: some View {
        Section("음성") {
            Picker("음성 입력 모드", selection: $settings.voiceInputMode) {
                ForEach(VoiceInputMode.allCases, id: \.self) { mode in
                    Text(voiceModeLabel(mode)).tag(mode)
                }
            }
            Picker("STT 언어", selection: $sttLanguageRaw) {
                Text("기본 (ko-KR)").tag("")
                ForEach(sttLanguageCandidates, id: \.self) { identifier in
                    Text(identifier).tag(identifier)
                }
            }
            .onChange(of: sttLanguageRaw) { _, newValue in
                settings.sttLanguage = newValue
            }
            Text("‘기본’은 한국어(ko-KR)를 사용합니다. 다른 언어를 쓰려면 직접 선택하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var miscSection: some View {
        Section("기타") {
            Toggle("응답 자동 복사", isOn: $settings.autoCopyResponse)
            Toggle("창 항상 최상위", isOn: $settings.alwaysOnTop)
            Text("(현재는 설정만 저장됩니다 — 적용은 추후 버전)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var onboardingSection: some View {
        Section("온보딩") {
            LabeledContent("권한 및 단축키 설정") {
                Button("온보딩 다시 열기", action: onOpenOnboarding)
            }
            if !onboardingComplete {
                Text("일부 권한 또는 단축키가 아직 설정되지 않았습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // WHY: empty base URL is valid (resolver falls back to localhost). We only
    // warn when the user typed something that is not an http(s) URL with a host,
    // mirroring SettingsStore.resolvedOllamaBaseURL()'s acceptance rule.
    private var showInvalidURLWarning: Bool {
        let trimmed = settings.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return true }
        return false
    }

    // WHY: the saved defaultModel must always be selectable so the Picker shows
    // the persisted value even when listModels() fails or omits it.
    private var modelOptions: [String] {
        var options = models
        if !options.contains(settings.defaultModel) {
            options.insert(settings.defaultModel, at: 0)
        }
        return options
    }

    private var sttLanguageCandidates: [String] {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
        guard !supported.isEmpty else {
            return ["ko-KR", "en-US", "ja-JP", "zh-CN"]
        }
        return supported
    }

    private func voiceModeLabel(_ mode: VoiceInputMode) -> String {
        switch mode {
        case .pushToTalk: "누르고 있는 동안 (push-to-talk)"
        case .toggle: "토글"
        }
    }

    private func loadModels() async {
        // WHY: fail-soft — a missing/unreachable Ollama must not block the UI;
        // an empty result is treated the same as a failure for the caption.
        let fetched = (try? await client.listModels()) ?? []
        models = fetched
        modelLoadFailed = fetched.isEmpty
    }
}
