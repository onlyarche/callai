import AppKit
import SwiftUI

struct PromptComposerView: View {
    @Bindable private var viewModel: ComposerViewModel
    private let settings: SettingsStore
    private let onSend: () -> Void
    private let onVoiceStart: () -> Void
    private let onVoiceStop: () -> Void
    private let onVoiceUnavailableTap: (() -> Void)?

    init(
        viewModel: ComposerViewModel,
        settings: SettingsStore,
        onSend: @escaping () -> Void,
        onVoiceStart: @escaping () -> Void,
        onVoiceStop: @escaping () -> Void,
        onVoiceUnavailableTap: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.settings = settings
        self.onSend = onSend
        self.onVoiceStart = onVoiceStart
        self.onVoiceStop = onVoiceStop
        self.onVoiceUnavailableTap = onVoiceUnavailableTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.attachedImageDisallowed {
                CapabilityWarningBanner()
            }

            if let data = viewModel.attachedImage {
                ScreenshotPreview(data: data) {
                    viewModel.setAttachedImage(nil)
                }
            }

            TextEditor(text: $viewModel.text)
                .font(.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if viewModel.text.isEmpty {
                        Text("질문을 입력하세요…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(viewModel.isSending)

            if let partial = viewModel.partialTranscript, !partial.isEmpty {
                PartialTranscriptLabel(text: partial)
            }

            HStack(spacing: 8) {
                voiceButton
                modelPicker
                Spacer()
                Button(action: triggerSend) {
                    if viewModel.isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("전송", systemImage: "paperplane.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canSend)
            }
        }
        .padding(12)
    }

    private func triggerSend() {
        guard viewModel.canSend else { return }
        onSend()
    }

    @ViewBuilder
    private var modelPicker: some View {
        Picker("", selection: $viewModel.model) {
            ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
        .disabled(viewModel.isSending)
        .accessibilityLabel(Text("모델 선택"))
    }

    // WHY: keep the active `model` selectable even when listModels() failed
    // (empty) or hasn't yet returned the current model — otherwise the Picker
    // would have no matching tag and render blank.
    private var modelOptions: [String] {
        viewModel.availableModels.contains(viewModel.model)
            ? viewModel.availableModels
            : [viewModel.model] + viewModel.availableModels
    }

    @ViewBuilder
    private var voiceButton: some View {
        let unavailable = viewModel.voiceInputUnavailableReason != nil
        let recording = viewModel.isRecording
        let iconName = recording ? "mic.fill" : "mic"
        let iconColor: Color = unavailable
            ? .secondary
            : (recording ? .red : .accentColor)
        let tooltip = viewModel.voiceInputUnavailableReason
            ?? (settings.voiceInputMode == .pushToTalk
                ? (recording ? "녹음 중…" : "음성 입력 (누르고 있는 동안 녹음)")
                : (recording ? "녹음 중지" : "음성 입력 시작/중지"))

        switch settings.voiceInputMode {
        case .pushToTalk:
            voiceButtonLabel(iconName: iconName, iconColor: iconColor, recording: recording, unavailable: unavailable)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .gesture(pushToTalkGesture(unavailable: unavailable))
                .help(tooltip)
                .accessibilityLabel(Text("음성 입력 (누르고 있는 동안 녹음)"))
                .accessibilityHint(viewModel.voiceInputUnavailableReason.map(Text.init) ?? Text(""))
        case .toggle:
            Button(action: handleToggleTap) {
                voiceButtonLabel(iconName: iconName, iconColor: iconColor, recording: recording, unavailable: unavailable)
            }
            .buttonStyle(.plain)
            .help(tooltip)
            .accessibilityLabel(Text("음성 입력 토글"))
            .accessibilityHint(viewModel.voiceInputUnavailableReason.map(Text.init) ?? Text(""))
        }
    }

    @ViewBuilder
    private func voiceButtonLabel(iconName: String, iconColor: Color, recording: Bool, unavailable: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(recording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
            if recording {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.red.opacity(0.6), lineWidth: 1.5)
            }
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 14, weight: .semibold))
        }
        .frame(width: 36, height: 28)
        .opacity(unavailable ? 0.5 : 1.0)
    }

    // WHY: DragGesture(minimumDistance: 0) gives us an immediate press/release
    // pair without the long-press activation delay. We guard onChanged against
    // duplicate fires (it ticks per drag movement) by checking isRecording.
    private func pushToTalkGesture(unavailable: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if unavailable {
                    onVoiceUnavailableTap?()
                    return
                }
                if !viewModel.isRecording {
                    onVoiceStart()
                }
            }
            .onEnded { _ in
                if unavailable { return }
                if viewModel.isRecording {
                    onVoiceStop()
                }
            }
    }

    private func handleToggleTap() {
        if viewModel.voiceInputUnavailableReason != nil {
            onVoiceUnavailableTap?()
            return
        }
        if viewModel.isRecording {
            onVoiceStop()
        } else {
            onVoiceStart()
        }
    }
}

private struct PartialTranscriptLabel: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 3)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CapabilityWarningBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("선택한 모델은 이미지를 처리할 수 없습니다. vision 지원 모델로 변경하세요.")
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ScreenshotPreview: View {
    let data: Data
    let onRemove: () -> Void

    private static let maxWidth: CGFloat = 200
    private static let maxHeight: CGFloat = 150

    var body: some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(maxWidth: Self.maxWidth, maxHeight: Self.maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator, lineWidth: 1)
                    )

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("첨부 이미지 제거")
            }
            Spacer()
        }
    }

    // WHY: NSImage(data:) may fail on malformed bytes — fall back to an empty
    // placeholder rather than crashing; the X button still removes the slot.
    @ViewBuilder
    private var thumbnail: some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background.secondary)
                .frame(width: Self.maxWidth, height: Self.maxHeight)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }
}
