import SwiftData
import SwiftUI

@main
struct CallaiApp: App {
    @State private var coordinator = AppCoordinator()

    private let modelContainer: ModelContainer = Self.makeModelContainer()

    private static func makeModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Conversation.self, Message.self)
        } catch {
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: Conversation.self, Message.self, configurations: fallback)
            } catch {
                fatalError("SwiftData ModelContainer 생성 실패: \(error)")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarScene(coordinator: coordinator)
        } label: {
            MenuBarLabel(coordinator: coordinator)
        }

        Window("callai 시작하기", id: AppCoordinator.onboardingWindowID) {
            OnboardingScene(coordinator: coordinator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("callai", id: AppCoordinator.sessionWindowID) {
            SessionScene(coordinator: coordinator)
        }
        .defaultPosition(.center)
        .modelContainer(modelContainer)

        Window("callai 히스토리", id: AppCoordinator.mainWindowID) {
            MainWindow(
                client: coordinator.llmClient,
                recorder: coordinator.microphoneRecorder,
                recognitionService: coordinator.speechRecognitionService,
                settings: coordinator.settings,
                permissions: coordinator.permissions
            )
        }
        .defaultPosition(.center)
        .modelContainer(modelContainer)

        Settings {
            SettingsScene(coordinator: coordinator)
        }
    }
}

// WHY: the MenuBarExtra label is instantiated at launch and stays alive, so it is
// the binding point for the window opener — the dropdown content is created lazily.
private struct MenuBarLabel: View {
    let coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "bubble.left.and.bubble.right")
            .onAppear {
                coordinator.refresh()
                coordinator.bindWindowOpener { openWindow(id: $0) }
                coordinator.presentOnboardingIfFirstLaunch()
            }
    }
}

private struct MenuBarScene: View {
    let coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarContent(
            onboardingStatus: coordinator.onboardingStatus,
            onOpenOnboarding: coordinator.openOnboarding,
            onOpenComposer: coordinator.openComposer,
            onRegionThenComposer: coordinator.startRegionThenComposer,
            onOpenMainWindow: coordinator.openMainWindow,
            // WHY: `openSettings()` from the environment doesn't route through
            // AppCoordinator.presentWindow, so the accessory-app activation
            // step is skipped and the Settings window slides in behind whichever
            // app currently has focus. Pair it with the same explicit activate
            // call presentWindow uses for every other window.
            onOpenSettings: {
                openSettings()
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            },
            onQuit: coordinator.quit
        )
    }
}

// WHY: the SwiftUI Window scene's view builder can re-evaluate multiple times
// (any @Observable change on `coordinator` triggers it). Calling `consume*`
// inside the builder drains the pending attachment/banner on the first
// evaluation, leaving subsequent evaluations to instantiate SessionWindow with
// nil — so the screenshot preview and the diagnostic banner both vanish before
// the user can see them. We isolate consumption to a single `onAppear` here so
// the values stick for the lifetime of the window.
private struct SessionScene: View {
    let coordinator: AppCoordinator
    @State private var payloadID: UUID = UUID()
    @State private var pendingAttachment: Data?
    @State private var screenRecordingDenied: Bool = false
    @State private var captureFailureMessage: String?

    var body: some View {
        SessionWindow(
            client: coordinator.llmClient,
            payloadID: payloadID,
            pendingAttachment: pendingAttachment,
            screenRecordingDenied: screenRecordingDenied,
            captureFailureMessage: captureFailureMessage,
            recorder: coordinator.microphoneRecorder,
            recognitionService: coordinator.speechRecognitionService,
            settings: coordinator.settings,
            permissions: coordinator.permissions,
            onRelaunchForPermission: coordinator.relaunchForPermissionChange
        )
        .onAppear {
            consumePendingPayload()
        }
        .onChange(of: coordinator.sessionPresentationID) { _, _ in
            consumePendingPayload()
        }
    }

    private func consumePendingPayload() {
        payloadID = coordinator.sessionPresentationID
        pendingAttachment = coordinator.consumePendingAttachment()
        screenRecordingDenied = coordinator.consumePendingScreenRecordingDenial()
        captureFailureMessage = coordinator.consumePendingCaptureFailureMessage()
    }
}

private struct OnboardingScene: View {
    let coordinator: AppCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingView(
            permissions: coordinator.permissions,
            hotkeys: coordinator.hotkeys,
            onDismiss: { coordinator.dismissOnboarding { dismissWindow(id: $0) } },
            onFinish: { coordinator.finishOnboarding { dismissWindow(id: $0) } },
            onRelaunchForPermission: coordinator.relaunchForPermissionChange
        )
    }
}

private struct SettingsScene: View {
    let coordinator: AppCoordinator

    var body: some View {
        SettingsView(
            settings: coordinator.settings,
            client: coordinator.llmClient,
            hotkeys: coordinator.hotkeys,
            onOpenOnboarding: coordinator.openOnboarding,
            onboardingComplete: coordinator.onboardingStatus.isComplete
        )
    }
}
