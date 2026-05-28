import Foundation

struct OnboardingStatus: Sendable, Equatable {
    var screenRecordingGranted: Bool
    var microphoneGranted: Bool
    var speechRecognitionGranted: Bool
    var openComposerHotkeyAssigned: Bool
    var regionThenComposerHotkeyAssigned: Bool

    init(
        screenRecordingGranted: Bool = false,
        microphoneGranted: Bool = false,
        speechRecognitionGranted: Bool = false,
        openComposerHotkeyAssigned: Bool = false,
        regionThenComposerHotkeyAssigned: Bool = false
    ) {
        self.screenRecordingGranted = screenRecordingGranted
        self.microphoneGranted = microphoneGranted
        self.speechRecognitionGranted = speechRecognitionGranted
        self.openComposerHotkeyAssigned = openComposerHotkeyAssigned
        self.regionThenComposerHotkeyAssigned = regionThenComposerHotkeyAssigned
    }

    var isComplete: Bool {
        screenRecordingGranted
            && microphoneGranted
            && speechRecognitionGranted
            && openComposerHotkeyAssigned
            && regionThenComposerHotkeyAssigned
    }
}
