import AppKit
import CoreGraphics
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppCoordinator {
    static let onboardingWindowID = "onboarding"
    static let sessionWindowID = "session"
    static let mainWindowID = "main"

    let permissions: PermissionsManager
    let hotkeys: HotkeyRegistry

    // Drives the SessionWindow's LLM streaming; injected into its Scene by CallaiApp.
    @ObservationIgnored
    let llmClient: LLMClient

    @ObservationIgnored
    let screenCaptureService: ScreenCaptureService

    @ObservationIgnored
    let regionSelector: RegionSelectorOverlay

    @ObservationIgnored
    let microphoneRecorder: MicrophoneRecorder

    @ObservationIgnored
    let speechRecognitionService: SpeechRecognitionService

    @ObservationIgnored
    let settings: SettingsStore

    @ObservationIgnored
    private var openWindowAction: ((String) -> Void)?

    @ObservationIgnored
    @AppStorage("hasCompletedFirstLaunch") private var hasCompletedFirstLaunch = false

    // WHY: captured-at timestamp is reserved for a future TTL policy on stale
    // attachments. Held but unused in M6 — preserved per the architect's spec.
    private struct PendingScreenshot { let data: Data; let capturedAt: Date }

    @ObservationIgnored
    private var pendingAttachment: PendingScreenshot?

    @ObservationIgnored
    private var pendingScreenRecordingDenial: Bool = false

    // WHY: Region capture used to fail silently — the SessionWindow opened
    // with no attachment and no banner, leaving users guessing. We now stash
    // a user-facing error string here and surface it as a banner alongside
    // the existing permission-denied path.
    @ObservationIgnored
    private var pendingCaptureFailureMessage: String?

    init(permissions: PermissionsManager? = nil,
         hotkeys: HotkeyRegistry? = nil,
         llmClient: LLMClient? = nil,
         screenCaptureService: ScreenCaptureService = SCKitScreenCaptureService(),
         regionSelector: RegionSelectorOverlay? = nil,
         microphoneRecorder: MicrophoneRecorder? = nil,
         speechRecognitionService: SpeechRecognitionService? = nil,
         settings: SettingsStore? = nil) {
        self.permissions = permissions ?? PermissionsManager()
        self.hotkeys = hotkeys ?? HotkeyRegistry()
        // WHY: inject the configurable base URL via provider so an Ollama URL
        // change in Settings is read on each request. resolvedOllamaBaseURL() is
        // nonisolated static, so it is safe inside the @Sendable closure. Built
        // in the init body (not as a default arg) for the same @MainActor reason
        // as regionSelector/microphoneRecorder below.
        self.llmClient = llmClient ?? OllamaClient(baseURLProvider: { SettingsStore.resolvedOllamaBaseURL() })
        self.screenCaptureService = screenCaptureService
        // WHY: RegionSelectorOverlay / AVAudioEngineMicrophoneRecorder /
        // SFSpeechRecognitionSpeechService / SettingsStore are all @MainActor-
        // isolated, so their inits can't be used as default-argument
        // expressions (those evaluate outside the enclosing actor).
        // Constructing inside the @MainActor init body is OK.
        self.regionSelector = regionSelector ?? RegionSelectorOverlay()
        self.microphoneRecorder = microphoneRecorder ?? AVAudioEngineMicrophoneRecorder()
        self.speechRecognitionService = speechRecognitionService ?? SFSpeechRecognitionSpeechService()
        self.settings = settings ?? SettingsStore()
        registerHotkeys()
    }

    var onboardingStatus: OnboardingStatus {
        var status = permissions.onboardingStatus()
        status.openComposerHotkeyAssigned = hotkeys.openComposerAssigned
        status.regionThenComposerHotkeyAssigned = hotkeys.regionThenComposerAssigned
        return status
    }

    var isFirstLaunch: Bool { !hasCompletedFirstLaunch }

    func refresh() {
        permissions.refresh()
        hotkeys.refreshAssignmentState()
    }

    func bindWindowOpener(_ open: @escaping (String) -> Void) {
        openWindowAction = open
    }

    // WHY: LSUIElement=YES menu-bar apps don't get foreground focus on their
    // own when SwiftUI's openWindow fires — the new window slides in behind
    // whichever app the user is currently focused on. We wrap every openWindow
    // call so the app is explicitly activated and the new window is brought
    // forward.
    //
    // Three-pronged activation, because each step covers a different failure
    // mode observed on macOS 26:
    //  1. NSApp.activate(ignoringOtherApps:) — the legacy "force foreground"
    //     call; reliable on accessory apps when triggered from a user click.
    //  2. NSRunningApplication.current.activate(options:.activateAllWindows) —
    //     pulls every existing app window up; necessary because step 1 alone
    //     sometimes leaves non-key windows behind on multi-display layouts.
    //  3. async makeKeyAndOrderFront on the matching window — SwiftUI's
    //     openWindow creates the NSWindow on the next runloop tick, so we
    //     defer the lookup until that tick and explicitly raise the new
    //     window. Without this, opening an Onboarding/Settings window from
    //     the MenuBarExtra dropdown placed the window behind the previously
    //     focused app (the dropdown click activated our app for an instant,
    //     then dropdown dismissal handed focus back before the window had
    //     time to appear).
    private func presentWindow(_ id: String) {
        openWindowAction?(id)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            Self.bringToFrontWindow(matching: id)
        }
    }

    // WHY: SwiftUI doesn't expose the NSWindow it creates for a Window scene,
    // so we look it up by `identifier` (which SwiftUI sets to the scene id) on
    // the next runloop tick. We orderFront unconditionally and only
    // makeKeyAndOrderFront when the app is active — calling makeKey on an
    // inactive app can no-op on Sequoia+.
    private static func bringToFrontWindow(matching id: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == id })
            ?? NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix(id) })
        else { return }
        window.orderFrontRegardless()
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func presentOnboardingIfFirstLaunch() {
        guard isFirstLaunch else { return }
        presentWindow(Self.onboardingWindowID)
    }

    func openOnboarding() {
        refresh()
        presentWindow(Self.onboardingWindowID)
    }

    func openComposer() {
        presentWindow(Self.sessionWindowID)
    }

    func dismissOnboarding(dismiss: (String) -> Void) {
        hasCompletedFirstLaunch = true
        dismiss(Self.onboardingWindowID)
    }

    func finishOnboarding(dismiss: (String) -> Void) {
        hasCompletedFirstLaunch = true
        refresh()
        dismiss(Self.onboardingWindowID)
    }

    // WHY: kept non-async so MenuBar's sync `onRegionThenComposer` binding and
    // the sync `HotkeyRegistry` callback don't need to change. The actual
    // overlay → capture → window-open flow is detached into a Task.
    func startRegionThenComposer() {
        Task { @MainActor in await runRegionCapture() }
    }

    func consumePendingAttachment() -> Data? {
        defer { pendingAttachment = nil }
        return pendingAttachment?.data
    }

    func consumePendingScreenRecordingDenial() -> Bool {
        defer { pendingScreenRecordingDenial = false }
        return pendingScreenRecordingDenial
    }

    func consumePendingCaptureFailureMessage() -> String? {
        defer { pendingCaptureFailureMessage = nil }
        return pendingCaptureFailureMessage
    }

    func openMainWindow() {
        presentWindow(Self.mainWindowID)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // WHY: macOS Screen Recording permission is keyed by PID — flipping the
    // toggle in System Settings does not take effect until the process restarts.
    // Onboarding offers this as a one-click action so the user doesn't have to
    // remember to Cmd+Q and reopen from Finder. We launch a fresh instance via
    // NSWorkspace before terminating so the relaunch doesn't depend on
    // LaunchServices remembering the bundle.
    func relaunchForPermissionChange() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL,
                                            configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    private func registerHotkeys() {
        hotkeys.onOpenComposer { [weak self] in self?.openComposer() }
        hotkeys.onRegionThenComposer { [weak self] in self?.startRegionThenComposer() }
    }

    private func runRegionCapture() async {
        permissions.refresh()
        switch permissions.screenRecording {
        case .granted:
            await performRegionCapture()
        case .notDetermined:
            let status = await permissions.requestScreenRecording()
            if status == .granted {
                await performRegionCapture()
            } else {
                pendingScreenRecordingDenial = true
                presentWindow(Self.sessionWindowID)
            }
        case .denied:
            pendingScreenRecordingDenial = true
            presentWindow(Self.sessionWindowID)
        }
    }

    private func performRegionCapture() async {
        let rect: CGRect
        do {
            rect = try await regionSelector.presentForRegion()
        } catch ScreenCaptureError.cancelled {
            // WHY: user-cancelled selection — do not open a SessionWindow.
            return
        } catch {
            pendingCaptureFailureMessage = userFacingMessage(for: error)
            presentWindow(Self.sessionWindowID)
            return
        }

        do {
            let image = try await screenCaptureService.capture(rect: rect)
            guard let png = Self.encodeAsPNG(image) else {
                pendingCaptureFailureMessage = ScreenCaptureError
                    .captureFailed(message: "스크린샷 PNG 인코딩에 실패했습니다.")
                    .userFacingMessage
                presentWindow(Self.sessionWindowID)
                return
            }
            pendingAttachment = PendingScreenshot(data: png, capturedAt: .now)
            presentWindow(Self.sessionWindowID)
        } catch ScreenCaptureError.permissionDenied {
            pendingScreenRecordingDenial = true
            presentWindow(Self.sessionWindowID)
        } catch ScreenCaptureError.cancelled {
            return
        } catch {
            // WHY: previously a silent fall-through. Stash a user-facing
            // message and let ConversationHostView render it as a banner.
            pendingCaptureFailureMessage = userFacingMessage(for: error)
            presentWindow(Self.sessionWindowID)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let captureError = error as? ScreenCaptureError {
            return captureError.userFacingMessage
        }
        return error.localizedDescription
    }

    // WHY: NSBitmapImageRep(cgImage:).representation(using:.png) silently
    // returns nil for CGImages whose pixel format / color space combination it
    // can't ingest — observed with SCKit on macOS 26 (display P3 + BGRA premul
    // alpha). CGImageDestination accepts whatever CG produced, so prefer it.
    // Returns nil only on genuinely catastrophic failures (no PNG encoder
    // installed, CG image unreadable), which the caller treats as a captureFailed.
    private static func encodeAsPNG(_ image: CGImage) -> Data? {
        guard image.width > 0, image.height > 0 else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
