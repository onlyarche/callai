import Foundation

// WHY: Vision-only fallback prompt for scenario 2-1 (image only, no text).
// M8 makes it user-editable via SettingsStore.visionPrompt; this constant is the
// seed/default. `defaultVisionPrompt` is a deprecated alias kept until M8 Stage
// 8.3 migrates ComposerViewModel's call site — remove it then.
enum PromptTemplate {
    static let defaultVisionPromptFallback = "이 이미지를 설명해주세요."
    static let defaultVisionPrompt = defaultVisionPromptFallback
}
