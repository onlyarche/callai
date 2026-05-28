import AVFoundation
import Foundation
import Speech

// WHY: partial vs final are the only two states a downstream composer needs —
// `partial(String)` updates the in-flight transcript box, `final(String)`
// commits it. Sendable + Equatable for testability and cross-actor flow.
enum SpeechRecognitionEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}

// WHY: Five error cases cover the entire on-device path: TCC denial (mapped
// by host pre-flight, same pattern as `MicrophoneRecorderError`), locale not
// supported on-device (we refuse to fall back to the network per PLAN §1),
// recognizer object unavailable at call time, generic recognition failure,
// and an explicit cancellation case for host-driven teardown.
enum SpeechRecognitionError: Error, Equatable, Sendable {
    case permissionDenied
    case onDeviceUnavailable(locale: String)
    case recognizerUnavailable
    // WHY: SFSpeechRecognizer requires macOS-level Dictation/Siri to be
    // enabled — the framework shares infrastructure with system Dictation.
    // When it's off, the recognizer surfaces NSError "Siri and Dictation are
    // disabled". We promote that to a dedicated case so the host can render a
    // friendly Korean prompt and a deeplink button to the right Settings pane.
    case dictationDisabled
    case recognitionFailed(message: String)
    case cancelled
}

extension SpeechRecognitionError {
    var userFacingMessage: String {
        switch self {
        case .permissionDenied:
            return "음성 인식 권한이 필요합니다. 시스템 설정에서 권한을 부여하세요."
        case .onDeviceUnavailable(let locale):
            return "이 언어(\(locale))는 디바이스 음성 인식을 지원하지 않습니다."
        case .recognizerUnavailable:
            return "음성 인식기를 사용할 수 없습니다. 잠시 후 다시 시도하세요."
        case .dictationDisabled:
            return "macOS 받아쓰기가 꺼져 있어 음성 인식을 쓸 수 없습니다. 시스템 설정 → 키보드 → 받아쓰기에서 켜주세요."
        case .recognitionFailed(let message):
            return "음성 인식 실패: \(message)"
        case .cancelled:
            return "음성 인식이 취소되었습니다."
        }
    }

    // WHY: lets the host view decide whether to show the deeplink button
    // without leaking the SFSpeech NSError shape into the UI layer.
    var canOpenDictationSettings: Bool {
        if case .dictationDisabled = self { return true }
        return false
    }
}

// WHY: Returns the throwing stream synchronously (not `async throws`) so the
// host can treat the recognition session as a single `for try await` loop —
// setup errors propagate through `continuation.finish(throwing:)` rather than
// a separate try.
protocol SpeechRecognitionService: Sendable {
    @MainActor func recognize(
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: Locale
    ) -> AsyncThrowingStream<SpeechRecognitionEvent, Error>
}

// WHY: `requiresOnDeviceRecognition = true` is the privacy contract (PLAN §1):
// no audio leaves the device. We gate this on `supportsOnDeviceRecognition`
// up-front so the user gets a clear error instead of an opaque framework
// failure later. `shouldReportPartialResults = true` drives the streaming
// composer UI.
@MainActor
final class SFSpeechRecognitionSpeechService: SpeechRecognitionService {
    init() {}

    func recognize(
        audio: AsyncStream<AVAudioPCMBuffer>,
        locale: Locale
    ) -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        AsyncThrowingStream<SpeechRecognitionEvent, Error> { continuation in
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                continuation.finish(throwing: SpeechRecognitionError.recognizerUnavailable)
                return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                continuation.finish(throwing: SpeechRecognitionError.onDeviceUnavailable(locale: locale.identifier))
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true

            // WHY: SFSpeechRecognitionTask's completion handler dispatches on
            // an internal queue. `AsyncThrowingStream.Continuation` is
            // Sendable so yielding from that queue is safe without bouncing
            // through MainActor — and keeping the bounce out shaves latency
            // off every partial result.
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    // SFSpeechRecognizer surfaces task cancellation as an
                    // error too; we map it to .cancelled so host-side teardown
                    // doesn't look like a real recognition failure.
                    let nsError = error as NSError
                    if nsError.code == 301 // kAFAssistantErrorDomain cancelled
                        || (error is CancellationError) {
                        continuation.finish(throwing: SpeechRecognitionError.cancelled)
                    } else if Self.isDictationDisabled(nsError) {
                        continuation.finish(throwing: SpeechRecognitionError.dictationDisabled)
                    } else {
                        continuation.finish(throwing: SpeechRecognitionError.recognitionFailed(message: nsError.localizedDescription))
                    }
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    continuation.yield(.final(text))
                    continuation.finish()
                } else {
                    continuation.yield(.partial(text))
                }
            }

            // Pump audio buffers from the input stream into the recognition
            // request. When the producer (mic recorder) finishes the stream,
            // `endAudio()` tells the recognizer no more audio is coming so it
            // can deliver its final result.
            let pump = Task.detached {
                for await buffer in audio {
                    request.append(buffer)
                }
                request.endAudio()
            }

            // WHY: If the consumer abandons the stream (Task cancelled, host
            // calls stop), we tear down the recognizer task, end the request,
            // and cancel the pump so we don't leak the input loop.
            continuation.onTermination = { _ in
                task.cancel()
                request.endAudio()
                pump.cancel()
            }
        }
    }

    // WHY: SFSpeechRecognizer doesn't expose a typed code for the
    // "Dictation off" condition — macOS 26 surfaces it as NSError with
    // localizedDescription "Siri and Dictation are disabled". We match on
    // the string so future code-number changes don't silently regress
    // back to the opaque generic message.
    private static func isDictationDisabled(_ nsError: NSError) -> Bool {
        let description = nsError.localizedDescription.lowercased()
        return description.contains("dictation") && description.contains("disabled")
    }
}
