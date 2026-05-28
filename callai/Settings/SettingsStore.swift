import Foundation
import SwiftUI

// WHY: Raw String + CaseIterable so a settings UI (M8) can iterate without a
// hand-maintained list, and so `@AppStorage` can persist by raw value.
// Default is `.pushToTalk` per PLAN §2/§8 — voice input ships push-to-talk
// first, toggle is opt-in.
enum VoiceInputMode: String, CaseIterable, Sendable {
    case pushToTalk
    case toggle
}

// WHY: `@Observable` for SwiftUI tracking. `@AppStorage` properties inside an
// `@Observable` class are marked `@ObservationIgnored` because their backing
// `UserDefaults` already triggers SwiftUI invalidation on write — letting
// Observation track them too would double-fire updates. The public surface
// is a computed `var` so we can apply default-fallback logic (e.g.
// `sttLanguage` empty → `Locale.current.identifier`) and so we go through
// `@Observable`'s synthesized accessors for read tracking.
@Observable
@MainActor
final class SettingsStore {
    @ObservationIgnored
    @AppStorage("voiceInputMode")
    private var rawVoiceInputMode: String = VoiceInputMode.pushToTalk.rawValue

    @ObservationIgnored
    @AppStorage("sttLanguage")
    private var rawSttLanguage: String = ""

    @ObservationIgnored
    @AppStorage("ollamaBaseURL")
    private var rawOllamaBaseURL: String = ""

    @ObservationIgnored
    @AppStorage("defaultModel")
    private var rawDefaultModel: String = "gemma4:latest"

    @ObservationIgnored
    @AppStorage("systemPrompt")
    private var rawSystemPrompt: String = ""

    @ObservationIgnored
    @AppStorage("visionPrompt")
    private var rawVisionPrompt: String = PromptTemplate.defaultVisionPromptFallback

    @ObservationIgnored
    @AppStorage("autoCopyResponse")
    private var rawAutoCopyResponse: Bool = false

    @ObservationIgnored
    @AppStorage("alwaysOnTop")
    private var rawAlwaysOnTop: Bool = false

    init() {}

    var voiceInputMode: VoiceInputMode {
        get { VoiceInputMode(rawValue: rawVoiceInputMode) ?? .pushToTalk }
        set { rawVoiceInputMode = newValue.rawValue }
    }

    // WHY: Empty stored value means "use the app's default", which for this
    // Korean-localised app is `ko-KR` — not `Locale.current.identifier`.
    // The latter follows the macOS region (often `en_US` even on Macs whose
    // UI language is Korean), and SFSpeechRecognizer happily transcribes
    // Korean speech as nonsense English when fed an English locale. Users
    // who want a different STT language pin it explicitly via Settings.
    static let defaultSttLanguage = "ko-KR"

    var sttLanguage: String {
        get { rawSttLanguage.isEmpty ? Self.defaultSttLanguage : rawSttLanguage }
        set { rawSttLanguage = newValue }
    }

    // WHY: Raw value preserved as-is; validation/fallback to localhost happens in
    // resolvedOllamaBaseURL() so the OllamaClient provider can read it nonisolated.
    var ollamaBaseURL: String {
        get { rawOllamaBaseURL }
        set { rawOllamaBaseURL = newValue }
    }

    var defaultModel: String {
        get { rawDefaultModel }
        set { rawDefaultModel = newValue }
    }

    var systemPrompt: String {
        get { rawSystemPrompt }
        set { rawSystemPrompt = newValue }
    }

    var visionPrompt: String {
        get { rawVisionPrompt }
        set { rawVisionPrompt = newValue }
    }

    var autoCopyResponse: Bool {
        get { rawAutoCopyResponse }
        set { rawAutoCopyResponse = newValue }
    }

    var alwaysOnTop: Bool {
        get { rawAlwaysOnTop }
        set { rawAlwaysOnTop = newValue }
    }

    nonisolated static let ollamaBaseURLKey = "ollamaBaseURL"

    // WHY: nonisolated + reads UserDefaults directly so OllamaClient's @Sendable
    // baseURLProvider closure (called off the main actor, per request) can resolve
    // the current base URL without @MainActor hops. Empty / malformed / scheme-less
    // input falls back to localhost so a broken setting never crashes or hangs a request.
    nonisolated static func resolvedOllamaBaseURL() -> URL {
        let fallback = URL(string: "http://localhost:11434")!
        guard let raw = UserDefaults.standard.string(forKey: ollamaBaseURLKey),
              case let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return fallback }
        return url
    }
}
