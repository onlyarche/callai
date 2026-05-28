import AppKit
import SwiftUI
import KeyboardShortcuts

struct OnboardingView: View {
    let permissions: PermissionsManager
    let hotkeys: HotkeyRegistry
    let onDismiss: () -> Void
    let onFinish: () -> Void
    // WHY: Screen Recording permission is PID-cached by TCC, so newly granted
    // access does not apply to the running process. Surfacing a relaunch CTA
    // turns the macOS-standard 4-step flow (ask → System Settings → toggle →
    // Cmd+Q + reopen) into a 3-step flow with no terminal trip.
    let onRelaunchForPermission: () -> Void

    private var status: OnboardingStatus {
        var status = permissions.onboardingStatus()
        status.openComposerHotkeyAssigned = hotkeys.openComposerAssigned
        status.regionThenComposerHotkeyAssigned = hotkeys.regionThenComposerAssigned
        return status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                screenRecordingRow
                permissionRow(
                    title: "마이크",
                    description: "음성 입력을 녹음하려면 필요합니다.",
                    status: permissions.microphone,
                    actionTitle: permissions.microphone == .granted ? nil : "권한 요청",
                    action: { await permissions.requestMicrophone() }
                )
                permissionRow(
                    title: "음성 인식",
                    description: "녹음한 음성을 텍스트로 변환하려면 필요합니다.",
                    status: permissions.speechRecognition,
                    actionTitle: permissions.speechRecognition == .granted ? nil : "권한 요청",
                    action: { await permissions.requestSpeechRecognition() }
                )
                hotkeyRow(
                    title: "단축키 — Composer 열기",
                    description: "빈 입력 상태로 Composer 창을 엽니다.",
                    name: .openComposer,
                    assigned: status.openComposerHotkeyAssigned
                )
                hotkeyRow(
                    title: "단축키 — 영역 선택 + Composer",
                    description: "영역을 선택한 뒤 스크린샷이 첨부된 Composer를 엽니다.",
                    name: .regionThenComposer,
                    assigned: status.regionThenComposerHotkeyAssigned
                )
            }
            .padding(20)

            Divider()

            footer
        }
        .frame(width: 460)
        .onAppear {
            permissions.refresh()
            hotkeys.refreshAssignmentState()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("callai 시작하기")
                .font(.title2.bold())
            Text("권한과 단축키를 설정하면 모든 기능을 쓸 수 있습니다. 지금 건너뛰어도 앱은 정상 동작합니다.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("나중에 하기", action: onDismiss)
            Spacer()
            Button("완료", action: onFinish)
                .keyboardShortcut(.defaultAction)
                .disabled(!status.isComplete)
        }
        .padding(20)
    }

    private func permissionRow(
        title: String,
        description: String,
        status: PermissionStatus,
        actionTitle: String?,
        action: @escaping () async -> Void
    ) -> some View {
        ChecklistRow(granted: status.isGranted, title: title, description: description) {
            if let actionTitle {
                Button(actionTitle) {
                    Task { @MainActor in
                        await action()
                        // WHY: macOS TCC permission alerts are system modals;
                        // dismissing them does NOT return focus to LSUIElement
                        // accessory apps like ours — focus drops to whichever
                        // regular app was previously frontmost, hiding the
                        // onboarding window behind it. We reclaim focus twice:
                        //  • Immediately — handles AVCaptureDevice.requestAccess
                        //    whose completion fires AFTER the alert is dismissed.
                        //  • After ~250 ms — handles SFSpeechRecognizer
                        //    .requestAuthorization, whose completion can fire
                        //    BEFORE the alert finishes dismissing; an immediate
                        //    activate then gets stomped by the dismissal handing
                        //    focus to the previous frontmost app.
                        Self.reclaimFocusAfterPermissionAlert()
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        Self.reclaimFocusAfterPermissionAlert()
                    }
                }
            }
        }
    }

    private static func reclaimFocusAfterPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        if let onboarding = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "onboarding"
        }) {
            onboarding.orderFrontRegardless()
            onboarding.makeKeyAndOrderFront(nil)
        }
    }

    // WHY: Screen Recording gets a custom row because the macOS permission
    // requires a process relaunch to take effect — the standard request button
    // is paired with a "재시작" CTA, and a short hint line spells out the
    // two-click sequence so users don't have to discover it.
    private var screenRecordingRow: some View {
        ChecklistRow(
            granted: permissions.screenRecording.isGranted,
            title: "화면 녹화",
            description: permissions.screenRecording.isGranted
                ? "영역 스크린샷을 캡쳐하려면 필요합니다."
                : "영역 스크린샷을 캡쳐하려면 필요합니다. 권한 부여 후 재시작이 필요합니다."
        ) {
            HStack(spacing: 8) {
                if !permissions.screenRecording.isGranted {
                    Button("권한 설정") {
                        Task { await permissions.requestScreenRecording() }
                    }
                }
                Button("재시작", action: onRelaunchForPermission)
                    .help("권한이 새로 부여된 후 현재 인스턴스에 적용하려면 앱을 재시작해야 합니다.")
            }
        }
    }

    private func hotkeyRow(
        title: String,
        description: String,
        name: KeyboardShortcuts.Name,
        assigned: Bool
    ) -> some View {
        ChecklistRow(granted: assigned, title: title, description: description) {
            KeyboardShortcuts.Recorder(for: name) { _ in
                hotkeys.refreshAssignmentState()
            }
        }
    }
}

private struct ChecklistRow<Trailing: View>: View {
    let granted: Bool
    let title: String
    let description: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(granted ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            trailing
        }
    }
}
