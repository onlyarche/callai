import AVFoundation
import CoreGraphics
import Speech

enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case granted

    var isGranted: Bool { self == .granted }
}

@MainActor
@Observable
final class PermissionsManager {
    private(set) var screenRecording: PermissionStatus = .notDetermined
    private(set) var microphone: PermissionStatus = .notDetermined
    private(set) var speechRecognition: PermissionStatus = .notDetermined

    init() {
        refresh()
    }

    func refresh() {
        screenRecording = Self.currentScreenRecordingStatus()
        microphone = Self.currentMicrophoneStatus()
        speechRecognition = Self.currentSpeechRecognitionStatus()
    }

    func onboardingStatus() -> OnboardingStatus {
        OnboardingStatus(
            screenRecordingGranted: screenRecording.isGranted,
            microphoneGranted: microphone.isGranted,
            speechRecognitionGranted: speechRecognition.isGranted
        )
    }

    @discardableResult
    func requestScreenRecording() async -> PermissionStatus {
        // CGRequestScreenCaptureAccess is synchronous and blocks until the user
        // responds; hop off the main actor so the UI stays responsive.
        let granted = await Task.detached { CGRequestScreenCaptureAccess() }.value
        screenRecording = granted ? .granted : Self.currentScreenRecordingStatus()
        return screenRecording
    }

    @discardableResult
    func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : Self.currentMicrophoneStatus()
        return microphone
    }

    @discardableResult
    func requestSpeechRecognition() async -> PermissionStatus {
        let raw = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        speechRecognition = Self.map(raw)
        return speechRecognition
    }

    private static func currentScreenRecordingStatus() -> PermissionStatus {
        // CGPreflightScreenCaptureAccess only distinguishes granted vs not;
        // there is no API to tell notDetermined from denied without prompting.
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    private static func currentMicrophoneStatus() -> PermissionStatus {
        map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private static func currentSpeechRecognitionStatus() -> PermissionStatus {
        map(SFSpeechRecognizer.authorizationStatus())
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}
