import Foundation
import SwiftData
import SwiftUI

// WHY: @Environment(\.modelContext) is unavailable at View.init, and
// ConversationStore needs a concrete ModelContext. The outer view reads the
// scene's context, then hands it to the shared ConversationHostView (in
// new-conversation mode) which fully owns the send/stream/persist/cancel path.
struct SessionWindow: View {
    private let client: LLMClient
    private let payloadID: UUID
    private let pendingAttachment: Data?
    private let screenRecordingDenied: Bool
    private let captureFailureMessage: String?
    private let recorder: MicrophoneRecorder
    private let recognitionService: SpeechRecognitionService
    private let settings: SettingsStore
    private let permissions: PermissionsManager
    private let onRelaunchForPermission: () -> Void

    @Environment(\.modelContext) private var modelContext

    init(
        client: LLMClient,
        payloadID: UUID = UUID(),
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
        self.payloadID = payloadID
        self.pendingAttachment = pendingAttachment
        self.screenRecordingDenied = screenRecordingDenied
        self.captureFailureMessage = captureFailureMessage
        self.recorder = recorder
        self.recognitionService = recognitionService
        self.settings = settings
        self.permissions = permissions
        self.onRelaunchForPermission = onRelaunchForPermission
    }

    var body: some View {
        ConversationHostView(
            client: client,
            store: ConversationStore(modelContext: modelContext),
            payloadID: payloadID,
            pendingAttachment: pendingAttachment,
            screenRecordingDenied: screenRecordingDenied,
            captureFailureMessage: captureFailureMessage,
            recorder: recorder,
            recognitionService: recognitionService,
            settings: settings,
            permissions: permissions,
            onRelaunchForPermission: onRelaunchForPermission
        )
        .frame(minWidth: 460, minHeight: 420)
    }
}
