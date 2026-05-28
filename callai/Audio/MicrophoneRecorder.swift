import AVFoundation
import Foundation

// WHY: Sendable protocol so the recorder can be passed across actor boundaries
// (e.g. AppCoordinator on @MainActor → composer view model). The async stream
// it returns carries `AVAudioPCMBuffer` (a reference type from a system
// framework) which is not formally Sendable, but flows through a single
// producer/consumer channel by design — the buffers are produced inside the
// engine tap and consumed by the recognition service downstream. Co-locating
// protocol + adopter + error + userFacingMessage mirrors the M6 Capture
// convention (`Capture/ScreenCaptureService.swift`).
protocol MicrophoneRecorder: Sendable {
    @MainActor func start() async throws -> AsyncStream<AVAudioPCMBuffer>
    @MainActor func stop()
    @MainActor var isRecording: Bool { get }
}

// WHY: Four error cases mirror the host UI's needs (T7.2.2 inline banner):
// TCC denial (mapped by the host, not by this class — see below), engine
// failure to start, double-start guard, and a cancelled state for host-driven
// teardown. `userFacingMessage` wording matches `ScreenCaptureError` /
// `LLMClientError`.
enum MicrophoneRecorderError: Error, Equatable, Sendable {
    case permissionDenied
    case engineStartFailed(message: String)
    case alreadyRecording
    case cancelled
}

extension MicrophoneRecorderError {
    var userFacingMessage: String {
        switch self {
        case .permissionDenied:
            return "마이크 권한이 필요합니다. 시스템 설정에서 권한을 부여하세요."
        case .engineStartFailed(let message):
            return "마이크를 시작하지 못했습니다: \(message)"
        case .alreadyRecording:
            return "이미 녹음 중입니다."
        case .cancelled:
            return "녹음이 취소되었습니다."
        }
    }
}

// WHY: AVAudioEngine + a single tap on inputNode is the canonical macOS path
// for low-latency mic capture. We use the inputNode's native output format —
// forcing a sample rate / channel layout would invite format-mismatch crashes
// on uncommon devices, and SFSpeechAudioBufferRecognitionRequest accepts
// whatever PCM format the engine hands us.
//
// Permission caveat: macOS does NOT throw from `engine.start()` when mic TCC
// is denied — it simply produces silent buffers. The HOST (T7.2.2) checks
// `PermissionsManager.microphone` BEFORE calling `start()`, so this class does
// not perform TCC checks itself. The `.permissionDenied` case stays in the
// enum so the host can map a pre-flight denial into a consistent error type.
@MainActor
final class AVAudioEngineMicrophoneRecorder: MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var _isRecording: Bool = false

    var isRecording: Bool { _isRecording }

    init() {}

    func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if _isRecording {
            throw MicrophoneRecorderError.alreadyRecording
        }

        // Build the stream first so the continuation is captured before the
        // tap closure starts producing buffers.
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.continuation = continuation
            // WHY: onTermination fires when the consumer Task is cancelled or
            // breaks out of `for await`. We hop back to the MainActor to tear
            // down the engine so the tap can't leak into the next start().
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stop()
                }
            }
        }

        let inputNode = engine.inputNode
        // WHY: outputFormat(forBus:) returns the hardware's native format; we
        // pass it straight to installTap so AVAudioEngine doesn't insert an
        // implicit converter. bufferSize 1024 ≈ 21ms @ 48kHz which keeps
        // streaming partials well under the 500ms latency target.
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // AsyncStream.Continuation is Sendable, so yielding from the
            // tap's audio thread is safe without hopping to MainActor.
            self?.continuation?.yield(buffer)
        }

        do {
            try engine.start()
        } catch {
            // Clean up the tap we just installed before surfacing the error.
            inputNode.removeTap(onBus: 0)
            continuation?.finish()
            continuation = nil
            _isRecording = false
            throw MicrophoneRecorderError.engineStartFailed(message: error.localizedDescription)
        }

        _isRecording = true
        return stream
    }

    func stop() {
        // Idempotent: a second stop() call from onTermination after a manual
        // stop() must not double-remove the tap or double-finish the stream.
        guard _isRecording else { return }
        _isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
